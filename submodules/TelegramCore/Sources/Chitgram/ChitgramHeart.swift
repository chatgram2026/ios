import Foundation
import Postbox
import SwiftSignalKit

/// Chitgram's ".heart" (Android `HeartAnimator`): the message goes out as a plain red heart, and on this device only
/// the sent bubble then cycles through the nine coloured hearts and settles back on red.
///
/// The cycle is local on purpose: an edit per frame would hit the server's flood limit, mark the message "edited"
/// and reach the other side as one colour anyway. Here each frame rewrites only the stored copy's text, and the last
/// frame puts back exactly what the server holds, so nothing is left behind.
private let chitgramHearts = ["\u{2764}\u{FE0F}", "\u{1F9E1}", "\u{1F49B}", "\u{1F49A}", "\u{1F499}", "\u{1F49C}", "\u{1F90E}", "\u{1F5A4}", "\u{1F90D}"]

/// Full colour loops and the time per frame (Android: 3 and 320 ms).
private let chitgramHeartCycles = 3
private let chitgramHeartStep = 0.32

/// How long to wait for the server to confirm the sent heart before giving up (Android: 5 s).
private let chitgramHeartAttempts = 16
private let chitgramHeartAttemptDelay = 0.3

private let chitgramHeartQueue = Queue(name: "org.chitgram.heart")

/// Starts the cycle on the heart just sent to `peerId`, once it is confirmed by the server.
public func chitgramAnimateSentHeart(account: Account, peerId: EnginePeer.Id) {
    let postbox = account.postbox
    let sentAfter = Int32(Date().timeIntervalSince1970) - 10
    chitgramFindSentHeart(postbox: postbox, peerId: peerId, sentAfter: sentAfter, attempt: 0)
}

private func chitgramFindSentHeart(postbox: Postbox, peerId: PeerId, sentAfter: Int32, attempt: Int) {
    let _ = (postbox.transaction { transaction -> MessageId? in
        guard let index = transaction.getTopPeerMessageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud), let message = transaction.getMessage(index.id) else {
            return nil
        }
        if message.flags.contains(.Incoming) || message.text != chitgramHearts[0] || message.timestamp < sentAfter {
            return nil
        }
        return message.id
    }
    |> deliverOn(chitgramHeartQueue)).start(next: { id in
        if let id {
            chitgramShowHeartFrame(postbox: postbox, id: id, frame: 1)
        } else if attempt + 1 < chitgramHeartAttempts {
            chitgramHeartQueue.after(chitgramHeartAttemptDelay, {
                chitgramFindSentHeart(postbox: postbox, peerId: peerId, sentAfter: sentAfter, attempt: attempt + 1)
            })
        }
    })
}

private func chitgramShowHeartFrame(postbox: Postbox, id: MessageId, frame: Int) {
    let isLast = frame >= chitgramHearts.count * chitgramHeartCycles
    let text = isLast ? chitgramHearts[0] : chitgramHearts[frame % chitgramHearts.count]
    let _ = (postbox.transaction { transaction -> Bool in
        guard let message = transaction.getMessage(id), !message.flags.contains(.Incoming), chitgramHearts.contains(message.text) else {
            // Edited or deleted meanwhile: leave it alone.
            return false
        }
        transaction.updateMessage(id, update: { currentMessage in
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
                text: text,
                attributes: currentMessage.attributes,
                media: currentMessage.media
            ))
        })
        return true
    }
    |> deliverOn(chitgramHeartQueue)).start(next: { updated in
        if updated && !isLast {
            chitgramHeartQueue.after(chitgramHeartStep, {
                chitgramShowHeartFrame(postbox: postbox, id: id, frame: frame + 1)
            })
        }
    })
}
