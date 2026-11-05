import Foundation

/// The default text style put on every message when it is sent (Android `TextStyleDialog`, key `selected_style`).
/// Android's codes are kept.
public enum ChitgramTextStyle {
    public static let none = -1
    public static let bold = 50
    public static let italic = 51
    public static let mono = 52
    public static let regular = 54
    public static let strikethrough = 55
    public static let underline = 56
    public static let spoiler = 57
    public static let quote = 58

    /// The choices in Android's order, with their string ids.
    public static let choices: [(style: Int, titleId: Int)] = [
        (regular, 167), (spoiler, 168), (bold, 169), (italic, 170), (mono, 171), (strikethrough, 172), (underline, 173), (quote, 174)
    ]

    public static var selected: Int {
        return ChitgramPreferences.shared.userDefaults.object(forKey: "selected_style") as? Int ?? self.none
    }

    public static func setSelected(_ style: Int) {
        ChitgramPreferences.shared.userDefaults.set(style, forKey: "selected_style")
        ChitgramPreferences.shared.notifyChanged()
    }
}
