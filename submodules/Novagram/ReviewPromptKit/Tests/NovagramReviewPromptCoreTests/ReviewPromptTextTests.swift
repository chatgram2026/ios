// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramReviewPromptCore

final class ReviewPromptTextTests: XCTestCase {
    private static let forbiddenPattern = #"\b(iPhone|iPad|iPod|Mac|macOS|iOS|iPadOS|Apple|Android|tap|click)\b"#

    private func allTexts() -> [(String, String)] {
        var texts: [(String, String)] = []
        for language in ReviewPromptLanguage.allCases {
            let strings = ReviewPromptStrings(languageCode: language.rawValue)
            texts.append(("\(language.rawValue).rateTitle", strings.rateTitle))
            texts.append(("\(language.rawValue).feedbackTitle", strings.feedbackTitle))
            texts.append(("\(language.rawValue).footer", strings.footer))
        }
        return texts
    }

    func testWriteReviewURL() {
        #if os(macOS)
        let expected = "macappstore://apps.apple.com/app/id6768202244?action=write-review"
        #else
        let expected = "https://apps.apple.com/app/id6768202244?action=write-review"
        #endif
        XCTAssertEqual(ReviewPromptLinks.writeReviewURL(appStoreId: 6768202244)?.absoluteString, expected)
        XCTAssertEqual(ReviewPromptLinks.writeReviewURL(), ReviewPromptLinks.writeReviewURL(appStoreId: 6768202244))
        XCTAssertEqual(ReviewPromptLinks.writeReviewURL(appStoreId: 1)?.query, "action=write-review")
        XCTAssertNil(ReviewPromptLinks.writeReviewURL(appStoreId: 0))
        XCTAssertNil(ReviewPromptLinks.writeReviewURL(appStoreId: -5))
    }

    // Every user-visible text, pinned. The regex below only catches English words; this catches any change.
    func testEveryTextIsPinned() {
        let expected: [String: [String]] = [
            "en": ["Rate Novagram", "Send feedback", "Your rating helps other people find Novagram."],
            "uz": ["Novagramni baholash", "Fikr-mulohaza yuborish", "Bahoyingiz boshqa odamlarga Novagramni topishga yordam beradi."],
            "ru": ["Оценить Novagram", "Обратная связь", "Ваша оценка помогает другим людям найти Novagram."],
            "zh": ["为 Novagram 评分", "发送反馈", "您的评分能帮助其他人找到 Novagram。"],
            "zh-hant": ["為 Novagram 評分", "傳送意見回饋", "您的評分能幫助其他人找到 Novagram。"]
        ]
        XCTAssertEqual(Set(expected.keys), Set(ReviewPromptLanguage.allCases.map(\.rawValue)))
        for (code, texts) in expected {
            let strings = ReviewPromptStrings(languageCode: code)
            XCTAssertEqual([strings.rateTitle, strings.feedbackTitle, strings.footer], texts, code)
        }
    }

    func testLanguageCodes() {
        XCTAssertEqual(ReviewPromptLanguage(code: "uz-Latn"), .uzbek)
        XCTAssertEqual(ReviewPromptLanguage(code: "ru_RU"), .russian)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh"), .chinese)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh-hans-raw"), .chinese)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh-Hans-HK"), .chinese)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh-Hant"), .chineseTraditional)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh-hant-raw"), .chineseTraditional)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh_TW"), .chineseTraditional)
        XCTAssertEqual(ReviewPromptLanguage(code: "zh-HK"), .chineseTraditional)
        XCTAssertEqual(ReviewPromptLanguage(code: "fr"), .english)
        XCTAssertEqual(ReviewPromptLanguage(code: ""), .english)
        XCTAssertEqual(ReviewPromptStrings(languageCode: "de"), ReviewPromptStrings(languageCode: "en"))
    }

    func testNoPlatformNamesAndNoTapOrClick() throws {
        let regex = try NSRegularExpression(pattern: ReviewPromptTextTests.forbiddenPattern, options: [.caseInsensitive])
        func matches(_ text: String) -> Bool {
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        // The pattern itself works.
        XCTAssertTrue(matches("Tap here on your iPhone"))
        XCTAssertTrue(matches("click"))
        XCTAssertFalse(matches("Novagram"))

        for (name, text) in self.allTexts() {
            XCTAssertFalse(matches(text), "\(name): \(text)")
        }
    }

    func testEnglishTextsPromiseNoReward() throws {
        let regex = try NSRegularExpression(pattern: #"\b(free|reward|gift|bonus|prize|premium)\b"#, options: [.caseInsensitive])
        for (name, text) in self.allTexts() where name.hasPrefix("en.") {
            XCTAssertNil(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(name): \(text)")
        }
    }
}
