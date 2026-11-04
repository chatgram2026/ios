import Foundation
import SwiftSignalKit
import AccountContext
import ChitgramCore

/// What Chitgram runs in the background of each signed-in account in the main app: the auto answer now, the
/// settings sync, auto messenger top-up and keyword watch as they are ported. Created by the account's context.
public final class ChitgramAccountServices {
    private let autoAnswer: ChitgramAutoAnswer
    private let autoAcceptJoin: ChitgramAutoAcceptJoin
    private let messageReminder: ChitgramMessageReminder
    private let keywordWatch: ChitgramKeywordWatch

    public init(context: AccountContext) {
        self.autoAnswer = ChitgramAutoAnswer(context: context)
        self.autoAcceptJoin = ChitgramAutoAcceptJoin(context: context)
        self.messageReminder = ChitgramMessageReminder(context: context)
        self.keywordWatch = ChitgramKeywordWatch(context: context)
        // Starts listening for the auto answer switch, which clears the answered chats when turned off.
        let _ = ChitgramAnsweredChats.shared
        // Chitgram Premium: the prices and this account's status, read again at every launch (Android: on resume).
        ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: context.account.peerId)
        let accountPeerId = context.account.peerId
        let _ = (ChitgramPremium.refreshPlans(context: context)
        |> then(ChitgramPremium.refresh(context: context) |> map { _ -> Bool in return true })
        |> deliverOnMainQueue).startStandalone(completed: {
            ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: accountPeerId)
        })
    }
}
