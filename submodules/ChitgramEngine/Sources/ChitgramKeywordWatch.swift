import Foundation
import UserNotifications
import SwiftSignalKit
import TelegramCore
import AccountContext
import LocalizedPeerData
import ChitgramCore

/// Chitgram keyword watch (Android `KeywordWatch`): a notification when someone, in any chat, writes a watched word.
/// Our own messages, Saved Messages, service messages and secret chats are left alone, as on Android.
final class ChitgramKeywordWatch {
    private var disposable: Disposable?

    init(context: AccountContext) {
        let accountPeerId = context.account.peerId
        self.disposable = (context.account.stateManager.chitgramIncomingMessages
        |> deliverOnMainQueue).startStrict(next: { messages in
            let keywords = ChitgramKeywords.shared
            guard keywords.isEnabled, !keywords.words.isEmpty else {
                return
            }
            for message in messages {
                let peerId = message.id.peerId
                guard message.flags.contains(.Incoming), peerId != accountPeerId, peerId.namespace != Namespaces.Peer.SecretChat else {
                    continue
                }
                guard let word = keywords.match(message.text) else {
                    continue
                }
                let chatTitle = message.peers[peerId].flatMap { EnginePeer($0).compactDisplayTitle } ?? ""
                keywords.record(word: word, text: message.text, chatTitle: chatTitle, date: message.timestamp)

                let content = UNMutableNotificationContent()
                content.title = "\(chatTitle) · «\(word)»"
                content.body = message.text
                content.sound = .default
                let identifier = "chitgram.keyword.\(accountPeerId.toInt64()).\(peerId.toInt64()).\(message.id.id)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), withCompletionHandler: nil)
            }
        })
    }

    deinit {
        self.disposable?.dispose()
    }
}
