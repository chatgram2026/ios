import Foundation

/// Chitgram's own switches, the iOS side of Android's "db" shared preferences.
///
/// The keys are Android's, word for word, because the settings sync (`ChitgramCloud` on Android) writes them into
/// the account's Saved Messages under these names: an iPhone and an Android phone on the same account share one
/// set of choices.
///
/// Values live in the app group's defaults, so the notification and share extensions see the same switches, and are
/// cached in memory: several of them are read on hot paths (every read receipt, every typing update).
public final class ChitgramPreferences {
    public enum Key: String, CaseIterable {
        // Stories
        case ghostStory = "ghost_story"
        case hideStory = "hide_story"
        case hideStoryButtonInMenu = "hide_story_for_visibility_on_action_bar"
        case storyDownload = "story_download"
        // Messages
        case saveEdited = "edit"
        case deletedCheckType = "delete_check_key"
        case archiveMedia = "archive_media"
        // Auto answer
        case autoAnswerActive = "auto_answer_active"
        case autoAnswerText = "auto_answer_text"
        // Ghost mode
        case ghost = "ghost"
        case ghostHideRead = "ghost_hide_read"
        case ghostHideOnline = "ghost_hide_online"
        case ghostHideTyping = "ghost_hide_typing"
        case ghostHideUpload = "ghost_hide_upload"
        case ghostButton = "ghost_btn_visibility_on_action_bar"
        case hideSponsored = "hide_sponsored"
        // Confirmations
        case confirmSticker = "confirm_sticker"
        case confirmVoice = "confirm_voice"
        case confirmGif = "confirm_gif"
        // Round video, composer
        case roundCameraFront = "round_camera_front"
        case dictationMicEnabled = "dictation_mic_enabled"
        // Folders and tabs
        case folderIconMode = "folder_icon_mode"
        case folderIcons = "folder_icons"
        case hideTabs = "hide_tabs"
        // Channels
        case autoAcceptJoin = "auto_accept_join"
        // Reminder
        case reminderEnabled = "reminder_enabled"
        case reminderDelayMin = "reminder_delay_min"
        case reminderSound = "reminder_sound"
        // Security
        case apkShield = "apk_shield"

        /// Android's default for the key.
        public var defaultValue: Any {
            switch self {
            case .hideStoryButtonInMenu, .roundCameraFront, .dictationMicEnabled:
                return true
            case .deletedCheckType, .reminderSound:
                return 0
            case .reminderDelayMin:
                return 5
            case .autoAnswerText, .folderIcons:
                return ""
            default:
                return false
            }
        }
    }

    /// `delete_check_key` values, as on Android (`DeletedMsg`).
    public enum DeletedCheckType: Int {
        case off = 0
        case keep = 1
    }

    /// Posted on the main queue after a value changed; `userInfo["key"]` is the raw key.
    public static let didChangeNotification = Notification.Name("ChitgramPreferencesDidChange")

    public static let shared = ChitgramPreferences()

    private let lock = NSLock()
    private var defaults: UserDefaults = .standard
    private var cache: [String: Any] = [:]

    private init() {
    }

    /// Point the store at the app group. Called once at launch, before anything reads a switch.
    public func configure(appGroupName: String) {
        guard let defaults = UserDefaults(suiteName: appGroupName) else {
            return
        }
        self.lock.lock()
        self.defaults = defaults
        self.cache.removeAll()
        self.lock.unlock()
    }

    /// The defaults behind the store, for Chitgram data that is not a switch (lists kept under Android's keys).
    public var userDefaults: UserDefaults {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.defaults
    }

    private func value(_ key: Key) -> Any {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if let value = self.cache[key.rawValue] {
            return value
        }
        let value = self.defaults.object(forKey: key.rawValue) ?? key.defaultValue
        self.cache[key.rawValue] = value
        return value
    }

    public func bool(_ key: Key) -> Bool {
        return (self.value(key) as? Bool) ?? ((key.defaultValue as? Bool) ?? false)
    }

    public func int(_ key: Key) -> Int {
        return (self.value(key) as? Int) ?? ((key.defaultValue as? Int) ?? 0)
    }

    public func string(_ key: Key) -> String {
        return (self.value(key) as? String) ?? ((key.defaultValue as? String) ?? "")
    }

    public func set(_ value: Bool, for key: Key) {
        self.store(value, for: key)
    }

    public func set(_ value: Int, for key: Key) {
        self.store(value, for: key)
    }

    public func set(_ value: String, for key: Key) {
        self.store(value, for: key)
    }

    private func store(_ value: Any, for key: Key) {
        self.lock.lock()
        self.cache[key.rawValue] = value
        let defaults = self.defaults
        self.lock.unlock()

        defaults.set(value, forKey: key.rawValue)
        // The time of the change is what lets it win over an older value from another device in the settings sync.
        var times = defaults.dictionary(forKey: ChitgramPreferences.changeTimesKey) ?? [:]
        times[key.rawValue] = Int64(Date().timeIntervalSince1970 * 1000.0)
        defaults.set(times, forKey: ChitgramPreferences.changeTimesKey)

        let notify = {
            NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: self, userInfo: ["key": key.rawValue])
        }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async(execute: notify)
        }
    }

    /// Makes open screens redraw without a value changing, e.g. to put a switch back after a refused or cancelled
    /// action.
    public func notifyChanged() {
        let notify = {
            NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: self, userInfo: ["key": ""])
        }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async(execute: notify)
        }
    }

    /// When each key was last changed on this device, in milliseconds (Android's `System.currentTimeMillis`).
    public func changeTime(_ key: Key) -> Int64? {
        self.lock.lock()
        let defaults = self.defaults
        self.lock.unlock()
        return (defaults.dictionary(forKey: ChitgramPreferences.changeTimesKey)?[key.rawValue] as? NSNumber)?.int64Value
    }

    private static let changeTimesKey = "chitgram_cloud_times"

    /// When each raw key was last changed on this device, in milliseconds; for the settings sync.
    public func changeTimes() -> [String: Int64] {
        let defaults = self.userDefaults
        var result: [String: Int64] = [:]
        for (key, value) in defaults.dictionary(forKey: ChitgramPreferences.changeTimesKey) ?? [:] {
            if let number = value as? NSNumber {
                result[key] = number.int64Value
            }
        }
        return result
    }

    /// Records a change of a raw key that is not set through `set(_:for:)` (e.g. the text style).
    public func setChangeTime(_ rawKey: String, _ at: Int64) {
        let defaults = self.userDefaults
        var times = defaults.dictionary(forKey: ChitgramPreferences.changeTimesKey) ?? [:]
        times[rawKey] = at
        defaults.set(times, forKey: ChitgramPreferences.changeTimesKey)
    }

    /// Writes a value that came from another device with that device's change time; nil removes it. Posted with
    /// `userInfo["synced"] = true`, so the sync does not echo it back.
    public func applySynced(rawKey: String, value: Any?, at: Int64) {
        self.lock.lock()
        if let value {
            self.cache[rawKey] = value
        } else {
            self.cache.removeValue(forKey: rawKey)
        }
        let defaults = self.defaults
        self.lock.unlock()
        if let value {
            defaults.set(value, forKey: rawKey)
        } else {
            defaults.removeObject(forKey: rawKey)
        }
        self.setChangeTime(rawKey, at)
        let notify = {
            NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: self, userInfo: ["key": rawKey, "synced": true])
        }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.async(execute: notify)
        }
    }
}
