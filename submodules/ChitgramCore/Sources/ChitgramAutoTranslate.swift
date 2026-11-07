import Foundation

/// Per-chat auto-translate of outgoing messages (Android `utils/AutoTranslate`): the first Send translates the typed
/// text into the chat's language and shows it in the input box, the next Send sends it. Chats are
/// `EnginePeer.Id.toInt64()` values (Android keys them by its own dialog ids, so the two do not share this).
public enum ChitgramAutoTranslate {
    private static let key = "chitgram_auto_translate"

    /// Languages offered, as Telegram's translation knows them.
    public static let languages: [String] = ["en", "ru", "uz", "tr", "kk", "ky", "tg", "az", "uk", "ar", "fa", "de", "fr", "es", "it", "pt", "zh", "ja", "ko", "hi", "id"]

    private static func map() -> [String: String] {
        return ChitgramPreferences.shared.userDefaults.dictionary(forKey: self.key) as? [String: String] ?? [:]
    }

    /// The chat's target language, or nil when auto-translate is off for it.
    public static func language(_ chat: Int64) -> String? {
        return self.map()["\(chat)"]
    }

    public static func setLanguage(_ chat: Int64, _ language: String?) {
        var map = self.map()
        map["\(chat)"] = language
        ChitgramPreferences.shared.userDefaults.set(map, forKey: self.key)
        ChitgramPreferences.shared.notifyChanged()
    }

    /// The language's own name for a picker, e.g. "O'zbek" or "English".
    public static func displayName(_ language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forLanguageCode: language) ?? language
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
