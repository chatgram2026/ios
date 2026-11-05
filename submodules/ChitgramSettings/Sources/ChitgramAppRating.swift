import Foundation
import UIKit
import StoreKit
import Display
import AccountContext
import BuildConfig
import ChitgramCore

/// Getting the app rated (Android `AppRating`). The About screen has "Rate the app" and "Share with friends"; and once
/// Chitgram has been used on three different days, Apple's own in-app review card is asked for from the chat list.
///
/// Apple shows the card at most three times a year and never says whether it appeared, so it is asked for at most
/// every 30 days and three times in all (Android keeps the same limits for Google's card). The About row does not
/// rely on the card for the same reason: a button that sometimes does nothing reads as broken.
public enum ChitgramAppRating {
    private static let minDays = 3
    private static let gapDays = 30
    private static let maxAsks = 3

    private static let lastDayKey = "chitgram_rate_last_day"
    private static let daysKey = "chitgram_rate_days"
    private static let askedDayKey = "chitgram_rate_asked_day"
    private static let asksKey = "chitgram_rate_asks"

    private static var today: Int {
        return Int(Date().timeIntervalSince1970 / 86400.0)
    }

    /// The app's Apple ID in App Store Connect, from the build configuration's `appstore_id` (0 until it is known).
    private static func appStoreId(context: AccountContext) -> Int64? {
        let id = BuildConfig(baseAppBundleId: context.sharedContext.applicationBindings.appBundleId).appStoreId
        return id > 0 ? id : nil
    }

    /// The link the share text carries: the App Store page, or the Chitgram channel until the app's id is known.
    public static func shareUrl(context: AccountContext) -> String {
        if let appStoreId = self.appStoreId(context: context) {
            return "https://apps.apple.com/app/id\(appStoreId)"
        }
        return "https://t.me/chitgram_org"
    }

    /// "Rate the app": the App Store's review page, or the in-app card until the app's id is known.
    public static func openReviewPage(context: AccountContext, view: UIView?) {
        if let appStoreId = self.appStoreId(context: context) {
            context.sharedContext.applicationBindings.openUrl("https://apps.apple.com/app/id\(appStoreId)?action=write-review")
        } else {
            Task { @MainActor [weak view] in
                ChitgramAppRating.requestCard(view: view)
            }
        }
    }

    /// "Share with friends": Telegram's share sheet with a short invitation and the link.
    public static func share(context: AccountContext, present: (ViewController) -> Void) {
        let text = ChitgramStrings.get(606) + "\n" + self.shareUrl(context: context)
        present(context.sharedContext.makeShareController(context: context, params: ShareControllerParams(subject: .text(text))))
    }

    /// Called each time the main chat list appears: counts the days the app is used on, and once there are enough,
    /// asks for the review card a moment after the list settles.
    public static func onChatListShown(view: UIView) {
        let defaults = UserDefaults.standard
        let day = self.today
        if defaults.object(forKey: self.lastDayKey) as? Int != day {
            defaults.set(day, forKey: self.lastDayKey)
            defaults.set(defaults.integer(forKey: self.daysKey) + 1, forKey: self.daysKey)
        }
        if defaults.integer(forKey: self.daysKey) < self.minDays {
            return
        }
        let asks = defaults.integer(forKey: self.asksKey)
        if asks >= self.maxAsks {
            return
        }
        if asks > 0 && day - defaults.integer(forKey: self.askedDayKey) < self.gapDays {
            return
        }
        defaults.set(day, forKey: self.askedDayKey)
        defaults.set(asks + 1, forKey: self.asksKey)
        Task { @MainActor [weak view] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            ChitgramAppRating.requestCard(view: view)
        }
    }

    @MainActor
    private static func requestCard(view: UIView?) {
        guard let scene = view?.window?.windowScene else {
            return
        }
        if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
        }
    }
}
