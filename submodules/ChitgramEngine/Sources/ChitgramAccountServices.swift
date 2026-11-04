import Foundation
import AccountContext

/// What Chitgram runs in the background of each signed-in account in the main app: the auto answer now, the
/// settings sync, auto messenger top-up and keyword watch as they are ported. Created by the account's context.
public final class ChitgramAccountServices {
    private let autoAnswer: ChitgramAutoAnswer
    private let autoAcceptJoin: ChitgramAutoAcceptJoin
    private let messageReminder: ChitgramMessageReminder

    public init(context: AccountContext) {
        self.autoAnswer = ChitgramAutoAnswer(context: context)
        self.autoAcceptJoin = ChitgramAutoAcceptJoin(context: context)
        self.messageReminder = ChitgramMessageReminder(context: context)
        // Starts listening for the auto answer switch, which clears the answered chats when turned off.
        let _ = ChitgramAnsweredChats.shared
    }
}
