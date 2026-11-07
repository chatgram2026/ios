import Foundation
import UIKit
import SwiftSignalKit
import AccountContext
import TelegramCore
import ChitgramCore

/// What Chitgram runs in the background of each signed-in account in the main app. Created by the account's context.
///
/// On the Novagram base (branch chitgram-nova) only Chitgram Premium and what follows it run here: the prices and this
/// account's status, the badges, the owner's notices from the channel pins and the settings shared with the account's
/// other devices (the Premium payment locks among them). Novagram's own modules do the rest of the old port's work
/// (auto accept, admin folders, unread reminder); auto answer, auto messenger and keyword watch are not ported yet.
public final class ChitgramAccountServices {
    private var foregroundObserver: NSObjectProtocol?

    public init(context: AccountContext) {
        // Chitgram badges: lookups through Firestore, and this account's own badge.
        ChitgramBadgeService.start(context: context)
        // Chitgram Premium: the prices and this account's status, read again at every launch (Android: on resume).
        ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: context.account.peerId)
        let accountPeerId = context.account.peerId
        let _ = (ChitgramPremium.refreshPlans(context: context)
        |> then(ChitgramPremium.refresh(context: context) |> map { _ -> Bool in return true })
        |> deliverOnMainQueue).startStandalone(completed: {
            ChitgramKeywords.shared.isPremium = ChitgramPremium.isActive(accountPeerId: accountPeerId)
            // The own badge follows Premium (created with it, its end date kept current).
            ChitgramBadges.shared.refresh(accountPeerId.id._internalGetInt64Value())
            // The owner's notices from the same pins: maintenance, a required or a newer version.
            ChitgramAppNotices.show(context: context)
            // Chitgram's settings shared with the account's other devices (Android ChitgramCloud).
            ChitgramCloud.onResume(context: context)
        })
        // Android does these on every resume (each throttled on its own).
        self.foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak context] _ in
            guard let context else {
                return
            }
            ChitgramAppNotices.show(context: context)
            ChitgramCloud.onResume(context: context)
        })
    }

    deinit {
        if let foregroundObserver = self.foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
}
