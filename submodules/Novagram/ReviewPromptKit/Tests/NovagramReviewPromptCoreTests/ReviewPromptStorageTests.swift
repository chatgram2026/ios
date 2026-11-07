// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramReviewPromptCore

final class ReviewPromptStorageTests: XCTestCase {
    func testSharedSuiteAndKey() {
        XCTAssertEqual(ReviewPromptCenter.suiteName, "pro_messager")
        XCTAssertEqual(ReviewPromptCenter.stateKey, "novagram_review_prompt_state")
    }

    func testFeatureRawValuesNeverChange() {
        // These strings are stored on users' devices by both apps.
        XCTAssertEqual(ReviewPromptFeature.allCases.map(\.rawValue), [
            "editedHistory", "translateMessage", "autoTranslate", "speechToText", "voiceTranslate", "storySave",
            "roundVideoFromGallery", "forwardWithoutNames", "ghostMode", "chatLockUnlock", "secretVaultUnlock",
            "callRecordingSaved", "viewFirstMessage"
        ])
    }

    func testStateIsOneJSONValueUnderOneKey() throws {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.ghostMode, times: 2)

        let data = try XCTUnwrap(env.storedData())
        let keys = env.defaults.persistentDomain(forName: TestEnvironment.suiteName)?.keys.sorted() ?? []
        XCTAssertEqual(keys, [ReviewPromptCenter.stateKey])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json.keys.sorted(), ["formatVersion", "startDate", "successCounts"])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertEqual((json["successCounts"] as? [String: Int])?["ghostMode"], 2)
        XCTAssertEqual(json["startDate"] as? Double, env.clock.now.timeIntervalSince1970)
    }

    @MainActor
    func testRoundTripThroughANewCenter() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let first = env.makeCenter()
        first.record(.secretVaultUnlock, times: 5)
        env.clock.advance(days: 3)
        first.request(appVersion: "2.0.15", target: nil, isBusy: { false }, completion: { _ in })
        env.scheduler.runPending()
        let saved = first.state
        XCTAssertNotNil(saved.lastRequestDate)

        ReviewPromptCenter.waitForPendingWrites()
        let second = env.makeCenter()
        XCTAssertEqual(second.state, saved)
        XCTAssertEqual(second.state.successCountsAtLastRequest, ["secretVaultUnlock": 5], "the baseline is stored")
        XCTAssertEqual(second.decision(appVersion: "2.0.15"), .notEnoughUse)
        second.record(.secretVaultUnlock, times: 5)
        XCTAssertEqual(second.decision(appVersion: "2.0.15"), .alreadyRequestedThisVersion)
    }

    func testReadingNeverWrites() throws {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let json = #"{"formatVersion":1,"startDate":1799000000,"successCounts":{"ghostMode":3}}"#
        env.store(json: json)
        let center = env.makeCenter()
        _ = center.state
        _ = center.decision(appVersion: "1.0")
        _ = env.makeCenter().state
        XCTAssertEqual(env.storedData(), Data(json.utf8), "init, state and decision leave the stored bytes alone")
    }

    func testNewerFormatIsReadButNeverOverwritten() throws {
        let env = TestEnvironment()
        defer { env.tearDown() }
        // A newer SDK wrote this; then the user went back to an older build.
        let json = #"{"formatVersion":2,"startDate":1799000000,"successCounts":{"ghostMode":9},"somethingNew":[1,2]}"#
        env.store(json: json)
        let center = env.makeCenter()
        XCTAssertEqual(center.state.successCount(for: .ghostMode), 9)
        center.recordSuccess(.ghostMode)
        center.noteFreshStart()
        XCTAssertEqual(center.state.successCount(for: .ghostMode), 10, "counted in memory")
        XCTAssertEqual(env.storedData(), Data(json.utf8))
    }

    @MainActor
    func testNewerFormatNeverAsks() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        env.store(json: #"{"formatVersion":2,"startDate":1799000000,"successCounts":{"ghostMode":9}}"#)
        let center = env.makeCenter()
        XCTAssertEqual(center.decision(appVersion: "1.0"), .eligible)
        let log = ResultLog()
        center.request(appVersion: "1.0", target: nil, isBusy: { false }, completion: { log.add($0) })
        XCTAssertEqual(log.results, [.unavailable])
        XCTAssertEqual(env.scheduler.pendingCount, 0)
    }

    func testOneBadFieldDoesNotEraseTheOthers() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        env.store(json: #"{"formatVersion":1,"startDate":"yesterday","lastRequestedAppVersion":"1.0","successCounts":{"ghostMode":3,"translateMessage":"many","storySave":-2}}"#)
        let state = env.makeCenter().state
        XCTAssertEqual(state.startDate, env.clock.now, "the bad start is stamped again")
        XCTAssertEqual(state.lastRequestedAppVersion, "1.0")
        XCTAssertEqual(state.successCounts, ["ghostMode": 3])
    }

    func testJSONWithoutTheBaselineStillDecodes() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let now = env.clock.now.timeIntervalSince1970
        // Exactly what the first SDK version (f070eec) writes after a request: no successCountsAtLastRequest.
        let json = #"{"formatVersion":1,"lastRequestDate":\#(now - 20 * 86_400),"lastRequestedAppVersion":"1.0","startDate":\#(now - 30 * 86_400),"successCounts":{"ghostMode":7}}"#
        env.store(json: json)
        let center = env.makeCenter()
        let state = center.state
        XCTAssertEqual(state.successCountsAtLastRequest, [:], "a missing baseline is zero")
        XCTAssertEqual(state.successCount(for: .ghostMode), 7)
        XCTAssertEqual(state.newSuccessCount(for: .ghostMode), 7)
        XCTAssertEqual(state.lastRequestedAppVersion, "1.0")
        XCTAssertEqual(center.decision(appVersion: "1.1"), .eligible)
        XCTAssertEqual(env.storedData(), Data(json.utf8), "reading it writes nothing")
    }

    func testCorruptDataGivesAFreshState() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        env.defaults.set(Data("not json".utf8), forKey: ReviewPromptCenter.stateKey)
        let center = env.makeCenter()
        let state = center.state
        XCTAssertEqual(state.startDate, env.clock.now)
        XCTAssertEqual(state.successCounts, [:])
        XCTAssertNil(state.lastRequestDate)
        XCTAssertNil(state.lastRequestedAppVersion)
        center.recordSuccess(.storySave)
        ReviewPromptCenter.waitForPendingWrites()
        XCTAssertEqual(env.makeCenter().state.successCount(for: .storySave), 1, "the fresh state is stored over the corrupt one")
    }

    func testWrongTypeUnderTheKeyGivesAFreshState() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        env.defaults.set("a string", forKey: ReviewPromptCenter.stateKey)
        let center = env.makeCenter()
        XCTAssertEqual(center.state.successCounts, [:])
        XCTAssertEqual(center.state.startDate, env.clock.now)
    }

    func testMissingDataStampsTheStart() throws {
        let env = TestEnvironment()
        defer { env.tearDown() }
        XCTAssertNil(env.defaults.object(forKey: ReviewPromptCenter.stateKey))
        let state = env.makeCenter().state
        XCTAssertEqual(state.startDate, env.clock.now)
        XCTAssertEqual(state.successCounts, [:])
        // The first sight of the device is the one write a new center makes.
        let stored = try XCTUnwrap(ReviewPromptState.decode(env.storedData()))
        XCTAssertEqual(stored.state.startDate, env.clock.now)
    }

    func testUnknownFeaturesAreKept() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        env.store(json: #"{"successCounts":{"translateMessage":3,"someFutureFeature":7}}"#)
        let center = env.makeCenter()
        center.recordSuccess(.translateMessage)
        ReviewPromptCenter.waitForPendingWrites()
        let state = env.makeCenter().state
        XCTAssertEqual(state.successCount(for: .translateMessage), 4)
        XCTAssertEqual(state.successCounts["someFutureFeature"], 7, "a feature this build does not know is not dropped")
    }

    func testCountsStopAtTheCapAndStopWriting() throws {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        center.record(.translateMessage, times: ReviewPromptCenter.successCountCap)
        let atCap = try XCTUnwrap(env.storedData())
        env.defaults.set(Data("marker".utf8), forKey: ReviewPromptCenter.stateKey)
        center.record(.translateMessage, times: 5)
        XCTAssertEqual(center.state.successCount(for: .translateMessage), ReviewPromptCenter.successCountCap)
        XCTAssertEqual(env.storedData(), Data("marker".utf8), "nothing is written past the cap")
        XCTAssertEqual(ReviewPromptState.decode(atCap)?.state.successCount(for: .translateMessage), ReviewPromptCenter.successCountCap)
    }

    func testRecordSuccessIsSafeFromManyThreads() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        let features: [ReviewPromptFeature] = [.translateMessage, .speechToText, .forwardWithoutNames]
        let iterations = 1_200
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            center.recordSuccess(features[index % 3])
        }
        ReviewPromptCenter.waitForPendingWrites()
        let stored = env.makeCenter().state
        for feature in features {
            XCTAssertEqual(center.state.successCount(for: feature), iterations / 3, "\(feature)")
            XCTAssertEqual(stored.successCount(for: feature), iterations / 3, "the last write holds the last count: \(feature)")
        }
    }

    // Regression: the write used to happen under the lock, so a host observer that waits for another thread which
    // touches the center (the Mac app's queue: .main observer did) deadlocked.
    func testObserverThatWaitsForAnotherThreadDoesNotDeadlock() {
        let env = TestEnvironment()
        defer { env.tearDown() }
        let center = env.makeCenter()
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var notifications = 0
            var timeouts = 0
        }
        let outcome = Outcome()
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = center.state
                _ = center.decision(appVersion: "1.0")
                done.signal()
            }
            let timedOut = done.wait(timeout: .now() + 2) == .timedOut
            outcome.lock.lock()
            outcome.notifications += 1
            if timedOut {
                outcome.timeouts += 1
            }
            outcome.lock.unlock()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        let finished = self.expectation(description: "recordSuccess returned")
        DispatchQueue.global().async {
            center.recordSuccess(.ghostMode)
            center.noteFreshStart()
            finished.fulfill()
        }
        self.wait(for: [finished], timeout: 5)
        ReviewPromptCenter.waitForPendingWrites()
        outcome.lock.lock()
        XCTAssertGreaterThan(outcome.notifications, 0, "the observer ran")
        XCTAssertEqual(outcome.timeouts, 0, "the other thread got the center while the observer waited")
        outcome.lock.unlock()
    }

    func testDefaultsFallBackToStandardWhenTheSuiteCannotOpen() {
        // The global domain is not a valid suite name, so it exercises the fallback.
        XCTAssertTrue(ReviewPromptCenter.defaults(suiteName: UserDefaults.globalDomain) === UserDefaults.standard)
        XCTAssertFalse(ReviewPromptCenter.defaults(suiteName: TestEnvironment.suiteName) === UserDefaults.standard)
    }
}
