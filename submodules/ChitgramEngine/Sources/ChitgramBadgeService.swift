import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// The network half of `ChitgramBadges` (Android `ChitgramBadges`): Firestore's REST API in the project the Android
/// app uses, `badges/{telegramUserId}` = { e: emoji document id, u: Premium end in unix seconds, t: write time }.
/// The project and its web key come from the build configuration (Info.plist `ChitgramFirebaseProjectId`,
/// `ChitgramFirebaseApiKey`); without them badges are simply not looked up.
public enum ChitgramBadgeService {
    /// Firestore REST allows more, Android's SDK query took 10; the same here keeps requests small.
    private static let batch = 10
    private static var installed = false

    private static var projectId: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "ChitgramFirebaseProjectId") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static var apiKey: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "ChitgramFirebaseApiKey") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    public static var isAvailable: Bool {
        return self.projectId != nil && self.apiKey != nil
    }

    private static func documentsPath(_ projectId: String) -> String {
        return "projects/\(projectId)/databases/(default)/documents"
    }

    private static func endpoint(_ path: String) -> URL? {
        guard let projectId = self.projectId, let apiKey = self.apiKey else {
            return nil
        }
        return URL(string: "https://firestore.googleapis.com/v1/\(self.documentsPath(projectId))\(path)?key=\(apiKey)")
    }

    /// Once per account at launch: lookups go through Firestore from now on, and the account's own badge is looked up
    /// (which then keeps its document in step with Premium).
    public static func start(context: AccountContext) {
        guard self.isAvailable else {
            return
        }
        if !self.installed {
            self.installed = true
            ChitgramBadges.shared.lookup = { ids in
                self.lookup(ids)
            }
        }
        let accountPeerId = context.account.peerId
        let ownId = accountPeerId.id._internalGetInt64Value()
        self.own[ownId] = context
        ChitgramBadges.shared.refresh(ownId)
    }

    /// Accounts whose own document this device keeps current, by Telegram user id.
    private static var own: [Int64: AccountContext] = [:]

    private static func post(_ url: URL, body: [String: Any], completion: @escaping (Any?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20.0
        URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
            var result: Any?
            if error == nil, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), let data {
                result = try? JSONSerialization.jsonObject(with: data)
            }
            let value = result
            DispatchQueue.main.async {
                completion(value)
            }
        }).resume()
    }

    private static func integer(_ fields: [String: Any]?, _ name: String) -> Int64 {
        guard let field = fields?[name] as? [String: Any] else {
            return 0
        }
        if let string = field["integerValue"] as? String {
            return Int64(string) ?? 0
        }
        if let number = field["integerValue"] as? NSNumber {
            return number.int64Value
        }
        if let number = field["doubleValue"] as? NSNumber {
            return number.int64Value
        }
        return 0
    }

    private static func lookup(_ ids: [Int64]) {
        guard let projectId = self.projectId, let url = self.endpoint(":batchGet") else {
            return
        }
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start ..< min(start + self.batch, ids.count)])
            start += self.batch
            let names = chunk.map { "\(self.documentsPath(projectId))/badges/\($0)" }
            self.post(url, body: ["documents": names], completion: { result in
                guard let items = result as? [[String: Any]] else {
                    ChitgramBadges.shared.retryLater(chunk)
                    return
                }
                var found: [Int64: ChitgramBadges.Badge] = [:]
                for item in items {
                    guard let document = item["found"] as? [String: Any], let name = document["name"] as? String, let id = Int64(name.components(separatedBy: "/").last ?? "") else {
                        continue
                    }
                    let fields = document["fields"] as? [String: Any]
                    found[id] = ChitgramBadges.Badge(emoji: self.integer(fields, "e"), until: self.integer(fields, "u"))
                }
                ChitgramBadges.shared.apply(found: found, checked: chunk)
                for id in chunk {
                    if let context = self.own[id] {
                        self.syncMine(context: context, current: found[id])
                    }
                }
            })
        }
    }

    /// Keeps the member's document in step with their Premium: created with the mark only, end date kept current.
    private static func syncMine(context: AccountContext, current: ChitgramBadges.Badge?) {
        let accountPeerId = context.account.peerId
        guard ChitgramPremium.isActive(accountPeerId: accountPeerId) else {
            return
        }
        let until = Int64(ChitgramPremium.until(accountPeerId: accountPeerId))
        if let current, current.until == until {
            return
        }
        self.write(context: context, emoji: current?.emoji ?? 0, until: until, completion: nil)
    }

    /// The member's own emoji; 0 leaves the mark only.
    public static func myEmoji(context: AccountContext) -> Int64 {
        return ChitgramBadges.shared.active(userId: context.account.peerId.id._internalGetInt64Value())?.emoji ?? 0
    }

    /// Sets the emoji after the member's name. Calls back with nil, or an error text.
    public static func setMyEmoji(context: AccountContext, emoji: Int64, completion: @escaping (String?) -> Void) {
        let accountPeerId = context.account.peerId
        guard ChitgramPremium.isActive(accountPeerId: accountPeerId) else {
            completion("PREMIUM_REQUIRED")
            return
        }
        self.write(context: context, emoji: emoji, until: Int64(ChitgramPremium.until(accountPeerId: accountPeerId)), completion: completion)
    }

    private static func write(context: AccountContext, emoji: Int64, until: Int64, completion: ((String?) -> Void)?) {
        guard let projectId = self.projectId, let url = self.endpoint(":commit") else {
            completion?("NOT_CONFIGURED")
            return
        }
        let userId = context.account.peerId.id._internalGetInt64Value()
        let body: [String: Any] = [
            "writes": [
                [
                    "update": [
                        "name": "\(self.documentsPath(projectId))/badges/\(userId)",
                        "fields": [
                            "e": ["integerValue": String(emoji)],
                            "u": ["integerValue": String(until)]
                        ]
                    ],
                    "updateTransforms": [
                        ["fieldPath": "t", "setToServerValue": "REQUEST_TIME"]
                    ]
                ]
            ]
        ]
        self.post(url, body: body, completion: { result in
            if result != nil {
                ChitgramBadges.shared.setOwn(userId: userId, badge: ChitgramBadges.Badge(emoji: emoji, until: until))
                completion?(nil)
            } else {
                completion?("ERROR")
            }
        })
    }
}
