import Foundation

/// Chitgram: the app's name in texts that come from language packs (the bundled English strings were rewritten by the
/// same rule): every "Telegram" that means the app becomes "Chitgram". Telegram's own services keep their name
/// (Telegram Premium, Stars, Passport…), since that is what they are.
private let chitgramRebrandPattern = try? NSRegularExpression(pattern: "\\bTelegram\\b(?!\\.[a-z])(?!\\s+(?:Premiums?|Passport|Stars?|Ads?|Business|Gifts?|Web|Desktop|X|API|Terms|Support|Team|Service|Wallet)\\b)", options: [])

/// Texts where "Telegram" is who runs the service, not this app: money, terms, stored data, moderation. They stay true
/// only under Telegram's name.
private let chitgramOperatorKeyPrefixes: [String] = [
    "AdsInfo.",
    "AgeVerification.",
    "Business.AdsInfo",
    "Chat.Giveaway.",
    "Checkout.",
    "FrozenAccount.",
    "Gift.",
    "Group.AdminLog.AntiSpamFalsePositiveReportedText",
    "Login.Fee.",
    "Login.TermsOfService",
    "Message.Giveaway",
    "Monetization.",
    "Notification.Giveaway",
    "Notification.PremiumGift",
    "Notification.StarsGift",
    "Notification.StarsGiveaway",
    "Passport.",
    "PeerInfo.Gifts.",
    "Premium.",
    "Privacy.Calls.P2PHelp",
    "Privacy.ContactsResetConfirmation",
    "Privacy.PaymentsClearInfoHelp",
    "Privacy.SecretChatsLinkPreviewsHelp",
    "PrivacyPolicy.",
    "PrivacySettings.DataSettingsHelp",
    "ProfileLevelInfo.",
    "Report.Succeed",
    "ReportAd.",
    "Settings.Ton.",
    "Settings.TransactionsTon.",
    "SponsoredMessageInfoScreen.",
    "Stars.",
    "Wallet.",
    "WebApp.DisclaimerText"
]

func chitgramRebranded(key: String, value: String) -> String {
    guard value.contains("Telegram"), let pattern = chitgramRebrandPattern else {
        return value
    }
    if chitgramOperatorKeyPrefixes.contains(where: { key.hasPrefix($0) }) {
        return value
    }
    return pattern.stringByReplacingMatches(in: value, options: [], range: NSRange(location: 0, length: (value as NSString).length), withTemplate: "Chitgram")
}
