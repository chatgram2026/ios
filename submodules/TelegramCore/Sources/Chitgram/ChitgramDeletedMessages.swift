import Foundation
import Postbox
import ChitgramCore

/// Chitgram: a message someone else deleted that "Save deleted messages" kept (Android `DeletedMsg`). The message
/// stays in the history with this mark instead of being removed; the bubble shows "🗑 Deleted" next to its time.
///
/// It survives because the server never sends a deleted message again, so nothing overwrites the stored copy.
public final class ChitgramDeletedMessageAttribute: MessageAttribute {
    public enum DeletedBy: Int32 {
        /// The other side (or anyone in a group) deleted it. Android: `By.You`, string 110.
        case them = 0
        /// A channel removed its post. Android: `By.Channel`, string 111.
        case channel = 1
    }

    public let deletedBy: DeletedBy
    /// When this device learned of the deletion.
    public let date: Int32

    public init(deletedBy: DeletedBy, date: Int32) {
        self.deletedBy = deletedBy
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.deletedBy = DeletedBy(rawValue: decoder.decodeInt32ForKey("b", orElse: 0)) ?? .them
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.deletedBy.rawValue, forKey: "b")
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

public extension Message {
    var chitgramDeletedAttribute: ChitgramDeletedMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? ChitgramDeletedMessageAttribute {
                return attribute
            }
        }
        return nil
    }
}

/// Keeps `id` instead of deleting it when the switch is on, or when it was kept before. Returns whether it stays.
///
/// Only messages that arrived or were sent for real are kept: a send still in flight or failed is deleted as usual,
/// otherwise a cancelled upload would linger as "deleted" forever (Android checks `send_state = 0` for the same reason).
func chitgramKeepsDeletedMessage(transaction: Transaction, id: MessageId) -> Bool {
    guard let message = transaction.getMessage(id) else {
        return false
    }
    if message.chitgramDeletedAttribute != nil {
        return true
    }
    if ChitgramPreferences.shared.int(.deletedCheckType) == ChitgramPreferences.DeletedCheckType.off.rawValue {
        return false
    }
    if message.flags.contains(.Unsent) || message.flags.contains(.Failed) || id.namespace != Namespaces.Message.Cloud {
        return false
    }
    let deletedBy: ChitgramDeletedMessageAttribute.DeletedBy
    if let channel = message.peers[id.peerId] as? TelegramChannel, case .broadcast = channel.info {
        deletedBy = .channel
    } else {
        deletedBy = .them
    }
    let date = Int32(Date().timeIntervalSince1970)
    transaction.updateMessage(id, update: { currentMessage in
        var attributes = currentMessage.attributes
        attributes.append(ChitgramDeletedMessageAttribute(deletedBy: deletedBy, date: date))
        return .update(StoreMessage(
            id: currentMessage.id,
            customStableId: nil,
            globallyUniqueId: currentMessage.globallyUniqueId,
            groupingKey: currentMessage.groupingKey,
            threadId: currentMessage.threadId,
            timestamp: currentMessage.timestamp,
            flags: StoreMessageFlags(currentMessage.flags),
            tags: currentMessage.tags,
            globalTags: currentMessage.globalTags,
            localTags: currentMessage.localTags,
            forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init),
            authorId: currentMessage.author?.id,
            text: currentMessage.text,
            attributes: attributes,
            media: currentMessage.media
        ))
    })
    return true
}

/// The ids of a server deletion that are really removed; the rest stay, marked.
func chitgramMessageIdsToDelete(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    return ids.filter { !chitgramKeepsDeletedMessage(transaction: transaction, id: $0) }
}

/// The same for a deletion addressed by global ids (private chats and basic groups).
func chitgramGlobalIdsToDelete(transaction: Transaction, globalIds: [Int32]) -> [Int32] {
    return globalIds.filter { globalId in
        guard let id = transaction.messageIdsForGlobalIds([globalId]).first else {
            return true
        }
        return !chitgramKeepsDeletedMessage(transaction: transaction, id: id)
    }
}
