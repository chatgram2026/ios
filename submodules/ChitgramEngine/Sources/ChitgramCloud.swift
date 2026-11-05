import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram's settings follow the account (Android `cloud/ChitgramCloud` + `SavedCloud`): a copy lives in the
/// account's Saved Messages as messages scheduled a year ahead, which reach every device and never get sent. The
/// format is Android's — `#chitgram_settings v1 <rev> <part> <total>`, then Base64 of gzip of a JSON map
/// key → {t: type, v: value, a: changed at} — so one account's Android and iOS phones share one copy.
///
/// Merging is per setting and the newest change wins; a fresh phone's defaults were never "changed", so they never
/// overwrite what was set elsewhere. Only settings both apps mean the same way are shared; per-chat settings are
/// left out (chat ids differ between the apps), and so are passwords and per-account data.
public enum ChitgramCloud {
    private static let tag = "#chitgram_settings"
    private static let head = "\u{2699}\u{FE0F} Chitgram \u{00B7} sozlamalar nusxasi \u{2014} o'chirmang"
    private static let version = "v1"
    private static let chunk = 3500
    /// Telegram schedules at most a year ahead.
    private static let keepSeconds: Int32 = 360 * 24 * 60 * 60
    /// A copy with less than this left before its date is written again.
    private static let refreshBefore: Int32 = 200 * 24 * 60 * 60
    private static let syncThrottle: Double = 10 * 60
    private static let pushDelay: Double = 5.0

    /// Shared keys and Android's type letter for each.
    private static let keys: [String: String] = [
        "ghost": "b", "ghost_btn_visibility_on_action_bar": "b", "ghost_story": "b", "hide_story": "b",
        "hide_story_for_visibility_on_action_bar": "b", "story_download": "b",
        "confirm_gif": "b", "confirm_sticker": "b", "confirm_voice": "b", "selected_style": "i",
        "auto_answer_active": "b", "auto_answer_text": "s", "auto_accept_join": "b", "round_camera_front": "b",
        "reminder_enabled": "b", "reminder_delay_min": "i", "reminder_sound": "i",
        "hide_tabs": "b", "folder_icon_mode": "b"
    ]

    private struct Item {
        var type: String
        var value: String
        var at: Int64
    }

    private struct Part {
        let rev: Int64
        let part: Int
        let total: Int
        let data: String
        let messageId: Int32
        let date: Int32
    }

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static var syncing = false
    private static var syncAgain: AccountContext?
    private static var observer: NSObjectProtocol?
    private static var pushTimer: SwiftSignalKit.Timer?
    private static weak var lastContext: AccountContext?

    /// At launch and on every return: start listening for changes and sync, at most every 10 minutes.
    public static func onResume(context: AccountContext) {
        self.lastContext = context
        if self.observer == nil {
            self.observer = NotificationCenter.default.addObserver(forName: ChitgramPreferences.didChangeNotification, object: nil, queue: .main, using: { notification in
                guard let key = notification.userInfo?["key"] as? String, self.keys[key] != nil else {
                    return
                }
                if notification.userInfo?["synced"] as? Bool == true {
                    return
                }
                // Several switches flipped in a row become one write.
                self.pushTimer?.invalidate()
                let timer = SwiftSignalKit.Timer(timeout: self.pushDelay, repeat: false, completion: {
                    if let context = self.lastContext {
                        self.sync(context: context)
                    }
                }, queue: Queue.mainQueue())
                self.pushTimer = timer
                timer.start()
            })
        }
        let key = "chitgram_cloud_synced_\(context.account.peerId.toInt64())"
        if Date().timeIntervalSince1970 - self.defaults.double(forKey: key) < self.syncThrottle {
            return
        }
        self.sync(context: context)
    }

    // MARK: Values

    private static func encode(_ value: Any, type: String) -> String? {
        switch type {
        case "b":
            return (value as? Bool).map { $0 ? "true" : "false" }
        case "i", "l":
            return (value as? NSNumber).map { "\($0.int64Value)" }
        case "s":
            return value as? String
        default:
            return nil
        }
    }

    private static func decode(_ item: Item) -> Any? {
        switch item.type {
        case "b":
            return item.value == "true"
        case "i", "l":
            return Int(item.value)
        case "s":
            return item.value
        default:
            return nil
        }
    }

    /// This device's shared settings, each with the time it was last changed ("x" = removed).
    private static func snapshot(times: [String: Int64]) -> [String: Item] {
        var result: [String: Item] = [:]
        for (key, type) in self.keys {
            if let value = self.defaults.object(forKey: key) {
                if let text = self.encode(value, type: type) {
                    result[key] = Item(type: type, value: text, at: times[key] ?? 0)
                }
            } else if let at = times[key] {
                result[key] = Item(type: "x", value: "", at: at)
            }
        }
        return result
    }

    // MARK: Sync

