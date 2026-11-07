// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Texts for the host's Settings rows. One text serves every platform: no device or platform names, no "tap" or
/// "click", and nothing that sounds like a reward. Every value can be overridden.
public struct ReviewPromptStrings: Equatable, Sendable {
    /// The row that opens the App Store's write-review page.
    public var rateTitle: String
    /// The row that opens the host's feedback channel.
    public var feedbackTitle: String
    /// The footer under the rows.
    public var footer: String

    public init(languageCode: String) {
        let language = ReviewPromptLanguage(code: languageCode)
        self.rateTitle = language.pick(
            en: "Rate Chitgram",
            uz: "Chitgramni baholash",
            ru: "Оценить Chitgram",
            zh: "为 Chitgram 评分",
            zhHant: "為 Chitgram 評分"
        )
        self.feedbackTitle = language.pick(
            en: "Send feedback",
            uz: "Fikr-mulohaza yuborish",
            ru: "Обратная связь",
            zh: "发送反馈",
            zhHant: "傳送意見回饋"
        )
        self.footer = language.pick(
            en: "Your rating helps other people find Chitgram.",
            uz: "Bahoyingiz boshqa odamlarga Chitgramni topishga yordam beradi.",
            ru: "Ваша оценка помогает другим людям найти Chitgram.",
            zh: "您的评分能帮助其他人找到 Chitgram。",
            zhHant: "您的評分能幫助其他人找到 Chitgram。"
        )
    }
}
