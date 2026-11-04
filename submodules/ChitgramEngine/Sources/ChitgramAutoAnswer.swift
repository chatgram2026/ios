import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram auto answer (Android `ui/auto_answer/AutoAnswer`): replies once, with the saved text, to the first
/// incoming message of each private chat. Opening the chat makes it answerable again; turning the switch off
/// forgets every chat answered so far.
///
/// iOS runs it while the app is running; a suspended app hears of a message only when it is opened again.
final class ChitgramAutoAnswer {
    // Weak: the account's context owns this service.
    private weak var context: AccountContext?
    private var disposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        self.disposable = (context.account.stateManager.chitgramIncomingMessages
        |> deliverOnMainQueue).startStrict(next: { [weak self] messages in
            self?.process(messages)
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    private func process(_ messages: [EngineMessage]) {
        guard let context = self.context else {
            return
        }
        let preferences = ChitgramPreferences.shared
        guard preferences.bool(.autoAnswerActive) else {
            return
        }
        let text = preferences.string(.autoAnswerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        for message in messages {
            let peerId = message.id.peerId
            // Private chats only, as on Android (`peer_id.user_id != 0`), never Saved Messages.
            guard peerId.namespace == Namespaces.Peer.CloudUser, peerId != context.account.peerId, message.flags.contains(.Incoming) else {
                continue
            }
            guard ChitgramAnsweredChats.shared.markAnswered(peerId.toInt64()) else {
                continue
            }
            for part in chitgramMessageParts(text) {
                let _ = context.engine.messages.enqueueOutgoingMessage(
                    to: peerId,
                    replyTo: EngineMessageReplySubject(messageId: message.id, quote: nil, innerSubject: nil),
                    content: .text(part, [])
                ).startStandalone()
            }
        }
    }
}

/// The chats already answered, Android's `answered_dialogs` (a JSON list of dialog ids, kept on the device).
public final class ChitgramAnsweredChats {
    public static let shared = ChitgramAnsweredChats()

    private static let key = "answered_dialogs"
    private let lock = NSLock()
    private var loaded: Set<Int64>?

    private init() {
        NotificationCenter.default.addObserver(forName: ChitgramPreferences.didChangeNotification, object: nil, queue: nil, using: { [weak self] notification in
            // Turning auto answer off forgets every chat answered so far.
            if (notification.userInfo?["key"] as? String) == ChitgramPreferences.Key.autoAnswerActive.rawValue, !ChitgramPreferences.shared.bool(.autoAnswerActive) {
                self?.forgetAll()
            }
        })
    }

    private var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private func current() -> Set<Int64> {
        if let loaded = self.loaded {
            return loaded
        }
        var result = Set<Int64>()
        if let string = self.defaults.string(forKey: ChitgramAnsweredChats.key), let data = string.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [NSNumber] {
            result = Set(list.map { $0.int64Value })
        }
        self.loaded = result
        return result
    }

    private func store(_ set: Set<Int64>) {
        self.loaded = set
        let list = set.map { NSNumber(value: $0) }
        if let data = try? JSONSerialization.data(withJSONObject: list), let string = String(data: data, encoding: .utf8) {
            self.defaults.set(string, forKey: ChitgramAnsweredChats.key)
        }
    }

    /// Records the chat as answered; false when it already was.
    func markAnswered(_ peerId: Int64) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var set = self.current()
        if set.contains(peerId) {
            return false
        }
        set.insert(peerId)
        self.store(set)
        return true
    }

    /// The user opened the chat: the next message in it may be answered again (Android `ChatActivity.createView`).
    public func forget(_ peerId: Int64) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        var set = self.current()
        if set.remove(peerId) != nil {
            self.store(set)
        }
    }

    private func forgetAll() {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.store([])
    }
}

/// Splits a long text into messages Telegram accepts, at a line break or a space when there is one near the end.
func chitgramMessageParts(_ text: String, limit: Int = 4096) -> [String] {
    var parts: [String] = []
    var rest = Substring(text)
    while rest.count > limit {
        let window = rest.prefix(limit)
        var cut = window.endIndex
        if let newline = window.lastIndex(of: "\n"), window.distance(from: window.startIndex, to: newline) > limit / 2 {
            cut = newline
        } else if let space = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: space) > limit / 2 {
            cut = space
        }
        let part = rest[rest.startIndex ..< cut].trimmingCharacters(in: .whitespacesAndNewlines)
        if !part.isEmpty {
            parts.append(part)
        }
        rest = rest[cut...]
        if let first = rest.first, first == "\n" || first == " " {
            rest = rest.dropFirst()
        }
    }
    let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    if !last.isEmpty {
        parts.append(last)
    }
    return parts
}
