import Foundation

/// Chitgram's per-chat choices (Android `ChatFenixSettings`), kept by chat id under Android's keys.
public enum ChitgramPerChat {
    /// Android `AutoTextAppender`: a chat's signature, added to the end of every text message sent there while on.
    public struct AutoText: Codable, Equatable {
        public var active: Bool
        public var text: String

        public init(active: Bool, text: String) {
            self.active = active
            self.text = text
        }
    }

    private static func autoTextKey(_ chatId: Int64) -> String {
        return "chitgram_auto_text_\(chatId)"
    }

    public static func autoText(_ chatId: Int64) -> AutoText {
        guard let data = ChitgramPreferences.shared.userDefaults.data(forKey: self.autoTextKey(chatId)), let value = try? JSONDecoder().decode(AutoText.self, from: data) else {
            return AutoText(active: false, text: "")
        }
        return value
    }

    public static func setAutoText(_ chatId: Int64, _ value: AutoText) {
        if let data = try? JSONEncoder().encode(value) {
            ChitgramPreferences.shared.userDefaults.set(data, forKey: self.autoTextKey(chatId))
        }
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": self.autoTextKey(chatId)])
    }

    /// The text to add to an outgoing message in this chat, if any.
    public static func signature(_ chatId: Int64) -> String? {
        let value = self.autoText(chatId)
        if value.active && !value.text.isEmpty {
            return value.text
        }
        return nil
    }

    /// Android `OneTimeVoice`, key `one_time_media_ids`: voice messages in these chats default to view-once.
    private static let oneTimeKey = "one_time_media_ids"
    private static let lock = NSLock()

    private static func oneTimeIds() -> Set<Int64> {
        let defaults = ChitgramPreferences.shared.userDefaults
        guard let string = defaults.string(forKey: self.oneTimeKey), let data = string.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [NSNumber] else {
            return []
        }
        return Set(list.map { $0.int64Value })
    }

    public static func isOneTimeMedia(_ chatId: Int64) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.oneTimeIds().contains(chatId)
    }

    public static func setOneTimeMedia(_ chatId: Int64, _ enabled: Bool) {
        self.lock.lock()
        var ids = self.oneTimeIds()
        if enabled {
            ids.insert(chatId)
        } else {
            ids.remove(chatId)
        }
        let list = ids.map { NSNumber(value: $0) }
        if let data = try? JSONSerialization.data(withJSONObject: list), let string = String(data: data, encoding: .utf8) {
            ChitgramPreferences.shared.userDefaults.set(string, forKey: self.oneTimeKey)
        }
        self.lock.unlock()
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": self.oneTimeKey])
    }
}
