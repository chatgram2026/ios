import Foundation

/// Chitgram keyword watch (Android `keywords/KeywordWatch`): the words a user waits for in any chat, and what was
/// found. Matching is a plain case-insensitive substring, with the apostrophe variants of Uzbek folded onto one:
/// "kvartira" must find "kvartirani", and o'zi / oʻzi / oʼzi are one word to a person.
public final class ChitgramKeywords {
    public struct Hit: Codable, Equatable {
        public let word: String
        public let text: String
        public let chatTitle: String
        public let date: Int32
    }

    /// Android: 2 words free, 300 with Chitgram Premium.
    public static let freeWords = 2
    public static let premiumWords = 300
    private static let maxHits = 200

    public static let shared = ChitgramKeywords()

    private static let wordsKey = "keyword_words"
    private static let enabledKey = "keyword_enabled"
    private static let hitsKey = "chitgram_keyword_hits"

    private let lock = NSLock()

    private init() {
    }

    private var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    public var isEnabled: Bool {
        get {
            return self.defaults.bool(forKey: ChitgramKeywords.enabledKey)
        }
        set {
            self.defaults.set(newValue, forKey: ChitgramKeywords.enabledKey)
            NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": ChitgramKeywords.enabledKey])
        }
    }

    /// The watched words, as typed, newline-separated on disk as on Android.
    public var words: [String] {
        let stored = self.defaults.string(forKey: ChitgramKeywords.wordsKey) ?? ""
        return stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public var maxWords: Int {
        // Raised to premiumWords once Chitgram Premium is ported.
        return ChitgramKeywords.freeWords
    }

    /// Adds a word; false when it is empty, already there, or over the limit.
    public func add(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        var current = self.words
        if current.count >= self.maxWords || current.contains(where: { ChitgramKeywords.normalise($0) == ChitgramKeywords.normalise(trimmed) }) {
            return false
        }
        current.append(trimmed)
        self.store(current)
        return true
    }

    public func remove(at index: Int) {
        var current = self.words
        guard index >= 0, index < current.count else {
            return
        }
        current.remove(at: index)
        self.store(current)
    }

    private func store(_ words: [String]) {
        self.defaults.set(words.joined(separator: "\n"), forKey: ChitgramKeywords.wordsKey)
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": ChitgramKeywords.wordsKey])
    }

    public static func normalise(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.lowercased() {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{02BB}", "\u{02BC}", "`", "\u{00B4}":
                result.append("'")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// The first watched word that occurs in `text`.
    public func match(_ text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }
        let haystack = ChitgramKeywords.normalise(text)
        return self.words.first(where: { haystack.contains(ChitgramKeywords.normalise($0)) })
    }

    /// Found messages, newest first.
    public var hits: [Hit] {
        guard let data = self.defaults.data(forKey: ChitgramKeywords.hitsKey), let hits = try? JSONDecoder().decode([Hit].self, from: data) else {
            return []
        }
        return hits
    }

    public func record(word: String, text: String, chatTitle: String, date: Int32) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var hits = self.hits
        hits.insert(Hit(word: word, text: text, chatTitle: chatTitle, date: date), at: 0)
        if hits.count > ChitgramKeywords.maxHits {
            hits.removeLast(hits.count - ChitgramKeywords.maxHits)
        }
        if let data = try? JSONEncoder().encode(hits) {
            self.defaults.set(data, forKey: ChitgramKeywords.hitsKey)
        }
    }
}
