import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// One message the auto messenger put into a chat's scheduled list: its id there and when it goes out.
public struct ChitgramQueuedMessage: Equatable {
    public let id: Int32
    public let date: Int32
}

/// What one auto messenger request came back with. A refused request carries Telegram's error text
/// (`FLOOD_WAIT_120`, `CHAT_WRITE_FORBIDDEN`, …), which the caller turns into a decision.
public enum ChitgramScheduleOutcome: Equatable {
    case queued([ChitgramQueuedMessage])
    case done
    case failed(String)
}

private func chitgramQueuedMessages(_ updates: Api.Updates) -> [ChitgramQueuedMessage] {
    var result: [ChitgramQueuedMessage] = []
    for update in updates.allUpdates {
        if case let .updateNewScheduledMessage(updateData) = update, case let .message(messageData) = updateData.message {
            // A scheduled message carries its send time in `date`.
            result.append(ChitgramQueuedMessage(id: messageData.id, date: messageData.date))
        }
    }
    return result
}

private func chitgramErrorText(_ error: MTRpcError) -> String {
    return error.errorDescription ?? "UNKNOWN"
}

private func chitgramInputPeers(account: Account, _ first: EnginePeer.Id, _ second: EnginePeer.Id) -> Signal<(Api.InputPeer, Api.InputPeer)?, NoError> {
    return account.postbox.transaction { transaction -> (Api.InputPeer, Api.InputPeer)? in
        guard let firstPeer = transaction.getPeer(first).flatMap(apiInputPeer), let secondPeer = transaction.getPeer(second).flatMap(apiInputPeer) else {
            return nil
        }
        return (firstPeer, secondPeer)
    }
}

/// Puts `text` into the chat's scheduled list, to go out at `scheduleDate` (Android `AutoPost.buildRequest`, typed
/// variants). Flood waits come back as errors instead of being waited out: the auto messenger paces itself.
public func chitgramScheduleText(account: Account, peerId: EnginePeer.Id, text: String, scheduleDate: Int32) -> Signal<ChitgramScheduleOutcome, NoError> {
    return chitgramInputPeer(account: account, peerId: peerId)
    |> mapToSignal { inputPeer -> Signal<ChitgramScheduleOutcome, NoError> in
        guard let inputPeer else {
            return .single(.failed("PEER_ID_INVALID"))
        }
        // schedule_date:flags.10
        let flags: Int32 = 1 << 10
        return account.network.request(Api.functions.messages.sendMessage(flags: flags, peer: inputPeer, replyTo: nil, message: text, randomId: Int64.random(in: Int64.min ... Int64.max), replyMarkup: nil, entities: nil, scheduleDate: scheduleDate, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, allowPaidStars: nil, suggestedPost: nil, richMessage: nil), automaticFloodWait: false)
        |> map { updates -> ChitgramScheduleOutcome in
            account.stateManager.addUpdates(updates)
            return .queued(chitgramQueuedMessages(updates))
        }
        |> `catch` { error -> Signal<ChitgramScheduleOutcome, NoError> in
            return .single(.failed(chitgramErrorText(error)))
        }
    }
}

/// Forwards one message into the chat's scheduled list. With `dropAuthor` it goes out as a normal message, without
/// the "forwarded from" header (Android `AutoPost.MODE_COPY`).
public func chitgramScheduleForward(account: Account, fromPeerId: EnginePeer.Id, messageId: Int32, toPeerId: EnginePeer.Id, dropAuthor: Bool, scheduleDate: Int32) -> Signal<ChitgramScheduleOutcome, NoError> {
    return chitgramInputPeers(account: account, fromPeerId, toPeerId)
    |> mapToSignal { peers -> Signal<ChitgramScheduleOutcome, NoError> in
        guard let (fromPeer, toPeer) = peers else {
            return .single(.failed("PEER_ID_INVALID"))
        }
        // schedule_date:flags.10, drop_author:flags.11
        var flags: Int32 = 1 << 10
        if dropAuthor {
            flags |= 1 << 11
        }
        return account.network.request(Api.functions.messages.forwardMessages(flags: flags, fromPeer: fromPeer, id: [messageId], randomId: [Int64.random(in: Int64.min ... Int64.max)], toPeer: toPeer, topMsgId: nil, replyTo: nil, scheduleDate: scheduleDate, scheduleRepeatPeriod: nil, sendAs: nil, quickReplyShortcut: nil, effect: nil, videoTimestamp: nil, allowPaidStars: nil, suggestedPost: nil), automaticFloodWait: false)
        |> map { updates -> ChitgramScheduleOutcome in
            account.stateManager.addUpdates(updates)
            return .queued(chitgramQueuedMessages(updates))
        }
        |> `catch` { error -> Signal<ChitgramScheduleOutcome, NoError> in
            return .single(.failed(chitgramErrorText(error)))
        }
    }
}

/// Removes queued messages from a chat's scheduled list, so they never go out.
public func chitgramDeleteScheduledMessages(account: Account, peerId: EnginePeer.Id, ids: [Int32]) -> Signal<ChitgramScheduleOutcome, NoError> {
    return chitgramInputPeer(account: account, peerId: peerId)
    |> mapToSignal { inputPeer -> Signal<ChitgramScheduleOutcome, NoError> in
        guard let inputPeer else {
            return .single(.failed("PEER_ID_INVALID"))
        }
        return account.network.request(Api.functions.messages.deleteScheduledMessages(peer: inputPeer, id: ids), automaticFloodWait: false)
        |> map { updates -> ChitgramScheduleOutcome in
            account.stateManager.addUpdates(updates)
            return .done
        }
        |> `catch` { error -> Signal<ChitgramScheduleOutcome, NoError> in
            return .single(.failed(chitgramErrorText(error)))
        }
    }
}
