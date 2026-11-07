import Foundation

/// Earlier versions of edited messages (Android `EditMessage`, "Save edited messages").
///
/// Kept in a file of its own rather than on the message: Telegram replaces a stored message with the server's copy
/// whenever it fetches it again, which would drop anything attached to it. Device-only, like on Android: never
/// synced, never uploaded.
public final class ChitgramEditHistory {
    public struct Version: Codable, Equatable {
        public let text: String
        /// When this text was current from: the message's date, or the date of the edit that produced it.
        public let date: Int32

        public init(text: String, date: Int32) {
            self.text = text
            self.date = date
        }
    }

    public struct MessageKey: Hashable {
        public let accountPeerId: Int64
        public let peerId: Int64
        public let namespace: Int32
        public let id: Int32

        public init(accountPeerId: Int64, peerId: Int64, namespace: Int32, id: Int32) {
            self.accountPeerId = accountPeerId
            self.peerId = peerId
            self.namespace = namespace
            self.id = id
        }

        fileprivate var stringValue: String {
            return "\(self.accountPeerId):\(self.peerId):\(self.namespace):\(self.id)"
        }
    }

    private struct Entry: Codable {
        var key: String
        var versions: [Version]
    }

    /// Android keeps the newest 10 000 edited messages; so does this.
    private static let maxEntries = 10000

    public static let shared = ChitgramEditHistory()

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "org.chitgram.edit-history", qos: .utility)
    private var fileURL: URL?
    /// nil until the file has been read; reads before that answer empty instead of blocking.
    private var entries: [String: [Version]]?
    /// Keys oldest first, for trimming.
    private var order: [String] = []
    private var saveScheduled = false

    private init() {
    }

    /// Where the history lives; reads it in the background. Called at launch.
    public func configure(directory: URL) {
        let url = directory.appendingPathComponent("chitgram-edit-history.json")
        self.lock.lock()
        self.fileURL = url
        self.lock.unlock()

        self.ioQueue.async {
            var loaded: [Entry] = []
            if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                loaded = decoded
            }
            self.lock.lock()
            var entries = self.entries ?? [:]
            var order: [String] = []
            for entry in loaded where entries[entry.key] == nil {
                entries[entry.key] = entry.versions
                order.append(entry.key)
            }
            // Edits recorded while the file was still being read come after the stored ones.
            for key in self.order where !order.contains(key) {
                order.append(key)
            }
            self.entries = entries
            self.order = order
            self.lock.unlock()
        }
    }

    /// The earlier versions of a message, oldest first; empty when there are none (or not loaded yet).
    public func versions(_ key: MessageKey) -> [Version] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries?[key.stringValue] ?? []
    }

    /// Records the text a message had before an edit.
    public func record(_ key: MessageKey, previous: Version) {
        let stringKey = key.stringValue
        self.lock.lock()
        var entries = self.entries ?? [:]
        var versions = entries[stringKey] ?? []
        if versions.last?.text == previous.text {
            self.lock.unlock()
            return
        }
        versions.append(previous)
        if entries[stringKey] == nil {
            self.order.append(stringKey)
        } else if let index = self.order.firstIndex(of: stringKey) {
            self.order.remove(at: index)
            self.order.append(stringKey)
        }
        entries[stringKey] = versions
        while self.order.count > ChitgramEditHistory.maxEntries {
            let removed = self.order.removeFirst()
            entries.removeValue(forKey: removed)
        }
        self.entries = entries
        let shouldSchedule = !self.saveScheduled
        self.saveScheduled = true
        self.lock.unlock()

        if shouldSchedule {
            // Several edits in a row become one write.
            self.ioQueue.asyncAfter(deadline: .now() + 1.0) {
                self.save()
            }
        }
    }

    private func save() {
        self.lock.lock()
        self.saveScheduled = false
        let url = self.fileURL
        let entries = self.entries ?? [:]
        let snapshot = self.order.compactMap { key -> Entry? in
            return entries[key].flatMap { Entry(key: key, versions: $0) }
        }
        self.lock.unlock()

        guard let url, let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        try? data.write(to: url, options: [.atomic])
    }
}
