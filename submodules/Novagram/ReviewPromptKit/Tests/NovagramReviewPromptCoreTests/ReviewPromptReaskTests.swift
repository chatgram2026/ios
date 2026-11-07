// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramReviewPromptCore

/// Rule C: at most one request per app version, and every request needs `requiredSuccesses` new successes.
@MainActor
final class ReviewPromptReaskTests: XCTestCase {
    /// A center that has just made its request for version 1.0 after 5 uses of `editedHistory`.
    private func makeCenterAfterARequest(_ env: TestEnvironment) -> ReviewPromptCenter {
        let center = env.makeCenter()
        center.record(.editedHistory, times: 5)
        env.clock.advance(days: 3)
        let log = ResultLog()
        center.request(appVersion: "1.0", target: nil, isBusy: { false }, completion: { log.add($0) })
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.requested])
        XCTAssertEqual(center.state.successCountsAtLastRequest, ["editedHistory": 5])
        return center
    }

    func testNextVersionAloneIsNotEnough() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeCenterAfterARequest(env)
        env.clock.advance(days: 14)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .notEnoughUse)

        let log = ResultLog()
        center.request(appVersion: "1.1", target: nil, isBusy: { false }, completion: { log.add($0) })
        XCTAssertEqual(log.results, [.skipped(.notEnoughUse)])
        XCTAssertEqual(env.presenter.calls, 1, "only the first request asked")
    }

    func testFiveNewSuccessesFourteenDaysAndANewVersionAllowTheNextRequest() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeCenterAfterARequest(env)
        let requestDate = env.clock.now
        center.record(.editedHistory, times: 5)
        XCTAssertEqual(center.state.newSuccessCount(for: .editedHistory), 5)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .cooldown(until: requestDate.addingTimeInterval(14 * 86_400)))
        env.clock.advance(days: 14)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .alreadyRequestedThisVersion)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)

        let log = ResultLog()
        center.request(appVersion: "1.1", target: nil, isBusy: { false }, completion: { log.add($0) })
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.requested])
        XCTAssertEqual(env.presenter.calls, 2)
        XCTAssertEqual(center.state.successCountsAtLastRequest, ["editedHistory": 10], "the baseline moves with each request")
        XCTAssertEqual(center.decision(appVersion: "1.2"), .notEnoughUse)
    }

    func testFourNewSuccessesAreNotEnough() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeCenterAfterARequest(env)
        env.clock.advance(days: 14)
        center.record(.editedHistory, times: 4)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .notEnoughUse)
        center.recordSuccess(.editedHistory)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
    }

    func testOnlyCountedFeaturesCountAsNewSuccesses() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = self.makeCenterAfterARequest(env)
        env.clock.advance(days: 14)
        // Not counted by default.
        center.record(.autoTranslate, times: 20)
        center.record(.callRecordingSaved, times: 20)
        // Counted, but spread over two features.
        center.record(.editedHistory, times: 4)
        center.record(.ghostMode, times: 4)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .notEnoughUse)
        center.recordSuccess(.ghostMode)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
    }

    func testUncountedFeaturesNeverMakeTheFirstRequestEither() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.autoTranslate, times: 50)
        center.record(.callRecordingSaved, times: 50)
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse)
        ReviewPromptCenter.waitForPendingWrites()
        let hostChoice = env.makeCenter(policy: ReviewPromptPolicy(countedFeatures: [.autoTranslate]))
        XCTAssertEqual(hostChoice.decision(appVersion: "1.0"), .eligible, "a host may still pass its own set")
    }

    func testCapAppliesToNewSuccessesSoCountsGrowAgainAfterARequest() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.ghostMode, times: ReviewPromptCenter.successCountCap + 3)
        XCTAssertEqual(center.state.successCount(for: .ghostMode), ReviewPromptCenter.successCountCap)
        env.clock.advance(days: 3)
        let log = ResultLog()
        center.request(appVersion: "1.0", target: nil, isBusy: { false }, completion: { log.add($0) })
        env.scheduler.runPending()
        XCTAssertEqual(log.results, [.requested])
        center.record(.ghostMode, times: 5)
        XCTAssertEqual(center.state.newSuccessCount(for: .ghostMode), 5)
        env.clock.advance(days: 14)
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
    }
}
