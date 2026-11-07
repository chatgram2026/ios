import Foundation

/// What Chitgram Premium lifts, so the page that lists it and the features that enforce it read one number.
public enum ChitgramLimits {
    /// Android `UserConfig.MAX_ACCOUNT_DEFAULT_COUNT`, `MAX_ACCOUNT_COUNT`.
    public static let freeAccounts = 10
    public static let premiumAccounts = 32
    /// Android `ShareBar.FREE_BULK`, `PREMIUM_BULK`: ticking a whole category at once.
    public static let freeShareBulk = 10
    public static let premiumShareBulk = 100
}
