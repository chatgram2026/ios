import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

/// A channel post as Chitgram reads it: the price pin of @chitgram_org, the post a Premium payment reacts to.
public struct ChitgramChannelPost: Equatable {
    public let id: Int32
    public let date: Int32
    public let text: String
}

private func chitgramPosts(_ result: Api.messages.Messages) -> [ChitgramChannelPost] {
    let messages: [Api.Message]
    switch result {
    case let .messages(messagesData):
        messages = messagesData.messages
    case let .messagesSlice(messagesSliceData):
        messages = messagesSliceData.messages
    case let .channelMessages(channelMessagesData):
        messages = channelMessagesData.messages
    case .messagesNotModified:
        messages = []
    }
    var posts: [ChitgramChannelPost] = []
    for message in messages {
        if case let .message(messageData) = message {
            posts.append(ChitgramChannelPost(id: messageData.id, date: messageData.date, text: messageData.message))
        }
    }
    return posts.sorted(by: { $0.date > $1.date })
}

private func chitgramInputPeer(account: Account, peerId: EnginePeer.Id) -> Signal<Api.InputPeer?, NoError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
}

/// The channel's pinned posts, newest first (Android `ChitgramPremium.refreshPlans`: `messages.search` with the pinned
/// filter). Empty when they cannot be read.
public func chitgramPinnedPosts(account: Account, peerId: EnginePeer.Id) -> Signal<[ChitgramChannelPost], NoError> {
    return chitgramInputPeer(account: account, peerId: peerId)
    |> mapToSignal { inputPeer -> Signal<[ChitgramChannelPost], NoError> in
        guard let inputPeer else {
            return .single([])
        }
        return account.network.request(Api.functions.messages.search(flags: 0, peer: inputPeer, q: "", fromId: nil, savedPeerId: nil, savedReaction: nil, topMsgId: nil, filter: .inputMessagesFilterPinned, minDate: 0, maxDate: 0, offsetId: 0, addOffset: 0, limit: 20, maxId: 0, minId: 0, hash: 0))
        |> map(chitgramPosts)
        |> `catch` { _ -> Signal<[ChitgramChannelPost], NoError> in
            return .single([])
        }
    }
}

/// The channel's latest posts, newest first.
public func chitgramRecentPosts(account: Account, peerId: EnginePeer.Id, limit: Int32) -> Signal<[ChitgramChannelPost], NoError> {
    return chitgramInputPeer(account: account, peerId: peerId)
    |> mapToSignal { inputPeer -> Signal<[ChitgramChannelPost], NoError> in
        guard let inputPeer else {
            return .single([])
        }
        return account.network.request(Api.functions.messages.getHistory(peer: inputPeer, offsetId: 0, offsetDate: 0, addOffset: 0, limit: limit, maxId: Int32.max, minId: 0, hash: 0))
        |> map(chitgramPosts)
        |> `catch` { _ -> Signal<[ChitgramChannelPost], NoError> in
            return .single([])
        }
    }
}

/// Sends `stars` as an anonymous paid ⭐ reaction to a post (Android `ChitgramPremium.sendReaction`). Gives nil when
/// the server took it, else its error text (`BALANCE_TOO_LOW`, …).
public func chitgramSendPaidReaction(account: Account, peerId: EnginePeer.Id, messageId: Int32, stars: Int32) -> Signal<String?, NoError> {
    return chitgramInputPeer(account: account, peerId: peerId)
    |> mapToSignal { inputPeer -> Signal<String?, NoError> in
        guard let inputPeer else {
            return .single("PEER_NOT_FOUND")
        }
        let randomPart = UInt64(UInt32(bitPattern: Int32.random(in: Int32.min ... Int32.max)))
        let timePart = UInt64(UInt32(bitPattern: Int32(Date().timeIntervalSince1970)))
        let randomId = Int64(bitPattern: (timePart << 32) | randomPart)
        return account.network.request(Api.functions.messages.sendPaidReaction(flags: 1 << 0, peer: inputPeer, msgId: messageId, count: stars, randomId: randomId, private: .paidReactionPrivacyAnonymous))
        |> map { updates -> String? in
            account.stateManager.addUpdates(updates)
            return nil
        }
        |> `catch` { error -> Signal<String?, NoError> in
            return .single(error.errorDescription ?? "UNKNOWN")
        }
    }
}
