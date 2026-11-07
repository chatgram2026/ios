// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The rules that decide when the app may ask for a rating.
///
/// The system shows its prompt at most 3 times in 365 days and may show nothing at all, so these rules only decide
/// when asking is worth it. Nothing here may depend on the user's age, birthday, mood or account: every user who uses
/// the app gets the same rules.
public struct ReviewPromptPolicy: Equatable, Sendable {
    /// Successful uses of one feature needed before a request, counted since the previous request (or from the
    /// start). Counted per feature: 3 + 2 of two features is not enough.
    public let requiredSuccesses: Int
    /// The features whose successes count. Others are still stored, but ignored.
    public let countedFeatures: Set<ReviewPromptFeature>
    /// Days that must pass after the start (first use of the SDK on this device, or the last ``ReviewPromptCenter/noteFreshStart()``).
    public let minimumDaysAfterStart: Int
    /// Days that must pass after the previous request.
    public let minimumDaysBetweenRequests: Int
    /// At most one request per app version.
    public let oneRequestPerAppVersion: Bool
    /// Seconds to wait at the natural break before asking, so the prompt does not cover the screen change.
    public let delayBeforeRequest: TimeInterval

    /// The features both apps count, decided once for both: every feature except
    /// - `autoTranslate`: it runs by itself on every sent message, so 5 counts pile up in minutes and show no
    ///   engagement;
    /// - `callRecordingSaved`: an unapproved feature that only shows in a hidden Developer section.
    public static let defaultCountedFeatures: Set<ReviewPromptFeature> = Set(ReviewPromptFeature.allCases).subtracting([
        .autoTranslate,
        .callRecordingSaved
    ])

    public init(
        requiredSuccesses: Int = 5,
        countedFeatures: Set<ReviewPromptFeature> = ReviewPromptPolicy.defaultCountedFeatures,
        minimumDaysAfterStart: Int = 3,
        minimumDaysBetweenRequests: Int = 14,
        oneRequestPerAppVersion: Bool = true,
        delayBeforeRequest: TimeInterval = 2
    ) {
        self.requiredSuccesses = max(1, requiredSuccesses)
        self.countedFeatures = countedFeatures
        self.minimumDaysAfterStart = max(0, minimumDaysAfterStart)
        self.minimumDaysBetweenRequests = max(0, minimumDaysBetweenRequests)
        self.oneRequestPerAppVersion = oneRequestPerAppVersion
        self.delayBeforeRequest = max(0, delayBeforeRequest)
    }

    static let secondsPerDay: TimeInterval = 86_400

    /// The decision for `state` at `now`. Checks run in this order and the first one that fails is the reason: a
    /// usable app version, use, time since the start, this version, time since the last request. Stored dates after
    /// `now` (the clock was set back) count as `now`.
    public func decision(for state: ReviewPromptState, appVersion: String, now: Date) -> ReviewPromptDecision {
        if appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidAppVersion
        }
        // Only successes since the last request count, so every request needs new use.
        let hasEnoughUse = self.countedFeatures.contains { feature in
            state.newSuccessCount(for: feature) >= self.requiredSuccesses
        }
        if !hasEnoughUse {
            return .notEnoughUse
        }
        // A state that was never stamped starts now.
        let start = min(state.startDate ?? now, now)
        let startDelayEnd = start.addingTimeInterval(TimeInterval(self.minimumDaysAfterStart) * ReviewPromptPolicy.secondsPerDay)
        if now < startDelayEnd {
            return .tooSoonAfterStart(until: startDelayEnd)
        }
        if self.oneRequestPerAppVersion, let lastVersion = state.lastRequestedAppVersion, lastVersion == appVersion {
            return .alreadyRequestedThisVersion
        }
        if let lastRequest = state.lastRequestDate.map({ min($0, now) }) {
            let cooldownEnd = lastRequest.addingTimeInterval(TimeInterval(self.minimumDaysBetweenRequests) * ReviewPromptPolicy.secondsPerDay)
            if now < cooldownEnd {
                return .cooldown(until: cooldownEnd)
            }
        }
        return .eligible
    }
}
