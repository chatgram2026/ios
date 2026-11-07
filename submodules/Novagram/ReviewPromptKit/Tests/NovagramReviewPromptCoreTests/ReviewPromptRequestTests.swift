// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import NovagramReviewPromptCore

@MainActor
final class ReviewPromptRequestTests: XCTestCase {
    /// A center whose user has used one feature 5 times, 3 days ago.
    private func makeEligibleCenter(_ env: TestEnvironment, policy: ReviewPromptPolicy = ReviewPromptPolicy()) -> ReviewPromptCenter {
        let center = env.makeCenter(policy: policy)
        center.record(.editedHistory, times: 5)
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
        return center
    }

    private func request(_ center: ReviewPromptCenter, version: String = "1.0", log: ResultLog, isBusy: @escaping @MainActor () -> Bool = { false }) {
        center.request(appVersion: version, target: nil, isBusy: isBusy, completion: { log.add($0) })
    }

    func testEligibleRequestWaitsThenCallsTheSystemPromptAndStoresTheRequest() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()

        self.request(center, log: log)
        XCTAssertEqual(env.scheduler.delays, [2])
        XCTAssertEqual(env.presenter.calls, 0, "nothing is asked before the delay")
        XCTAssertEqual(log.results, [])
        XCTAssertNil(center.state.lastRequestDate)

