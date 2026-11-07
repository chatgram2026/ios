// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Whether the rules allow a request right now, and why not. For host logs and tests.
public enum ReviewPromptDecision: Equatable, Sendable, CustomStringConvertible {
    /// The rules allow a request.
    case eligible
    /// The host passed an empty app version; nothing is asked or stored.
    case invalidAppVersion
    /// No counted feature has reached ``ReviewPromptPolicy/requiredSuccesses`` yet.
    case notEnoughUse
    /// Too soon after the start; allowed again at `until`.
    case tooSoonAfterStart(until: Date)
    /// This app version already made its one request.
    case alreadyRequestedThisVersion
    /// Too soon after the previous request; allowed again at `until`.
    case cooldown(until: Date)

    public var isEligible: Bool {
        return self == .eligible
    }

    public var description: String {
        switch self {
        case .eligible:
            return "eligible"
        case .invalidAppVersion:
            return "invalidAppVersion"
        case .notEnoughUse:
            return "notEnoughUse"
        case let .tooSoonAfterStart(until):
            return "tooSoonAfterStart(until: \(until))"
        case .alreadyRequestedThisVersion:
            return "alreadyRequestedThisVersion"
        case let .cooldown(until):
            return "cooldown(until: \(until))"
        }
    }
}

/// What one call to `requestReviewIfAppropriate` did. For host logs and tests.
public enum ReviewPromptRequestResult: Equatable, Sendable, CustomStringConvertible {
    /// The system prompt was asked for and the request was stored. The system may still have shown nothing; there is
    /// no way to know.
    case requested
    /// The rules said no, before or after the delay.
    case skipped(ReviewPromptDecision)
    /// The host was busy, before or after the delay. Nothing was stored; the next natural break may try again.
    case busy
    /// Another request is already waiting for its delay. Nothing was scheduled.
    case alreadyPending
    /// Nothing could ask: the app was not active, the window was gone or hidden, the system is too old, or the stored
    /// state comes from a newer SDK and must not be overwritten. Nothing was stored.
    case unavailable

    public var description: String {
        switch self {
        case .requested:
            return "requested"
        case let .skipped(decision):
            return "skipped(\(decision))"
        case .busy:
            return "busy"
        case .alreadyPending:
            return "alreadyPending"
        case .unavailable:
            return "unavailable"
        }
    }
}
