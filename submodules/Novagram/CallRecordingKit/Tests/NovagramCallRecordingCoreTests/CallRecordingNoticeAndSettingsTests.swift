// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramCallRecordingCore

@available(macOS 14, iOS 15, *)
final class CallRecordingNoticePolicyTests: XCTestCase {
    func testSentOncePerCallSession() {
        var policy = CallRecordingNoticePolicy()
        let callId = UUID()
        XCTAssertTrue(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        // Stop, then Record again while the notice is still on its way.
        XCTAssertFalse(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        policy.markDelivered(callSessionId: callId)
        // Stop, then Record again after it was delivered.
        XCTAssertFalse(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        XCTAssertEqual(policy.status(callSessionId: callId), .delivered)
    }

    func testEachCallGetsItsOwnNotice() {
        var policy = CallRecordingNoticePolicy()
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(policy.beginSending(callSessionId: first, isOneToOneUser: true, recorderDidStart: true))
        XCTAssertTrue(policy.beginSending(callSessionId: second, isOneToOneUser: true, recorderDidStart: true))
        XCTAssertFalse(policy.beginSending(callSessionId: first, isOneToOneUser: true, recorderDidStart: true))
    }

    func testFailedNoticeIsSentAgainOnTheNextRecord() {
        var policy = CallRecordingNoticePolicy()
        let callId = UUID()
        XCTAssertTrue(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        policy.markFailed(callSessionId: callId)
        XCTAssertEqual(policy.status(callSessionId: callId), .failed)
        XCTAssertTrue(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        XCTAssertEqual(policy.status(callSessionId: callId), .sending)
    }

    func testForgetClearsTheCall() {
        var policy = CallRecordingNoticePolicy()
        let callId = UUID()
        XCTAssertTrue(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
        policy.forget(callSessionId: callId)
        XCTAssertNil(policy.status(callSessionId: callId))
    }

    func testOnlyOneToOneUsersAfterTheRecorderStarted() {
        var policy = CallRecordingNoticePolicy()
        let callId = UUID()
        XCTAssertFalse(policy.beginSending(callSessionId: callId, isOneToOneUser: false, recorderDidStart: true), "group calls and bots get no notice")
        XCTAssertFalse(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: false), "a start that failed sends nothing")
        XCTAssertNil(policy.status(callSessionId: callId), "a refused start leaves no trace")
        XCTAssertTrue(policy.beginSending(callSessionId: callId, isOneToOneUser: true, recorderDidStart: true))
    }

    func testNoticeFollowsTheAppLanguage() {
        XCTAssertEqual(CallRecordingNoticePolicy.message(languageCode: "en"), "🔴 I'm recording this call (Novagram)")
        XCTAssertEqual(CallRecordingNoticePolicy.message(languageCode: "uz"), "🔴 Men bu qo'ng'iroqni yozib olyapman (Novagram)")
        XCTAssertEqual(CallRecordingNoticePolicy.message(languageCode: "ru"), "🔴 Я записываю этот звонок (Novagram)")
        XCTAssertEqual(CallRecordingNoticePolicy.message(languageCode: "zh-hans-raw"), "🔴 我正在录制这次通话（Novagram）")
        // Any other language gets the English text.
        XCTAssertEqual(CallRecordingNoticePolicy.message(languageCode: "de"), "🔴 I'm recording this call (Novagram)")
    }

    func testFailureToastFollowsTheAppLanguage() {
        XCTAssertEqual(CallRecordingNoticePolicy.failureMessage(languageCode: "en"), "Couldn't notify the other person, so the call is not being recorded.")
        XCTAssertEqual(CallRecordingNoticePolicy.failureMessage(languageCode: "uz"), "Suhbatdoshga xabar berib bo'lmadi, shuning uchun qo'ng'iroq yozilmayapti.")
        XCTAssertEqual(CallRecordingNoticePolicy.failureMessage(languageCode: "ru"), "Не удалось уведомить собеседника, поэтому звонок не записывается.")
        XCTAssertEqual(CallRecordingNoticePolicy.failureMessage(languageCode: "zh"), "无法通知对方，因此本次通话未被录制。")
        XCTAssertEqual(CallRecordingNoticePolicy.failureMessage(languageCode: "fr"), CallRecordingNoticePolicy.failureMessage(languageCode: "en"))
    }

    func testLanguageCodes() {
        XCTAssertEqual(CallRecordingLanguage(code: "uz-Latn"), .uzbek)
        XCTAssertEqual(CallRecordingLanguage(code: "ru_RU"), .russian)
        XCTAssertEqual(CallRecordingLanguage(code: "ZH-Hant"), .chinese)
        XCTAssertEqual(CallRecordingLanguage(code: ""), .english)
    }
}

@available(macOS 14, iOS 15, *)
final class CallRecordingSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "call-recording-settings-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    // Both apps read these exact keys; renaming one wipes the users' switches.
    func testKeysAreTheSharedOnes() {
        XCTAssertEqual(CallRecordingSettings.suiteName, "pro_messager")
        XCTAssertEqual(CallRecordingSettings.enabledKey, "novagram_call_recording")
        XCTAssertEqual(CallRecordingSettings.autoKey, "novagram_call_recording_auto")
        XCTAssertEqual(CallRecordingSettings.warnedKey, "novagram_call_recording_warned")
        XCTAssertEqual(CallRecordingSettings.videoQualityKey, "novagram_call_recording_video_quality")
        // The stored values are shared too.
        XCTAssertEqual(CallRecordingVideoQuality.allCases.map(\.rawValue), ["audio", "saver", "high"])
    }

    func testEverythingIsOffByDefault() {
        let settings = CallRecordingSettings(defaults: self.defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.isAutoEnabled)
        XCTAssertFalse(settings.wasWarned)
    }

    // One switch per feature: the stored key is what calls read, with no second gate.
    func testSwitchesAreTheStoredKeys() {
        let settings = CallRecordingSettings(defaults: self.defaults)
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.isAutoEnabled)
        XCTAssertTrue(self.defaults.bool(forKey: "novagram_call_recording"))
        settings.isAutoEnabled = true
        XCTAssertTrue(settings.isAutoEnabled)
        XCTAssertTrue(self.defaults.bool(forKey: "novagram_call_recording_auto"))
        settings.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
        settings.wasWarned = true
        XCTAssertTrue(self.defaults.bool(forKey: "novagram_call_recording_warned"))
    }

    // Nothing stored, or a value this version does not know: battery saver.
    func testVideoQualityDefaultsToBatterySaver() {
        let settings = CallRecordingSettings(defaults: self.defaults)
        XCTAssertEqual(settings.videoQuality, .batterySaver)
        self.defaults.set("ultra", forKey: CallRecordingSettings.videoQualityKey)
        XCTAssertEqual(settings.videoQuality, .batterySaver)
    }

    func testVideoQualityIsStored() {
        let settings = CallRecordingSettings(defaults: self.defaults)
        for quality in CallRecordingVideoQuality.allCases {
            settings.videoQuality = quality
            XCTAssertEqual(settings.videoQuality, quality)
            XCTAssertEqual(self.defaults.string(forKey: "novagram_call_recording_video_quality"), quality.rawValue)
        }
        XCTAssertFalse(CallRecordingVideoQuality.audioOnly.recordsVideo)
        XCTAssertTrue(CallRecordingVideoQuality.batterySaver.recordsVideo)
        XCTAssertTrue(CallRecordingVideoQuality.high.recordsVideo)
    }

    // Battery saver halves the frame rate and the bit rate and keeps the picture size.
    func testConfigurationForEachQuality() {
        let high = CallRecordingConfiguration(quality: .high)
        XCTAssertEqual(high, .standard)
        XCTAssertEqual(high.framesPerSecond, 30)
        XCTAssertEqual(high.videoBitRate, 2_500_000)
        let saver = CallRecordingConfiguration(quality: .batterySaver)
        XCTAssertEqual(saver.framesPerSecond, 15)
        XCTAssertEqual(saver.videoBitRate, 1_250_000)
        XCTAssertEqual(saver.videoSize, high.videoSize)
        XCTAssertEqual(CallRecordingConfiguration(quality: .audioOnly), .standard)
        // The tick runs at 30 Hz, so more frames cannot be written.
        XCTAssertEqual(CallRecordingConfiguration(framesPerSecond: 60).framesPerSecond, 30)
        XCTAssertEqual(CallRecordingConfiguration(framesPerSecond: 0).framesPerSecond, 1)
        XCTAssertEqual(CallRecordingConfiguration(videoBitRate: 0).videoBitRate, 100_000)
    }
}

final class CallRecordingSettingsStringsTests: XCTestCase {
    private let languageCodes = ["en", "uz", "ru", "zh"]

    private func texts(_ strings: CallRecordingSettingsStrings) -> [String] {
        return [strings.title, strings.on, strings.off, strings.recordingHeader, strings.recordTitle, strings.recordFooter, strings.autoTitle, strings.autoFooter, strings.qualityHeader, strings.qualityAudioOnly, strings.qualityBatterySaver, strings.qualityHigh, strings.qualityFooter, strings.recordingsHeader, strings.recordingsTitle, strings.recordingsFooter, strings.privacyHeader, strings.privacyText]
    }

    // The privacy paragraph must tell the user exactly what the other person receives.
    func testPrivacyTextQuotesTheChatMessage() {
        for code in self.languageCodes {
            let strings = CallRecordingSettingsStrings(languageCode: code)
            XCTAssertTrue(strings.privacyText.contains(CallRecordingNoticePolicy.message(languageCode: code)), code)
        }
    }

    func testEveryLanguageHasItsOwnText() {
        let english = self.texts(CallRecordingSettingsStrings(languageCode: "en"))
        XCTAssertFalse(english.contains(where: { $0.isEmpty }))
        for code in ["uz", "ru", "zh"] {
            let texts = self.texts(CallRecordingSettingsStrings(languageCode: code))
            XCTAssertFalse(texts.contains(where: { $0.isEmpty }), code)
            // "REC" and the brand stay as they are, so compare whole texts: none may still be the English one.
            for (text, englishText) in zip(texts, english) {
                XCTAssertNotEqual(text, englishText, code)
            }
        }
        XCTAssertEqual(CallRecordingSettingsStrings(languageCode: "de").title, "Call recording")
    }

    // One text on every platform: no device or platform names (App Review) and no "tap" / "click".
    func testTextsNameNoDeviceOrPlatform() {
        let forbidden = try! NSRegularExpression(pattern: "\\b(iPhone|iPad|iPod|Mac|macOS|iOS|iPadOS|Apple|Android|tap|click)\\b", options: [.caseInsensitive])
        for code in self.languageCodes {
            for text in self.texts(CallRecordingSettingsStrings(languageCode: code)) {
                XCTAssertNil(forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(code): \(text)")
            }
        }
        XCTAssertTrue(CallRecordingSettingsStrings(languageCode: "en").recordingsFooter.contains("on this device"))
    }

    func testEveryQualityHasItsOwnTitle() {
        for code in self.languageCodes {
            let strings = CallRecordingSettingsStrings(languageCode: code)
            let titles = CallRecordingVideoQuality.allCases.map(strings.qualityTitle)
            XCTAssertEqual(Set(titles).count, CallRecordingVideoQuality.allCases.count, code)
            XCTAssertEqual(strings.qualityTitle(.batterySaver), strings.qualityBatterySaver, code)
        }
    }
}
