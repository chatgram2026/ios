import Foundation

/// Chitgram's own UI strings, the same table and ids as the Android app's `LanguageCode.kt`
/// (`TitleLanguages(id, en, uz, ru)`), so a row is named by the same number on both platforms.
///
/// The language follows the app's language the way Android does: Uzbek and Russian have their own text,
/// every other language gets English.
public enum ChitgramStrings {
    public enum Language: Int {
        case en = 0
        case uz = 1
        case ru = 2

        public init(languageCode: String) {
            let base = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? ""
            switch base {
            case "uz":
                self = .uz
            case "ru":
                self = .ru
            default:
                self = .en
            }
        }
    }

    private static let table: [[String]] = {
        guard let data = chitgramStringsJSON.data(using: .utf8), let table = (try? JSONSerialization.jsonObject(with: data)) as? [[String]] else {
            assertionFailure("ChitgramStrings: the generated table does not parse")
            return []
        }
        assert(table.count == chitgramStringsCount)
        return table
    }()

    private static let lock = NSLock()
    private static var currentLanguage: Language = .en

    /// Set from the app's presentation data whenever the app language changes.
    public static func setLanguageCode(_ languageCode: String) {
        let language = Language(languageCode: languageCode)
        self.lock.lock()
        self.currentLanguage = language
        self.lock.unlock()
    }

    public static var language: Language {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.currentLanguage
    }

    /// The string `id` in the current language; empty for an id the table does not have, as on Android.
    public static func get(_ id: Int) -> String {
        return self.get(id, language: self.language)
    }

    public static func get(_ id: Int, language: Language) -> String {
        guard id >= 0, id < self.table.count else {
            return ""
        }
        let entry = self.table[id]
        guard language.rawValue < entry.count else {
            return ""
        }
        return entry[language.rawValue]
    }

    /// The string `id` with Java-style positional arguments (`%1$@`, `%2$d`) filled in.
    public static func format(_ id: Int, _ arguments: CVarArg...) -> String {
        return String(format: self.get(id), arguments: arguments)
    }
}
