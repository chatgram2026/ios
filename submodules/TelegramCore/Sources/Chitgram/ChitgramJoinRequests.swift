import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// Chitgram: tells the auto-accept of join requests (Android `AutoAcceptJoin`) that a chat has requests waiting.
/// Fed by `updatePendingJoinRequests`, which the server sends to the chat's admins when someone asks to join.
public final class ChitgramPendingJoinRequests {
    public static let shared = ChitgramPendingJoinRequests()

    private let pipe = ValuePipe<(accountPeerId: PeerId, peerId: PeerId)>()

    private init() {
    }

    func note(accountPeerId: PeerId, peerId: PeerId) {
        self.pipe.putNext((accountPeerId, peerId))
    }

    /// The chats of this account that have just been told they have pending requests.
    public func chats(accountPeerId: EnginePeer.Id) -> Signal<EnginePeer.Id, NoError> {
        return self.pipe.signal()
        |> filter { item in
            return item.accountPeerId == accountPeerId
        }
        |> map { item -> EnginePeer.Id in
            return item.peerId
        }
    }
}

/// Approves every pending join request of the chat in one call (`messages.hideAllChatJoinRequests`); the server
/// refuses it unless the account may invite there, and a refusal is dropped.
public func chitgramApproveAllJoinRequests(account: Account, peerId: EnginePeer.Id) -> Signal<Never, NoError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    }
    |> mapToSignal { inputPeer -> Signal<Never, NoError> in
        guard let inputPeer else {
            return .complete()
        }
        return account.network.request(Api.functions.messages.hideAllChatJoinRequests(flags: 1 << 0, peer: inputPeer, link: nil))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.Updates?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { updates -> Signal<Never, NoError> in
            if let updates {
                account.stateManager.addUpdates(updates)
            }
            return .complete()
        }
    }
}
