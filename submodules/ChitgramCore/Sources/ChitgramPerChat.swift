import Foundation

/// Chitgram's per-chat choices (Android `ChatFenixSettings`), kept by chat id under Android's keys.
public enum ChitgramPerChat {
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
