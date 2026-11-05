import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram: the sponsored channel at the top of chat search (Android `AdsManager`, `AdsApi`). The ads backend
/// matches the query and answers with a channel, which is resolved by its username and shown as Telegram shows its own
/// sponsored results. Only the two anonymous `search_ads` endpoints are used; the query and the Telegram user id are
/// sent (the same id on Android and iOS, so one person is counted once). Chitgram Premium members see no ad.
///
/// The backend and its key come from the build configuration (Info.plist `ChitgramAdsBaseUrl`, `ChitgramAdsApiKey`);
/// without them no request is ever made.
public enum ChitgramSearchAds {
    private static let minQueryLength = 4
    private static let debounce: Double = 0.3
    private static let opaquePrefix = "chitgram-ad:"

    private static func info(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static var baseUrl: String? {
        guard var value = self.info("ChitgramAdsBaseUrl") else {
            return nil
        }
        if !value.hasSuffix("/") {
            value += "/"
        }
        return value
    }

    /// The order behind an ad of ours, or nil for Telegram's own sponsored results.
    public static func orderId(opaqueId: Data) -> String? {
        guard let string = String(data: opaqueId, encoding: .utf8), string.hasPrefix(self.opaquePrefix) else {
            return nil
        }
        return String(string.dropFirst(self.opaquePrefix.count))
    }

    private static func post(path: String, body: [String: Any]) -> Signal<[String: Any]?, NoError> {
        guard let baseUrl = self.baseUrl, let apiKey = self.info("ChitgramAdsApiKey"), let url = URL(string: baseUrl + path) else {
            return .single(nil)
        }
        return Signal { subscriber in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10.0
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
                var result: [String: Any]?
                if error == nil, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data {
                    result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                subscriber.putNext(result)
                subscriber.putCompletion()
            })
            task.resume()
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    /// The ad for a search query, ready to show, or nil.
    public static func ad(context: AccountContext, query: String) -> Signal<AdPeer?, NoError> {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count < self.minQueryLength || self.baseUrl == nil || ChitgramPremium.isActive(accountPeerId: context.account.peerId) {
            return .single(nil)
        }
        let viewerId = String(context.account.peerId.id._internalGetInt64Value())
        let request = self.post(path: "api/search_ads/order/search/", body: ["tag": query, "viewer_id": viewerId])
        // No ad at first, so the search results never wait for the ads backend; typing replaces the search before
        // the debounce ends, which cancels the request.
        return Signal<AdPeer?, NoError>.single(nil)
        |> then((Signal<Never, NoError>.complete()
        |> delay(self.debounce, queue: Queue.concurrentDefaultQueue())
        |> then(request))
        |> mapToSignal { result -> Signal<AdPeer?, NoError> in
            guard let result, let orderId = result["order_id"] as? String, !orderId.isEmpty else {
                return .single(nil)
            }
            // A public channel opens by its username; the advertiser-typed id is not trusted (Android: the same).
            let username = ((result["channel_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            if username.isEmpty {
                return .single(nil)
            }
            return context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> mapToSignal { resolved -> Signal<EnginePeer?, NoError> in
                guard case let .result(peer) = resolved else {
                    return .complete()
                }
                return .single(peer)
            }
            |> take(1)
            |> map { peer -> AdPeer? in
                guard let peer, case .channel = peer else {
                    return nil
                }
                let opaqueId = (self.opaquePrefix + orderId).data(using: .utf8) ?? Data()
                return AdPeer(opaqueId: opaqueId, peer: peer, subscribers: nil, sponsorInfo: nil, additionalInfo: nil)
            }
        })
    }

    /// Counts a tap on an ad of ours.
    public static func click(context: AccountContext, orderId: String) {
        let viewerId = String(context.account.peerId.id._internalGetInt64Value())
        let _ = self.post(path: "api/search_ads/order/click/", body: ["order_id": orderId, "viewer_id": viewerId]).startStandalone()
    }
}

/// Chitgram's anonymous growth counters in the Android app's Firestore (Android `AnalyticsRemote`): installs, one per
/// device, and logins. The only thing that leaves the device is a random per-install id used to count it once.
public enum ChitgramAnalytics {
    private static let installCountedKey = "fenix_install_counted"
    private static let countedAccountsKey = "chitgram_counted_accounts"

    private static func info(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func commit(writes: [[String: Any]], completion: @escaping (Bool) -> Void) {
        guard let projectId = self.info("ChitgramFirebaseProjectId"), let apiKey = self.info("ChitgramFirebaseApiKey"), let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents:commit?key=\(apiKey)") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["writes": writes])
        URLSession.shared.dataTask(with: request, completionHandler: { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false)
            DispatchQueue.main.async {
                completion(ok)
            }
        }).resume()
    }

    private static func document(_ path: String) -> String? {
        guard let projectId = self.info("ChitgramFirebaseProjectId") else {
            return nil
        }
        return "projects/\(projectId)/databases/(default)/documents/\(path)"
    }

    /// `counter.allUsers += 1`, creating the document when it is missing.
    private static func increment(_ path: String) -> [String: Any]? {
        guard let name = self.document(path) else {
            return nil
        }
        return [
            "update": ["name": name, "fields": [String: Any]()],
            "updateMask": ["fieldPaths": [String]()],
            "updateTransforms": [["fieldPath": "allUsers", "increment": ["integerValue": "1"]]]
        ]
    }

    /// This device counted once, ever: the install's document is created only if it does not exist yet, in the same
    /// atomic write as the increment, so two quick launches never count twice.
    public static func addInstallIfFirstTime() {
        if self.defaults.bool(forKey: self.installCountedKey) {
            return
        }
        guard let deviceId = UIDevice.current.identifierForVendor?.uuidString, let install = self.document("uniqueInstallUsers/ios_\(deviceId)"), let increment = self.increment("uniqueInstallUsersCount/usersCount") else {
            return
        }
        let create: [String: Any] = [
            "update": ["name": install, "fields": [String: Any]()],
            "currentDocument": ["exists": false],
            "updateTransforms": [["fieldPath": "created_at", "setToServerValue": "REQUEST_TIME"]]
        ]
        self.commit(writes: [create, increment], completion: { ok in
            if ok {
                self.defaults.set(true, forKey: self.installCountedKey)
            }
        })
    }

    /// An account signed in on this device for the first time: +1 to the logins counter.
    public static func addAccountIfNew(accountPeerId: EnginePeer.Id) {
        let id = String(accountPeerId.toInt64())
        if (self.defaults.stringArray(forKey: self.countedAccountsKey) ?? []).contains(id) {
            return
        }
        guard let increment = self.increment("users/usersCount") else {
            return
        }
        self.commit(writes: [increment], completion: { ok in
            if ok {
                var counted = self.defaults.stringArray(forKey: self.countedAccountsKey) ?? []
                if !counted.contains(id) {
                    counted.append(id)
                    self.defaults.set(counted, forKey: self.countedAccountsKey)
                }
            }
        })
    }
}
