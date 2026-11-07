// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Runs the delayed half of a request. Tests inject a scheduler they run by hand.
@MainActor
public protocol ReviewPromptScheduling {
    /// Runs `work` on the main actor after `delay` seconds.
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// The default scheduler: the main dispatch queue.
public struct ReviewPromptMainQueueScheduler: ReviewPromptScheduling {
    nonisolated public init() {
    }

    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            work()
        }
    }
}
