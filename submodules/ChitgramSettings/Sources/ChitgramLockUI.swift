import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import LocalAuth
import PasscodeUI
import LocalizedPeerData
import ChitgramCore

// MARK: Setting a passcode

/// Asks for a new passcode twice with Telegram's own passcode screen (4 or 6 digits, or a password) and hands it
/// over (Android `SecretPasscodeScreen` in SET_NEW mode).
public func chitgramSetupPasscode(context: AccountContext, push: (ViewController) -> Void, completion: @escaping (String, Bool) -> Void) {
    let controller = PasscodeSetupController(context: context, mode: .setup(change: false, .digits4))
    controller.complete = { [weak controller] passcode, numeric in
        completion(passcode, numeric)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    push(controller)
}

// MARK: Unlocking

/// Opens something locked: Telegram's own passcode screen, which offers Face ID / Touch ID first (Android
/// `SecretLockScreen` is the same screen from Telegram Android). `digits` is what the passcode was set up with, nil for
/// free text. `completion` runs only on success.
public func chitgramUnlock(context: AccountContext, digits: Int?, check: @escaping (String) -> Bool, completion: @escaping () -> Void) {
    let kind: PostboxAccessChallengeData.Kind
    switch digits {
    case 4:
        kind = .digits4
    case 6:
        kind = .digits6
    default:
        kind = .alphanumeric
    }
    let controller = PasscodeEntryController(
        applicationBindings: context.sharedContext.applicationBindings,
        accountManager: context.sharedContext.accountManager,
        appLockContext: context.sharedContext.appLockContext,
        presentationData: context.sharedContext.currentPresentationData.with { $0 },
        presentationDataSignal: context.sharedContext.presentationData,
        statusBarHost: context.sharedContext.mainWindow?.statusBarHost,
        challengeData: .secured(id: "chitgram", kind: kind),
        biometrics: .enabled(LocalAuth.evaluatedPolicyDomainState),
        arguments: PasscodeEntryControllerPresentationArguments(cancel: {}, modalPresentation: true, displayAppLock: false)
    )
    controller.chitgramCheck = check
    controller.completed = completion
    controller.presentationCompleted = { [weak controller] in
        controller?.requestBiometrics()
    }
    context.sharedContext.presentGlobalController(controller, nil)
}

// MARK: The cover over a locked chat

/// Covers a locked chat until it is unlocked: the lock, the chat-lock title, Unlock and Back. The chat screen owns
/// its frame.
public final class ChitgramChatLockOverlayView: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let unlockButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let unlockAction: () -> Void
    private let backAction: () -> Void

    public init(theme: PresentationTheme, unlock: @escaping () -> Void, back: @escaping () -> Void) {
        self.unlockAction = unlock
        self.backAction = back
        super.init(frame: CGRect())

        self.backgroundColor = theme.list.plainBackgroundColor
        self.iconView.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 48.0, weight: .regular))?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = theme.list.itemAccentColor
        self.iconView.contentMode = .center
        self.addSubview(self.iconView)

        self.titleLabel.text = ChitgramStrings.get(252)
        self.titleLabel.font = UIFont.systemFont(ofSize: 20.0, weight: .semibold)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.textAlignment = .center
        self.addSubview(self.titleLabel)

        self.unlockButton.setTitle(ChitgramStrings.get(247), for: .normal)
        self.unlockButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.unlockButton.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
        self.unlockButton.backgroundColor = theme.list.itemCheckColors.fillColor
        self.unlockButton.layer.cornerRadius = 12.0
        self.unlockButton.addTarget(self, action: #selector(self.unlockPressed), for: .touchUpInside)
        self.addSubview(self.unlockButton)

        self.backButton.setTitle(ChitgramStrings.get(80), for: .normal)
        self.backButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0)
        self.backButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.backButton.addTarget(self, action: #selector(self.backPressed), for: .touchUpInside)
        self.addSubview(self.backButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func unlockPressed() {
        self.unlockAction()
    }

    @objc private func backPressed() {
        self.backAction()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        let centerY = size.height * 0.42
        let sideInset: CGFloat = 32.0
        self.iconView.frame = CGRect(x: 0.0, y: centerY - 90.0, width: size.width, height: 64.0)
        self.titleLabel.frame = CGRect(x: sideInset, y: centerY - 16.0, width: size.width - sideInset * 2.0, height: 28.0)
        self.unlockButton.frame = CGRect(x: sideInset, y: centerY + 32.0, width: size.width - sideInset * 2.0, height: 50.0)
        self.backButton.frame = CGRect(x: sideInset, y: centerY + 94.0, width: size.width - sideInset * 2.0, height: 44.0)
    }
}
