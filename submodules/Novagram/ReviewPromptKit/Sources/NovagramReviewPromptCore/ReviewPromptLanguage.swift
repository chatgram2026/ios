// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The languages the SDK has built-in text for. Any other language gets English.
public enum ReviewPromptLanguage: String, Sendable, CaseIterable {
    case english = "en"
    case uzbek = "uz"
    case russian = "ru"
    /// Simplified Chinese.
    case chinese = "zh"
    /// Traditional Chinese.
    case chineseTraditional = "zh-hant"

    /// "uz", "uz-Latn", "ru_RU", "zh-hans-raw", "zh-Hant", "zh-TW", ...; any other code is English. Chinese is
    /// Traditional for a Hant script, or for Taiwan, Hong Kong and Macau without an explicit Hans script.
    public init(code: String) {
        let parts = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let base = parts.first else {
            self = .english
            return
        }
        if base == "zh" {
            let traditionalRegions: Set<String> = ["tw", "hk", "mo"]
            if parts.contains("hant") || (!parts.contains("hans") && parts.contains(where: { traditionalRegions.contains($0) })) {
                self = .chineseTraditional
            } else {
                self = .chinese
            }
            return
        }
        self = ReviewPromptLanguage(rawValue: base) ?? .english
    }

    /// The text for this language.
    public func pick(en: String, uz: String, ru: String, zh: String, zhHant: String) -> String {
        switch self {
        case .english:
            return en
        case .uzbek:
            return uz
        case .russian:
            return ru
        case .chinese:
            return zh
        case .chineseTraditional:
            return zhHant
        }
    }
}
