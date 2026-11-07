// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import StoreKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
/// What the system prompt is shown in: the window scene the user is looking at.
public typealias ReviewPromptTarget = UIWindowScene
#elseif os(macOS)
/// What the system prompt is shown in: the window the user is looking at.
public typealias ReviewPromptTarget = NSWindow
#else
/// The SDK asks for nothing on other platforms.
public typealias ReviewPromptTarget = AnyObject
#endif

/// The one place that calls the system rating prompt. Tests inject a spy.
@MainActor
public protocol ReviewPromptPresenting {
    /// Asks the system for its rating prompt. Returns false when it could not ask (app not active, no visible window,
    /// system too old); true means it asked, not that anything was shown.
    func requestReview(in target: ReviewPromptTarget?) -> Bool
}

/// Apple's system rating prompt, and nothing else: the SDK has no rating UI of its own.
///
/// - iOS 16+: `AppStore.requestReview(in:)` with the window scene; iOS 15: `SKStoreReviewController.requestReview(in:)`.
/// - macOS 13+: `AppStore.requestReview(in:)` with the window's view controller (the key window when nil);
///   macOS 10.14-12: `SKStoreReviewController.requestReview()`.
public struct ReviewPromptSystemPresenter: ReviewPromptPresenting {
    nonisolated public init() {
    }

    public func requestReview(in target: ReviewPromptTarget?) -> Bool {
        #if os(iOS)
        guard let scene = target, scene.activationState == .foregroundActive else {
            return false
        }
        if #available(iOS 16, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
        return true
        #elseif os(macOS)
        let application = NSApplication.shared
        guard application.isActive,
              let window = target ?? application.keyWindow ?? application.mainWindow,
              window.isVisible, !window.isMiniaturized else {
            return false
        }
        if #available(macOS 13, *) {
            guard let controller = window.contentViewController ?? ReviewPromptSystemPresenter.anchorController(in: window) else {
                return false
            }
            AppStore.requestReview(in: controller)
            return true
        } else {
            return ReviewPromptSystemPresenter.requestLegacyReview()
        }
        #else
        return false
        #endif
    }

    #if os(macOS)
    // Windows built without view controllers (the Mac app's TGUIKit) get a zero-size anchor controller whose view
    // sits in the window's content view. The last one stays until the next request replaces it, so StoreKit can
    // still reach its window after the call returns.
    private static var anchor: NSViewController?

    private static func anchorController(in window: NSWindow) -> NSViewController? {
        guard let contentView = window.contentView else {
            return nil
        }
        // The anchor's view was set by hand, so reading it never loads anything.
        ReviewPromptSystemPresenter.anchor?.view.removeFromSuperview()
        let controller = NSViewController()
        let view = NSView(frame: .zero)
        controller.view = view
        contentView.addSubview(view)
        ReviewPromptSystemPresenter.anchor = controller
        return controller
    }

    // Only runs before macOS 13. Marking it deprecated keeps the old StoreKit call from warning (an error with
    // -warnings-as-errors) in a host that deploys to macOS 15 or later.
    @available(macOS, deprecated: 13.0)
    private static func requestLegacyReview() -> Bool {
        if #available(macOS 10.14, *) {
            SKStoreReviewController.requestReview()
            return true
        }
        return false
    }
    #endif
}
