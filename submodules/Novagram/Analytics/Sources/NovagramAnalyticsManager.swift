import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import NovagramReviewPrompt

// Chitgram: Novagram counted devices and accounts on its own statistics server through its closed NovagramServices
// SDK. None of that is ours, so nothing is sent; the manager keeps the calls the app makes and still starts the
// rating prompt's login watch.
public final class NovagramAnalyticsManager {
    public static let shared = NovagramAnalyticsManager()

    private var started = false

    private init() {}

    /// Called once from AppDelegate after the shared account context is ready.
    public func start(sharedContext: SharedAccountContext) {
        if !self.started {
            self.started = true
            // Rating prompt: a login restarts its 3-day start delay.
            NovagramReviewPrompt.observeLogins(sharedContext: sharedContext)
        }
    }

    public func accountWillLogOut(accountId: AccountRecordId) {
    }

    /// No counters in this build.
    public func counts() -> Signal<(devices: Int?, accounts: Int?), NoError> {
        return .single((nil, nil))
    }
}
