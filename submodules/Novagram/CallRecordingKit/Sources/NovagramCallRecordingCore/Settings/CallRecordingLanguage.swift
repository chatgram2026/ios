// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The languages the SDK has built-in text for. Any other language gets English.
public enum CallRecordingLanguage: String, Sendable, CaseIterable {
    case english = "en"
    case uzbek = "uz"
    case russian = "ru"
    case chinese = "zh"

    /// "uz", "uz-Latn", "ru_RU", "zh-hans-raw", "zh-Hant", ...; any other code is English.
    public init(code: String) {
        let lowered = code.lowercased()
        let base = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lowered
        self = CallRecordingLanguage(rawValue: base) ?? .english
    }

    /// The text for this language.
    public func pick(en: String, uz: String, ru: String, zh: String) -> String {
        switch self {
        case .english:
            return en
        case .uzbek:
            return uz
        case .russian:
            return ru
        case .chinese:
            return zh
        }
    }
}
