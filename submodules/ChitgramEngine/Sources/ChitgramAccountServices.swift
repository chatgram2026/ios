import Foundation
import UIKit
import SwiftSignalKit
import AccountContext
import TelegramCore
import ChitgramCore

/// What Chitgram runs in the background of each signed-in account in the main app: the auto answer now, the
/// settings sync, auto messenger top-up and keyword watch as they are ported. Created by the account's context.
public final class ChitgramAccountServices {
    private let autoAnswer: ChitgramAutoAnswer
    private let autoAcceptJoin: ChitgramAutoAcceptJoin
    private let messageReminder: ChitgramMessageReminder
    private let keywordWatch: ChitgramKeywordWatch
    private var foregroundObserver: NSObjectProtocol?

    public init(context: AccountContext) {
        self.autoAnswer = ChitgramAutoAnswer(context: context)
        self.autoAcceptJoin = ChitgramAutoAcceptJoin(context: context)
        self.messageReminder = ChitgramMessageReminder(context: context)
        self.keywordWatch = ChitgramKeywordWatch(context: context)
        // Chitgram badges: lookups through Firestore, and this account's own badge.
        ChitgramBadgeService.start(context: context)
        // Saved media of kept deleted messages goes back into a cache that was cleared (Android ChitgramArchive).
        chitgramRestoreArchivedMedia(account: context.account)
        // Starts listening for the auto answer switch, which clears the answered chats when turned off.
        let _ = ChitgramAnsweredChats.shared
        // Chitgram Premium: the prices and this account's status, read again at every launch (Android: on resume).
        ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: context.account.peerId)
        let accountPeerId = context.account.peerId
        let _ = (ChitgramPremium.refreshPlans(context: context)
        |> then(ChitgramPremium.refresh(context: context) |> map { _ -> Bool in return true })
        |> deliverOnMainQueue).startStandalone(completed: {
            ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: accountPeerId)
            // The own badge follows Premium (created with it, its end date kept current).
            ChitgramBadges.shared.refresh(accountPeerId.id._internalGetInt64Value())
            // Auto messenger: tops the server queue up; the limits it applies depend on Premium.
            ChitgramAutoPost.refill(context: context)
            // Admin folders follow rights that changed while the app was closed.
            ChitgramAdminFolders.sync(context: context)
            // The owner's notices from the same pins: maintenance, a required or a newer version.
            ChitgramAppNotices.show(context: context)
            // Chitgram's settings shared with the account's other devices (Android ChitgramCloud).
            ChitgramCloud.onResume(context: context)
        })
        // Android refills on every resume (throttled to once in 10 minutes).
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak context] _ in
            guard let context else {
                return
            }
            ChitgramAutoPost.refill(context: context)
            ChitgramAdminFolders.sync(context: context)
            ChitgramAppNotices.show(context: context)
            ChitgramCloud.onResume(context: context)
            chitgramRestoreArchivedMedia(account: context.account)
        })
    }

    deinit {
        if let foregroundObserver = self.foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
}
