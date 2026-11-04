import Foundation
import UIKit
import Display
import TelegramPresentationData
import ChitgramCore

/// The rows of the "Chitgram" section in the Settings tab, in the order Android shows them
/// (`SettingsActivity.fillItems`, right under the accounts block).
public enum ChitgramSectionRow: Int, CaseIterable {
    case premium
    case voiceRoulette
    case chatRoulette
    case settings
    case appTheme
    case appCache
    case chatFinder
    case about

    /// The Android string id of the row's title.
    public var titleId: Int {
        switch self {
        case .premium:
            return 427
        case .voiceRoulette:
            return 698
        case .chatRoulette:
            return 787
        case .settings:
            return 236
        case .appTheme:
            return 120
        case .appCache:
            return 121
        case .chatFinder:
            return 123
        case .about:
            return 355
        }
    }

    public var title: String {
        return ChitgramStrings.get(self.titleId)
    }

    /// The row's icon: Android's two-colour tile with an iOS glyph of the same meaning.
    public var icon: UIImage? {
        return chitgramSectionIcons[self.rawValue]
    }
}

/// The header above the rows. Android writes it as a literal, not a translated string.
public let chitgramSectionTitle = "Chitgram"

private func chitgramIcon(_ name: String, top: UInt32, bottom: UInt32) -> UIImage? {
    // renderSettingsIcon draws its first colour at the bottom right and its last at the top left.
    return renderSettingsIcon(name: "Item List/Icons/\(name)", backgroundColors: [UIColor(rgb: bottom), UIColor(rgb: top)])
}

private let chitgramSectionIcons: [UIImage?] = ChitgramSectionRow.allCases.map { row in
    switch row {
    case .premium:
        return chitgramIcon("Premium", top: 0xFFB300, bottom: 0xF57C00)
    case .voiceRoulette:
        return chitgramIcon("Microphone", top: 0x1FC2A7, bottom: 0x2F80FF)
    case .chatRoulette:
        return chitgramIcon("Video", top: 0xFF5A7A, bottom: 0xE0484D)
    case .settings:
        return chitgramIcon("Folder", top: 0x7E57C2, bottom: 0x5E35B1)
    case .appTheme:
        return chitgramIcon("Appearance", top: 0x1BA4ED, bottom: 0x1488E1)
    case .appCache:
        return chitgramIcon("Pie", top: 0xC46EF4, bottom: 0x9F55DF)
    case .chatFinder:
        return chitgramIcon("View", top: 0xF28B31, bottom: 0xE26314)
    case .about:
        return chitgramIcon("Faq", top: 0x1FB0A5, bottom: 0x12968C)
    }
}