        env.clock.advance(seconds: 2)
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.requested])
        XCTAssertEqual(env.presenter.calls, 1)
        let state = center.state
        XCTAssertEqual(state.lastRequestDate, env.clock.now)
        XCTAssertEqual(state.lastRequestedAppVersion, "1.0")
    }

    func testIneligibleRequestSchedulesAndAsksNothing() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.editedHistory, times: 4)
        env.clock.advance(days: 3)
        let log = ResultLog()

        self.request(center, log: log)
        XCTAssertEqual(log.results, [.skipped(.notEnoughUse)])
        XCTAssertEqual(env.scheduler.pendingCount, 0)
        XCTAssertEqual(env.presenter.calls, 0)
    }

    func testBusyBeforeTheDelayBlocks() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()

        self.request(center, log: log, isBusy: { true })
        XCTAssertEqual(log.results, [.busy])
        XCTAssertEqual(env.scheduler.pendingCount, 0)
        XCTAssertEqual(env.presenter.calls, 0)
        XCTAssertNil(center.state.lastRequestDate)
    }

    func testBusyAfterTheDelayBlocksAndALaterBreakMayTryAgain() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        let flag = BusyFlag()

        self.request(center, log: log, isBusy: { flag.check() })
        XCTAssertEqual(flag.checks, 1)
        // A call starts during the delay.
        flag.isBusy = true
        env.scheduler.runPending()
        XCTAssertEqual(flag.checks, 2, "isBusy is asked again after the delay")
        XCTAssertEqual(log.results, [.busy])
        XCTAssertEqual(env.presenter.calls, 0)
        XCTAssertNil(center.state.lastRequestDate, "a blocked request is not stored")

        flag.isBusy = false
        self.request(center, log: log, isBusy: { flag.check() })
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.busy, .requested])
        XCTAssertEqual(env.presenter.calls, 1)
    }

    func testRulesAreCheckedAgainAfterTheDelay() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()

        self.request(center, log: log)
        // A login during the delay restarts the start delay.
        center.noteFreshStart()
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.skipped(.tooSoonAfterStart(until: env.clock.now.addingTimeInterval(3 * 86_400)))])
        XCTAssertEqual(env.presenter.calls, 0)
    }

    func testOnlyOneRequestWaitsAtATime() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()

        self.request(center, log: log)
        self.request(center, log: log)
        XCTAssertEqual(log.results, [.alreadyPending])
        XCTAssertEqual(env.scheduler.pendingCount, 1)
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.alreadyPending, .requested])
        XCTAssertEqual(env.presenter.calls, 1)
    }

    func testOneRequestPerVersion() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        self.request(center, version: "1.0", log: log)
        env.scheduler.runPending()
        // Rule C: the next request needs new use.
        center.record(.editedHistory, times: 5)

        env.clock.advance(days: 100)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .alreadyRequestedThisVersion)
        self.request(center, version: "1.0", log: log)
        XCTAssertEqual(log.results, [.requested, .skipped(.alreadyRequestedThisVersion)])
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
    }

    func testOneRequestPerVersionCanBeTurnedOff() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env, policy: ReviewPromptPolicy(oneRequestPerAppVersion: false))
        let log = ResultLog()
        self.request(center, log: log)
        env.scheduler.runPending()
        // Rule C: the next request needs new use.
        center.record(.editedHistory, times: 5)
        env.clock.advance(days: 14)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testFourteenDayCooldown() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        self.request(center, version: "1.0", log: log)
        env.scheduler.runPending()
        // Rule C: the next request needs new use.
        center.record(.editedHistory, times: 5)
        let cooldownEnd = env.clock.now.addingTimeInterval(14 * 86_400)

        env.clock.advance(days: 13)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .cooldown(until: cooldownEnd))
        self.request(center, version: "1.1", log: log)
        XCTAssertEqual(log.results.last, .skipped(.cooldown(until: cooldownEnd)))

        env.clock.advance(days: 1)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
        self.request(center, version: "1.1", log: log)
        env.scheduler.runPending()
        XCTAssertEqual(log.results.last, .requested)
        XCTAssertEqual(center.state.lastRequestedAppVersion, "1.1")
    }

    func testVersionIsCheckedBeforeTheCooldown() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        self.request(center, version: "1.0", log: log)
        env.scheduler.runPending()
        // Rule C: the next request needs new use.
        center.record(.editedHistory, times: 5)
        env.clock.advance(days: 1)
        // Both the version and the cooldown fail; the README promises this order.
        XCTAssertEqual(center.decision(appVersion: "1.0"), .alreadyRequestedThisVersion)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .cooldown(until: env.clock.now.addingTimeInterval(13 * 86_400)))
    }

    func testFreshStartKeepsTheRequestHistory() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        self.request(center, version: "1.0", log: log)
        env.scheduler.runPending()
        // Rule C: the next request needs new use.
        center.record(.editedHistory, times: 5)
        let requestDate = env.clock.now

        center.noteFreshStart()
        XCTAssertEqual(center.state.lastRequestDate, requestDate)
        XCTAssertEqual(center.state.lastRequestedAppVersion, "1.0")
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .alreadyRequestedThisVersion)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .cooldown(until: requestDate.addingTimeInterval(14 * 86_400)))
    }

    func testEmptyAppVersionAsksAndStoresNothing() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        self.request(center, version: "", log: log)
        XCTAssertEqual(log.results, [.skipped(.invalidAppVersion)])
        XCTAssertEqual(env.scheduler.pendingCount, 0)
        XCTAssertNil(center.state.lastRequestDate)
    }

    func testReleasedCenterDoesNotCallTheCompletion() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let log = ResultLog()
        var center: ReviewPromptCenter? = self.makeEligibleCenter(env)
        center?.request(appVersion: "1.0", target: nil, isBusy: { false }, completion: { log.add($0) })
        weak var released: ReviewPromptCenter?
        released = center
        center = nil
        XCTAssertNil(released, "a waiting request does not keep the center alive")
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [], "documented: no completion once the center is gone")
        XCTAssertEqual(env.presenter.calls, 0)
    }

    func testMainQueueSchedulerRunsTheWorkLaterOnMain() {
        let scheduler = ReviewPromptMainQueueScheduler()
        let ran = self.expectation(description: "scheduled work ran")
        let start = Date()
        scheduler.schedule(after: 0.05) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
            ran.fulfill()
        }
        self.wait(for: [ran], timeout: 2)
    }

    func testPresenterThatCannotAskStoresNothing() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        env.presenter.answer = false

        self.request(center, log: log)
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.unavailable])
        XCTAssertEqual(env.presenter.calls, 1)
        XCTAssertNil(center.state.lastRequestDate)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible, "the version's request is not used up")
    }

    #if os(macOS)
    func testPublicMacEntryPointDefaultsToTheKeyWindow() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeEligibleCenter(env)
        let log = ResultLog()
        center.requestReviewIfAppropriate(appVersion: "1.0", isBusy: { false }, completion: { log.add($0) })
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.requested])
        XCTAssertEqual(env.presenter.calls, 1)
    }
    #endif
}
