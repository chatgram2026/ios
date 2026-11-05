import Foundation

/// Where auto-accept of join requests applies, per account (Android `AutoAcceptJoin`, keys `auto_accept_all_<n>` and
/// `auto_accept_chats_<n>`): every chat the account can approve requests in, or only the chats picked. The switch
/// itself is `ChitgramPreferences.Key.autoAcceptJoin`. Accounts and chats are `toInt64()` peer ids.
public enum ChitgramAutoAccept {
    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func notifyChanged() {
        ChitgramPreferences.shared.notifyChanged()
    }

    public static func acceptsEverywhere(account: Int64) -> Bool {
        return self.defaults.object(forKey: "auto_accept_all_\(account)") as? Bool ?? true
    }

    public static func setAcceptsEverywhere(account: Int64, _ value: Bool) {
        self.defaults.set(value, forKey: "auto_accept_all_\(account)")
        self.notifyChanged()
    }

    public static func chosen(account: Int64) -> Set<Int64> {
        let values = self.defaults.array(forKey: "auto_accept_chats_\(account)") as? [NSNumber] ?? []
        return Set(values.map { $0.int64Value })
    }

    public static func setChosen(account: Int64, _ ids: Set<Int64>) {
        self.defaults.set(ids.map { NSNumber(value: $0) }, forKey: "auto_accept_chats_\(account)")
        self.notifyChanged()
    }

    public static func isChosen(account: Int64, chat: Int64) -> Bool {
        return self.acceptsEverywhere(account: account) || self.chosen(account: account).contains(chat)
    }

    /// "Off", "Everywhere" or "In N chats": the value shown on the settings row.
    public static func statusLabel(account: Int64) -> String {
        if !ChitgramPreferences.shared.bool(.autoAcceptJoin) {
            return ChitgramStrings.get(615)
        } else if self.acceptsEverywhere(account: account) {
            return ChitgramStrings.get(616)
        } else {
            return ChitgramStrings.format(617, self.chosen(account: account).count)
        }
    }
}
