// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Counts successful feature use and asks for an App Store rating when ``ReviewPromptPolicy`` allows it.
///
/// Keep one center per app (one per `UserDefaults` suite in a process): each center works on its own in-memory copy
/// of the state, so two centers on one suite would overwrite each other's counts.
///
/// ``recordSuccess(_:)``, ``noteFreshStart()``, ``state`` and ``decision(appVersion:now:)`` may be called from any
/// thread and never block on the host: the lock only guards the in-memory copy, and the `UserDefaults` write (which
/// posts `UserDefaults.didChangeNotification` to the host's observers) runs later on a private serial queue. The
/// request runs on the main actor.
public final class ReviewPromptCenter: @unchecked Sendable {
    /// The `UserDefaults` suite both apps use for Novagram settings.
    public static let suiteName = "pro_messager"
    /// The one key the whole state is stored under, as JSON.
    public static let stateKey = "novagram_review_prompt_state"

    /// The `pro_messager` suite, or the standard defaults if the suite cannot be opened.
    public static func novagramDefaults() -> UserDefaults {
        return ReviewPromptCenter.defaults(suiteName: ReviewPromptCenter.suiteName)
    }

    static func defaults(suiteName: String) -> UserDefaults {
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// New successes since the last request stop growing (and stop being written) here; any threshold is far below
    /// it.
    static let successCountCap = 1_000

    // Writes run here, in the order they were made, and never under a lock: `UserDefaults.set` posts its change
    // notification synchronously, and a host observer may wait for the main thread.
    private static let writeQueue = DispatchQueue(label: "uz.novagram.reviewprompt.writes")

    public let policy: ReviewPromptPolicy
    public let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let scheduler: any ReviewPromptScheduling
    private let presenter: any ReviewPromptPresenting
    /// The stored data comes from a newer SDK (a downgrade): use it, but never overwrite it and never ask.
    private let isReadOnly: Bool

    private let lock = NSLock()
    private var current: ReviewPromptState

    @MainActor private var isRequestPending = false

    /// - Parameters:
    ///   - defaults: where the state is stored; tests inject their own suite.
    ///   - now: the clock; tests inject a fixed one.
    ///   - scheduler: runs the delayed half of a request; tests run it by hand.
    ///   - presenter: calls the system prompt; tests inject a spy.
    public init(
        policy: ReviewPromptPolicy = ReviewPromptPolicy(),
        defaults: UserDefaults = ReviewPromptCenter.novagramDefaults(),
        now: @escaping @Sendable () -> Date = { Date() },
        scheduler: any ReviewPromptScheduling = ReviewPromptMainQueueScheduler(),
        presenter: any ReviewPromptPresenting = ReviewPromptSystemPresenter()
    ) {
        self.policy = policy
        self.defaults = defaults
        self.now = now
        self.scheduler = scheduler
        self.presenter = presenter

        let date = now()
        let stored = ReviewPromptState.decode(defaults.data(forKey: ReviewPromptCenter.stateKey))
        var state = stored?.state ?? ReviewPromptState()
        self.isReadOnly = (stored?.formatVersion ?? 0) > ReviewPromptState.currentFormatVersion
        // The first time the SDK sees this device is the start. That stamp is the only write a new center makes,
        // and only when nothing usable is stored.
        let needsStart = state.startDate == nil
        if needsStart {
            state.startDate = date
        }
        state.clampDates(to: date)
        self.current = state
        if needsStart && !self.isReadOnly {
            self.enqueueWrite(state)
        }
    }

    /// The state as this center has it. Never writes.
    public var state: ReviewPromptState {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        // A date after now means the clock was set back. Fixing it in memory makes it count from the moment it was
        // noticed; the fixed date is stored with the next real change.
        self.current.clampDates(to: self.now())
        return self.current
    }

    /// Counts one successful use of `feature`. Safe from any thread.
    public func recordSuccess(_ feature: ReviewPromptFeature) {
        self.update { state, _ in
            let count = state.successCount(for: feature)
            // The cap applies to new successes, so a count at the cap still grows again after a request.
            if state.newSuccessCount(for: feature) < ReviewPromptCenter.successCountCap {
                state.successCounts[feature.rawValue] = count + 1
            }
        }
    }

    /// Restarts the start delay (``ReviewPromptPolicy/minimumDaysAfterStart`` counts from now). Call after a login.
    /// Counts and the last request are kept, so a new login never allows an extra request.
    public func noteFreshStart() {
        self.update { state, now in
            state.startDate = now
        }
    }

    /// Whether the rules allow a request for `appVersion` at `now` (the clock when nil). Asks for nothing, writes
    /// nothing.
    public func decision(appVersion: String, now: Date? = nil) -> ReviewPromptDecision {
        let state = self.state
        return self.policy.decision(for: state, appVersion: appVersion, now: now ?? self.now())
    }

    #if os(iOS)
    /// Asks for a rating at a natural break, such as returning to the chat list, if the rules allow it.
    ///
    /// When eligible and not busy it waits ``ReviewPromptPolicy/delayBeforeRequest``, checks the rules and `isBusy`
    /// again, then calls the system prompt in `scene` (if it is still in the foreground) and stores the request.
    /// Never call it from a button tap.
    ///
    /// - Parameters:
    ///   - isBusy: true while the user is in the middle of something (a call, a recording, typing, an unlock, a
    ///     payment). Called before and after the delay.
    ///   - completion: the result, on the main actor: at once when the rules or `isBusy` refuse, after the delay
    ///     otherwise. Not called if the center is released during the delay.
    @MainActor
    public func requestReviewIfAppropriate(
        appVersion: String,
        in scene: UIWindowScene,
        isBusy: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (ReviewPromptRequestResult) -> Void = { _ in }
    ) {
        self.request(appVersion: appVersion, target: scene, isBusy: isBusy, completion: completion)
    }
    #elseif os(macOS)
    /// Asks for a rating at a natural break, such as returning to the chat list, if the rules allow it.
    ///
    /// When eligible and not busy it waits ``ReviewPromptPolicy/delayBeforeRequest``, checks the rules and `isBusy`
    /// again, then calls the system prompt in `window` (if it is still visible) and stores the request. Never call it
    /// from a button click.
    ///
    /// - Parameters:
    ///   - window: the window the user is looking at; nil uses the key window. A window without a
    ///     `contentViewController` works too.
    ///   - isBusy: true while the user is in the middle of something (a call, a recording, typing, an unlock, a
    ///     payment). Called before and after the delay.
    ///   - completion: the result, on the main actor: at once when the rules or `isBusy` refuse, after the delay
    ///     otherwise. Not called if the center is released during the delay.
    @MainActor
    public func requestReviewIfAppropriate(
        appVersion: String,
        in window: NSWindow? = nil,
        isBusy: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (ReviewPromptRequestResult) -> Void = { _ in }
    ) {
        self.request(appVersion: appVersion, target: window, isBusy: isBusy, completion: completion)
    }
    #endif

    @MainActor
    func request(
        appVersion: String,
        target: ReviewPromptTarget?,
        isBusy: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (ReviewPromptRequestResult) -> Void
    ) {
        if self.isRequestPending {
            completion(.alreadyPending)
            return
        }
        let decision = self.decision(appVersion: appVersion)
        guard decision == .eligible else {
            completion(.skipped(decision))
            return
        }
        if self.isReadOnly {
            completion(.unavailable)
            return
        }
        if isBusy() {
            completion(.busy)
            return
        }
        self.isRequestPending = true
        self.scheduler.schedule(after: self.policy.delayBeforeRequest) { [weak self] in
            guard let self = self else {
                return
            }
            self.isRequestPending = false
            completion(self.finishRequest(appVersion: appVersion, target: target, isBusy: isBusy))
        }
    }

    @MainActor
    private func finishRequest(appVersion: String, target: ReviewPromptTarget?, isBusy: @MainActor () -> Bool) -> ReviewPromptRequestResult {
        // Anything may have changed during the delay: a login, another request, a call.
        let decision = self.decision(appVersion: appVersion)
        guard decision == .eligible else {
            return .skipped(decision)
        }
        if isBusy() {
            return .busy
        }
        guard self.presenter.requestReview(in: target) else {
            return .unavailable
        }
        self.update { state, now in
            state.lastRequestDate = now
            state.lastRequestedAppVersion = appVersion
            // The next request needs requiredSuccesses new successes on top of these.
            state.successCountsAtLastRequest = state.successCounts
        }
        return .requested
    }

    /// Changes the in-memory state under the lock and queues a write when something changed. Never calls out while
    /// holding the lock.
    @discardableResult
    private func update<T>(_ body: (inout ReviewPromptState, Date) -> T) -> T {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let now = self.now()
        var state = self.current
        state.clampDates(to: now)
        let result = body(&state, now)
        if state != self.current {
            self.current = state
            if !self.isReadOnly {
                // Queued under the lock, so writes land in the order the changes were made.
                self.enqueueWrite(state)
            }
        }
        return result
    }

    private func enqueueWrite(_ state: ReviewPromptState) {
        let target = DefaultsBox(defaults: self.defaults)
        ReviewPromptCenter.writeQueue.async {
            if let data = state.encoded() {
                target.defaults.set(data, forKey: ReviewPromptCenter.stateKey)
            }
        }
    }

    // UserDefaults is thread-safe (Apple documents it so) but is not marked Sendable in every SDK.
    private struct DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
    }

    /// Waits until every queued write has reached `UserDefaults`. For tests; never call it from the main thread while
    /// a host observer may wait for the main thread.
    static func waitForPendingWrites() {
        ReviewPromptCenter.writeQueue.sync {
        }
    }
}
