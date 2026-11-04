import Foundation
import Postbox
import ChitgramCore

public extension ChitgramEditHistory.MessageKey {
    init(accountPeerId: EnginePeer.Id, messageId: EngineMessage.Id) {
        self.init(accountPeerId: accountPeerId.toInt64(), peerId: messageId.peerId.toInt64(), namespace: messageId.namespace, id: messageId.id)
    }
}

/// Chitgram: when "Save edited messages" is on, the text a message had before a real edit goes to
/// `ChitgramEditHistory`. Telegram also sends an edit for reactions, views and other changes that leave the text
/// alone; those record nothing (Android `ChitgramArchive.isRealEdit`).
func chitgramRecordEdit(accountPeerId: PeerId, previous: Message, updated: StoreMessage) {
    guard ChitgramPreferences.shared.bool(.saveEdited) else {
        return
    }
    guard previous.id.namespace == Namespaces.Message.Cloud, previous.text != updated.text, !previous.text.isEmpty else {
        return
    }
    let since = previous.editedTime ?? previous.timestamp
    ChitgramEditHistory.shared.record(
        ChitgramEditHistory.MessageKey(accountPeerId: accountPeerId, messageId: previous.id),
        previous: ChitgramEditHistory.Version(text: previous.text, date: since)
    )
}
