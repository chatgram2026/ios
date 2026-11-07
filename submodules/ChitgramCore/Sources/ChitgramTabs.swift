import Foundation

/// The bottom tab bar's order, visibility and start tab (Android `utils/ChatgramTabs`, keys `tabs_order`,
/// `tabs_hidden`, `tabs_customized`, `tabs_start`). Android's ids are kept; iOS has no separate Profile tab, so
/// Settings stands for both.
public enum ChitgramTabs {
    public static let chats = 0
    public static let contacts = 1
    public static let settings = 2
    public static let calls = 3

    /// Android: at least two tabs stay on.
    public static let minVisible = 2

    /// Posted when the bar should be rebuilt; the tab bar listens to this only, not to every preference.
    public static let didChangeNotification = Notification.Name("ChitgramTabsDidChange")

    /// Android's order, Chats first. Settings stands for both Android's Settings and Profile, so it stays last.
    private static let defaultOrder = [chats, contacts, calls, settings]

    /// The button beside the tabs (Android `EXTRA_*`, the same numbers).
    public static let extraNone = 0
    public static let extraSearch = 1
    public static let extraNewMessage = 2
    public static let extraSaved = 3

    /// Which tabs show their name (Android `LABELS_*`, the same numbers).
    public static let labelsAll = 0
    public static let labelsSelected = 1
    public static let labelsNone = 2

    /// Posted when the button beside the tabs is pressed; the root controller acts on it.
    public static let extraButtonPressedNotification = Notification.Name("ChitgramTabsExtraButtonPressed")

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: self.didChangeNotification, object: nil)
        ChitgramPreferences.shared.notifyChanged()
    }

    private static func parse(_ text: String?) -> [Int] {
        return (text ?? "").split(separator: ",").compactMap { Int($0) }
    }

    public static var isCustomized: Bool {
        return self.defaults.bool(forKey: "tabs_customized")
    }

    /// Every iOS tab, in the user's order.
    public static func order() -> [Int] {
        guard self.isCustomized else {
            return self.defaultOrder
        }
        var result = self.parse(self.defaults.string(forKey: "tabs_order")).filter { self.defaultOrder.contains($0) }
        for tab in self.defaultOrder where !result.contains(tab) {
            result.append(tab)
        }
        return result
    }

    public static func setOrder(_ order: [Int]) {
        self.defaults.set(order.map { "\($0)" }.joined(separator: ","), forKey: "tabs_order")
        self.defaults.set(true, forKey: "tabs_customized")
        self.notifyChanged()
    }

    public static func hidden() -> Set<Int> {
        return Set(self.parse(self.defaults.string(forKey: "tabs_hidden")))
    }

    /// Chats is always shown.
    public static func isVisible(_ tab: Int) -> Bool {
        return tab == self.chats || !self.hidden().contains(tab)
    }

    /// False when the change would leave fewer than two tabs or hide Chats.
    @discardableResult
    public static func setVisible(_ tab: Int, _ visible: Bool) -> Bool {
        if tab == self.chats && !visible {
            return false
        }
        var hidden = self.hidden()
        if visible {
            hidden.remove(tab)
        } else {
            hidden.insert(tab)
        }
        if self.defaultOrder.filter({ !hidden.contains($0) }).count < self.minVisible {
            return false
        }
        self.defaults.set(hidden.sorted().map { "\($0)" }.joined(separator: ","), forKey: "tabs_hidden")
        self.defaults.set(true, forKey: "tabs_customized")
        self.notifyChanged()
        return true
    }

    /// The tab the app opens on; Chats by default.
    public static func startTab() -> Int {
        let value = self.defaults.object(forKey: "tabs_start") as? Int ?? self.chats
        return self.isVisible(value) ? value : self.chats
    }

    public static func setStartTab(_ tab: Int) {
        self.defaults.set(tab, forKey: "tabs_start")
        self.notifyChanged()
    }

    public static func extraButton() -> Int {
        return self.defaults.integer(forKey: "tabs_extra")
    }

    public static func setExtraButton(_ value: Int) {
        self.defaults.set(value, forKey: "tabs_extra")
        self.notifyChanged()
    }

    public static func labelsMode() -> Int {
        return self.defaults.integer(forKey: "tabs_labels")
    }

    public static func setLabelsMode(_ value: Int) {
        self.defaults.set(value, forKey: "tabs_labels")
        self.notifyChanged()
    }

    public static func reset() {
        for key in ["tabs_order", "tabs_hidden", "tabs_customized", "tabs_start", "tabs_extra", "tabs_labels"] {
            self.defaults.removeObject(forKey: key)
        }
        self.notifyChanged()
    }
}
