import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram auto-accept of join requests (Android `AutoAcceptJoin`): when the server tells an admin that a chat has
/// requests waiting, they are all approved in one call. Cheap while off: the switch is read first.
final class ChitgramAutoAcceptJoin {
    private weak var context: AccountContext?
    private var disposable: Disposable?

    init(context: AccountContext) {
        self.context = context
        self.disposable = (ChitgramPendingJoinRequests.shared.chats(accountPeerId: context.account.peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] peerId in
            guard let self, let context = self.context, ChitgramPreferences.shared.bool(.autoAcceptJoin) else {
                return
            }
            let _ = chitgramApproveAllJoinRequests(account: context.account, peerId: peerId).startStandalone()
        })
    }

    deinit {
        self.disposable?.dispose()
    }
}
