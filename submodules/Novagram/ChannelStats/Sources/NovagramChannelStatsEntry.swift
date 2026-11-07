import Foundation
import UIKit
import SwiftSignalKit
import AccountContext

// Chitgram: Novagram's hidden admin statistics screen ran on its closed NovagramInsights SDK and its own server. The
// entry stays for the Settings hooks; the row is never shown.
public enum NovagramChannelStatsEntry {
    public static let revealDuration: TimeInterval = 20.0

    public static func refreshing<T>(_ signal: Signal<T, NoError>) -> Signal<T, NoError> {
        return signal
    }

    public static func isRowVisible(context: AccountContext) -> Bool {
        return false
    }

    public static func revealAction(
        context: AccountContext,
        authorize: @escaping (UIViewController, String, @escaping (Bool) -> Void) -> Void
    ) -> (() -> Void)? {
        return nil
    }

    public static func present(context: AccountContext) {
    }
}