    private static func now() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    /// Reads the cloud copy, takes every setting that is newer there, and writes back what is newer here.
    public static func sync(context: AccountContext) {
        if self.syncing {
            self.syncAgain = context
            return
        }
        self.syncing = true
        let account = context.account
        let selfId = account.peerId
        let _ = (chitgramScheduledPosts(account: account, peerId: selfId)
        |> deliverOnMainQueue).startStandalone(next: { posts in
            guard let posts else {
                self.finish()
                return
            }
            self.defaults.set(Date().timeIntervalSince1970, forKey: "chitgram_cloud_synced_\(selfId.toInt64())")
            let parts = posts.compactMap(self.parse)
            let newest = self.newestComplete(parts)
            let cloud = newest?.settings ?? [:]

            // The cloud's newer settings come in first.
            var times = ChitgramPreferences.shared.changeTimes()
            for (key, item) in cloud {
                guard self.keys[key] != nil, item.at > (times[key] ?? 0) else {
                    continue
                }
                ChitgramPreferences.shared.applySynced(rawKey: key, value: item.type == "x" ? nil : self.decode(item), at: item.at)
                times[key] = item.at
            }
            // Settings this device had before it ever synced count as set now, so they get shared too — after the
            // cloud has had its say, so a fresh phone never overwrites the old one.
            for key in self.keys.keys where times[key] == nil && self.defaults.object(forKey: key) != nil {
                let at = self.now()
                ChitgramPreferences.shared.setChangeTime(key, at)
                times[key] = at
            }

            let local = self.snapshot(times: times)
            let newerHere = local.contains(where: { key, item in item.at > (cloud[key]?.at ?? 0) })
            let nowSeconds = account.network.getApproximateRemoteTimestamp()
            let aging = newest.map { newest in (newest.parts.map(\.date).min() ?? 0) < nowSeconds + self.refreshBefore } ?? false
            let older = parts.filter { part in newest.map { part.rev < $0.rev } ?? false }.map(\.messageId)
            if !newerHere && !aging {
                // Already in step: only clear out leftovers of older writes.
                if !older.isEmpty {
                    let _ = chitgramDeleteScheduledMessages(account: account, peerId: selfId, ids: older).startStandalone()
                }
                self.finish()
                return
            }
            var merged = cloud
            for (key, item) in local where item.at > (merged[key]?.at ?? 0) {
                merged[key] = item
            }
            self.write(account: account, settings: merged, completion: { ok in
                // The new copy is complete: every older one can go.
                if ok {
                    let stale = parts.filter { part in newest.map { part.rev <= $0.rev } ?? true }.map(\.messageId)
                    if !stale.isEmpty {
                        let _ = chitgramDeleteScheduledMessages(account: account, peerId: selfId, ids: stale).startStandalone()
                    }
                }
                self.finish()
            })
        })
    }

    private static func finish() {
        self.syncing = false
        if let next = self.syncAgain {
            self.syncAgain = nil
            Queue.mainQueue().justDispatch {
                self.sync(context: next)
            }
        }
    }

    // MARK: The cloud copy

    private static func parse(_ post: ChitgramChannelPost) -> Part? {
        let lines = post.text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(self.tag) }) else {
            return nil
        }
        let head = lines[index].trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard head.count >= 5, head[1] == self.version, let rev = Int64(head[2]), let part = Int(head[3]), let total = Int(head[4]) else {
            return nil
        }
        let data = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
        return Part(rev: rev, part: part, total: total, data: data, messageId: post.id, date: post.date)
    }

    /// The newest copy whose parts are all there; a copy still being written is skipped.
    private static func newestComplete(_ parts: [Part]) -> (rev: Int64, settings: [String: Item], parts: [Part])? {
        let groups = Dictionary(grouping: parts, by: \.rev)
        for rev in groups.keys.sorted(by: >) {
            guard let group = groups[rev], let total = group.first?.total, total > 0 else {
                continue
            }
            var pieces: [String] = []
            for index in 1 ... total {
                guard let piece = group.first(where: { $0.part == index }) else {
                    break
                }
                pieces.append(piece.data)
            }
            guard pieces.count == total, let json = ChitgramGzip.unpack(pieces.joined()), let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            var settings: [String: Item] = [:]
            for (key, value) in object {
                guard let entry = value as? [String: Any] else {
                    continue
                }
                let type = entry["t"] as? String ?? ""
                let text: String
                if let string = entry["v"] as? String {
                    text = string
                } else if let number = entry["v"] as? NSNumber {
                    text = number.stringValue
                } else {
                    text = ""
                }
                let at = (entry["a"] as? NSNumber)?.int64Value ?? 0
                settings[key] = Item(type: type, value: text, at: at)
            }
            return (rev, settings, group)
        }
        return nil
    }

    private static func write(account: Account, settings: [String: Item], completion: @escaping (Bool) -> Void) {
        var object: [String: Any] = [:]
        for (key, item) in settings {
            object[key] = ["t": item.type, "v": item.value, "a": NSNumber(value: item.at)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8), let packed = ChitgramGzip.pack(json) else {
            completion(false)
            return
        }
        let rev = self.now()
        var chunks: [String] = []
        var start = packed.startIndex
        while start < packed.endIndex {
            let end = packed.index(start, offsetBy: self.chunk, limitedBy: packed.endIndex) ?? packed.endIndex
            chunks.append(String(packed[start ..< end]))
            start = end
        }
        let texts = chunks.enumerated().map { index, data in "\(self.head)\n\(self.tag) \(self.version) \(rev) \(index + 1) \(chunks.count)\n\(data)" }
        let base = account.network.getApproximateRemoteTimestamp() + self.keepSeconds
        let selfId = account.peerId

        // One at a time, in order; false on the first failure.
        func send(_ index: Int) {
            if index >= texts.count {
                completion(true)
                return
            }
            let _ = (chitgramScheduleText(account: account, peerId: selfId, text: texts[index], scheduleDate: base + Int32(index))
            |> deliverOnMainQueue).startStandalone(next: { outcome in
                if case .queued = outcome {
                    send(index + 1)
                } else {
                    completion(false)
                }
            })
        }
        send(0)
    }
}
