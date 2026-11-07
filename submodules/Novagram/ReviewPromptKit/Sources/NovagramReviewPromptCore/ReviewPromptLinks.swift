// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Links for a Settings "Rate Chitgram" row. A row opens the App Store's write-review page; it never calls the
/// system prompt, which Apple does not allow from a button.
///
/// On macOS the link uses `macappstore://`, so it opens the App Store app instead of the default browser.
public enum ReviewPromptLinks {
    /// Chitgram's App Store id (App Store Connect > the app > App Information > Apple ID; the same value as
    /// `appstore_id` in codemagic.yaml). At 0 the Settings "Rate" row is hidden.
    public static let chitgramAppStoreId = 6831325153

    /// `https://apps.apple.com/app/id<appStoreId>?action=write-review` (`macappstore://` on macOS), or nil for an id
    /// that is not positive.
    public static func writeReviewURL(appStoreId: Int = ReviewPromptLinks.chitgramAppStoreId) -> URL? {
        guard appStoreId > 0 else {
            return nil
        }
        return URL(string: "\(ReviewPromptLinks.scheme)://apps.apple.com/app/id\(appStoreId)?action=write-review")
    }

    #if os(macOS)
    static let scheme = "macappstore"
    #else
    static let scheme = "https"
    #endif
}
