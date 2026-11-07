// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramReviewPromptCore

final class ReviewPromptDecisionTests: XCTestCase {
    func testDefaults() {
        let policy = ReviewPromptPolicy()
        XCTAssertEqual(policy.requiredSuccesses, 5)
        XCTAssertEqual(policy.countedFeatures, ReviewPromptPolicy.defaultCountedFeatures)
        XCTAssertEqual(policy.countedFeatures.count, 11)
        XCTAssertEqual(Set(ReviewPromptFeature.allCases).subtracting(policy.countedFeatures), [.autoTranslate, .callRecordingSaved])
        XCTAssertEqual(policy.minimumDaysAfterStart, 3)
        XCTAssertEqual(policy.minimumDaysBetweenRequests, 14)
        XCTAssertTrue(policy.oneRequestPerAppVersion)
        XCTAssertEqual(policy.delayBeforeRequest, 2)
    }

    func testFiveSuccessesOfOneFeatureMakeTheUserEligible() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse, "no use at all")
        center.record(.translateMessage, times: 4)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse)
        center.recordSuccess(.translateMessage)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testThresholdIsPerFeature() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        env.clock.advance(days: 3)
        center.record(.translateMessage, times: 4)
        center.record(.speechToText, times: 4)
        center.record(.ghostMode, times: 4)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse, "12 uses spread over three features are not 5 of one")
        center.recordSuccess(.ghostMode)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testOnlyCountedFeaturesCount() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter(policy: ReviewPromptPolicy(countedFeatures: [.speechToText]))
        env.clock.advance(days: 3)
        center.record(.translateMessage, times: 20)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse)
        XCTAssertEqual(center.state.successCount(for: .translateMessage), 20, "an uncounted feature is still stored")
        center.record(.speechToText, times: 5)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testNoCountedFeaturesNeverAllowARequest() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter(policy: ReviewPromptPolicy(countedFeatures: []))
        env.clock.advance(days: 30)
        for feature in ReviewPromptFeature.allCases {
            center.record(feature, times: 5)
        }
        XCTAssertEqual(center.decision(appVersion: "1.0"), .notEnoughUse)
    }

    func testStartDelay() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let start = env.clock.now
        let center = env.makeCenter()
        XCTAssertEqual(center.state.startDate, start, "the first center stamps the start")
        center.record(.storySave, times: 5)
        let delayEnd = start.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .tooSoonAfterStart(until: delayEnd))
        env.clock.advance(seconds: 3 * 86_400 - 1)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .tooSoonAfterStart(until: delayEnd))
        env.clock.advance(seconds: 1)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testANewCenterKeepsTheFirstStart() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let start = env.clock.now
        _ = env.makeCenter()
        ReviewPromptCenter.waitForPendingWrites()
        env.clock.advance(days: 10)
        let later = env.makeCenter()
        XCTAssertEqual(later.state.startDate, start)
    }

    func testFreshStartRestartsTheDelayAndKeepsTheCounts() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.chatLockUnlock, times: 5)
        env.clock.advance(days: 4)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)

        center.noteFreshStart()
        let delayEnd = env.clock.now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .tooSoonAfterStart(until: delayEnd))
        XCTAssertEqual(center.state.successCount(for: .chatLockUnlock), 5)
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testDecisionAcceptsAnExplicitDate() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.voiceTranslate, times: 5)
        XCTAssertEqual(center.decision(appVersion: "1.0", now: env.clock.now.addingTimeInterval(3 * 86_400)), .eligible)
        XCTAssertFalse(center.decision(appVersion: "1.0").isEligible, "the clock itself has not moved")
    }

    func testEmptyAppVersionIsRefused() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.translateMessage, times: 5)
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: ""), .invalidAppVersion)
        XCTAssertEqual(center.decision(appVersion: " \n"), .invalidAppVersion)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
    }

    func testClockSetBackDoesNotBlockForMonths() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let now = env.clock.now.timeIntervalSince1970
        // Written while the clock ran 300 days ahead: start and last request both lie in the future.
        env.store(json: #"{"formatVersion":1,"startDate":\#(now + 300 * 86_400),"lastRequestDate":\#(now + 200 * 86_400),"lastRequestedAppVersion":"0.9","successCounts":{"ghostMode":5}}"#)
        let center = env.makeCenter()
        XCTAssertEqual(center.decision(appVersion: "1.0"), .tooSoonAfterStart(until: env.clock.now.addingTimeInterval(3 * 86_400)))
        env.clock.advance(days: 3)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .cooldown(until: env.clock.now.addingTimeInterval(11 * 86_400)), "the cooldown counts from the clamped date")
        env.clock.advance(days: 11)
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)

        // A change stores the clamped dates.
        center.recordSuccess(.ghostMode)
        let stored = ReviewPromptState.decode(env.storedData())?.state
        XCTAssertLessThanOrEqual(stored?.startDate ?? .distantFuture, env.clock.now)
        XCTAssertLessThanOrEqual(stored?.lastRequestDate ?? .distantFuture, env.clock.now)
    }

    func testDescriptionsForLogs() {
        XCTAssertEqual(ReviewPromptDecision.notEnoughUse.description, "notEnoughUse")
        XCTAssertEqual(ReviewPromptRequestResult.skipped(.alreadyRequestedThisVersion).description, "skipped(alreadyRequestedThisVersion)")
    }

    func testPolicyClampsNonsense() {
        let policy = ReviewPromptPolicy(requiredSuccesses: 0, minimumDaysAfterStart: -1, minimumDaysBetweenRequests: -5, delayBeforeRequest: -2)
        XCTAssertEqual(policy.requiredSuccesses, 1)
        XCTAssertEqual(policy.minimumDaysAfterStart, 0)
        XCTAssertEqual(policy.minimumDaysBetweenRequests, 0)
        XCTAssertEqual(policy.delayBeforeRequest, 0)
    }
}
