// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
@testable import NovagramReviewPromptCore

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    var now: Date {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.current
    }

    func advance(days: Double) {
        self.advance(seconds: days * 86_400)
    }

    func advance(seconds: TimeInterval) {
        self.lock.lock()
        self.current = self.current.addingTimeInterval(seconds)
        self.lock.unlock()
    }
}

/// Holds delayed work until the test runs it.
final class ManualScheduler: ReviewPromptScheduling {
    private(set) var delays: [TimeInterval] = []
    private var pending: [@MainActor () -> Void] = []

    nonisolated init() {
    }

    var pendingCount: Int {
        return self.pending.count
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        self.delays.append(delay)
        self.pending.append(work)
    }

    func runPending() {
        let work = self.pending
        self.pending = []
        for item in work {
            item()
        }
    }
}

/// Stands in for the system prompt and counts the calls.
final class SpyPresenter: ReviewPromptPresenting {
    var answer = true
    private(set) var calls = 0

    nonisolated init() {
    }

    func requestReview(in target: ReviewPromptTarget?) -> Bool {
        self.calls += 1
        return self.answer
    }
}

/// Collects request results.
@MainActor
final class ResultLog {
    private(set) var results: [ReviewPromptRequestResult] = []

    func add(_ result: ReviewPromptRequestResult) {
        self.results.append(result)
    }
}

/// A switch the test flips while a request waits for its delay.
@MainActor
final class BusyFlag {
    var isBusy = false
    private(set) var checks = 0

    func check() -> Bool {
        self.checks += 1
        return self.isBusy
    }
}

/// One fixed defaults suite, emptied before and after each test (a fresh name per test would leave a plist file in
/// ~/Library/Preferences every run), plus a clock, scheduler and presenter.
struct TestEnvironment {
    static let suiteName = "NovagramReviewPromptTests"

    let defaults: UserDefaults
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let scheduler = ManualScheduler()
    let presenter = SpyPresenter()

    init() {
        guard let defaults = UserDefaults(suiteName: TestEnvironment.suiteName) else {
            preconditionFailure("the test suite could not be opened")
        }
        self.defaults = defaults
        TestEnvironment.clear(defaults)
    }

    func makeCenter(policy: ReviewPromptPolicy = ReviewPromptPolicy()) -> ReviewPromptCenter {
        let clock = self.clock
        return ReviewPromptCenter(
            policy: policy,
            defaults: self.defaults,
            now: { clock.now },
            scheduler: self.scheduler,
            presenter: self.presenter
        )
    }

    /// The stored bytes once every queued write has landed.
    func storedData() -> Data? {
        ReviewPromptCenter.waitForPendingWrites()
        return self.defaults.data(forKey: ReviewPromptCenter.stateKey)
    }

    func store(json: String) {
        self.defaults.set(Data(json.utf8), forKey: ReviewPromptCenter.stateKey)
    }

    func tearDown() {
        TestEnvironment.clear(self.defaults)
    }

    private static func clear(_ defaults: UserDefaults) {
        // A write still queued by the previous test must not land in this one.
        ReviewPromptCenter.waitForPendingWrites()
        defaults.removePersistentDomain(forName: TestEnvironment.suiteName)
    }
}

extension ReviewPromptCenter {
    func record(_ feature: ReviewPromptFeature, times: Int) {
        for _ in 0 ..< times {
            self.recordSuccess(feature)
        }
    }
}
