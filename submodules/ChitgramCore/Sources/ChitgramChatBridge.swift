import Foundation

/// Lets a screen opened from a chat (its profile's menu) put text into that chat's input box: the open chat
/// registers itself while it is on screen. Main thread only.
public enum ChitgramChatBridge {
    private static var inserters: [Int64: (String) -> Bool] = [:]
    private static var dictators: [Int64: () -> Void] = [:]

    /// The open chat's dictation, started by its composer's mic button.
    public static func registerDictation(chat: Int64, start: @escaping () -> Void) {
        self.dictators[chat] = start
    }

    public static func dictate(chat: Int64) {
        self.dictators[chat]?()
    }

    /// `insert` returns false once its chat is gone.
    public static func register(chat: Int64, insert: @escaping (String) -> Bool) {
        self.inserters[chat] = insert
    }

    /// True when the chat took the text.
    public static func insert(chat: Int64, text: String) -> Bool {
        guard let insert = self.inserters[chat] else {
            return false
        }
        if insert(text) {
            return true
        }
        self.inserters.removeValue(forKey: chat)
        return false
    }
}
