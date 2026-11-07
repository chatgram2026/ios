// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colours and text sizes of the recordings screen. The default follows the system appearance; the iOS app maps
/// Telegram's theme and its own text size (and turns ``followsDynamicType`` off, as Telegram's lists do).
@available(macOS 14, iOS 15, *)
public struct CallRecordingTheme {
    public var background: Color
    /// The rows' background.
    public var card: Color
    public var primaryText: Color
    public var secondaryText: Color
    /// The summary line, the day headers, the footer and the empty-state text. Telegram's lists draw these a
    /// little darker than a row's subtitle; the default is ``secondaryText``.
    public var freeText: Color
    public var accent: Color
    public var destructive: Color
    public var separator: Color
    /// Avatar gradients, top colour first. A name always gets the same one.
    public var avatarGradients: [[Color]]
    /// The name, in points before Dynamic Type.
    public var titleFontSize: CGFloat
    /// "Video call · 0:40 · 742,3 KB".
    public var subtitleFontSize: CGFloat
    /// The time on the right.
    public var timeFontSize: CGFloat
    /// The summary line, the day headers and the footer.
    public var freeTextFontSize: CGFloat
    /// Scale the sizes above with the system text size.
    public var followsDynamicType: Bool
    /// The space between the screen edge and the cards (iOS; 16 is the system's inset-grouped margin). Telegram's
    /// lists use 20.
    public var listSideInset: CGFloat

    public init(
        background: Color = CallRecordingTheme.systemBackground,
        card: Color = CallRecordingTheme.systemCard,
        primaryText: Color = CallRecordingTheme.systemPrimaryText,
        secondaryText: Color = CallRecordingTheme.systemSecondaryText,
        accent: Color = .accentColor,
        destructive: Color = .red,
        separator: Color = CallRecordingTheme.systemSeparator,
        avatarGradients: [[Color]] = CallRecordingTheme.defaultAvatarGradients,
        titleFontSize: CGFloat = 17,
        subtitleFontSize: CGFloat = 14,
        timeFontSize: CGFloat = 15,
        freeTextFontSize: CGFloat = 13,
        followsDynamicType: Bool = true,
        freeText: Color? = nil,
        listSideInset: CGFloat = 16
    ) {
        self.background = background
        self.card = card
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.freeText = freeText ?? secondaryText
        self.accent = accent
        self.destructive = destructive
        self.separator = separator
        self.avatarGradients = avatarGradients
        self.titleFontSize = titleFontSize
        self.subtitleFontSize = subtitleFontSize
        self.timeFontSize = timeFontSize
        self.freeTextFontSize = freeTextFontSize
        self.followsDynamicType = followsDynamicType
        self.listSideInset = listSideInset
    }

    /// The system appearance.
    public static var system: CallRecordingTheme {
        return CallRecordingTheme()
    }

    /// Telegram's seven avatar gradients (red, orange, violet, green, cyan, blue, pink).
    public static var defaultAvatarGradients: [[Color]] {
        let pairs: [(UInt32, UInt32)] = [
            (0xff516a, 0xff885e),
            (0xffa85c, 0xffcd6a),
            (0x665fff, 0x82b1ff),
            (0x54cb68, 0xa0de7e),
            (0x4acccd, 0x00fcfd),
            (0x2a9ef1, 0x72d5fd),
            (0xd669ed, 0xe0a2f3)
        ]
        return pairs.map { [CallRecordingTheme.color(rgb: $0.0), CallRecordingTheme.color(rgb: $0.1)] }
    }

    static func color(rgb: UInt32) -> Color {
        return Color(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }

    #if canImport(UIKit)
    public static var systemBackground: Color { Color(uiColor: .systemGroupedBackground) }
    public static var systemCard: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    public static var systemPrimaryText: Color { Color(uiColor: .label) }
    public static var systemSecondaryText: Color { Color(uiColor: .secondaryLabel) }
    public static var systemSeparator: Color { Color(uiColor: .separator) }
    #else
    public static var systemBackground: Color { Color(nsColor: .windowBackgroundColor) }
    public static var systemCard: Color { Color(nsColor: .controlBackgroundColor) }
    public static var systemPrimaryText: Color { Color(nsColor: .labelColor) }
    public static var systemSecondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    public static var systemSeparator: Color { Color(nsColor: .separatorColor) }
    #endif
}
