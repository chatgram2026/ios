import Foundation
import UIKit
import Display
import AccountContext
import AlertUI
import PresentationDataUtils
import ChitgramCore
import ChitgramSettings

// Chitgram: set by "Special forward" in the message menu for the forward it starts (main thread only).
var chitgramForwardHidingSender = false

/// The options a forward runs with: "Special forward" (Android `special_forward`) hides the original sender's name.
func chitgramForwardOptions(_ requested: ChatInterfaceForwardOptionsState?) -> ChatInterfaceForwardOptionsState? {
    if chitgramForwardHidingSender {
        chitgramForwardHidingSender = false
        return ChatInterfaceForwardOptionsState(hideNames: true, hideCaptions: requested?.hideCaptions ?? false, unhideNamesOnCaptionChange: false)
    }
    return requested
}

// Chitgram: the chat screen's own additions, kept out of the upstream files except for one-line hooks.
extension ChatControllerImpl {
    /// Android `ConfirmDialog`: "Chitgram" over "Do you really want to send?" with OK and Cancel. `completion`
    /// runs on OK; the caller re-enters its own send with `chitgramSendConfirmed` set so it does not ask twice.
    func chitgramConfirmSend(completion: @escaping () -> Void) {
        let strings = self.presentationInterfaceState.strings
        self.present(textAlertController(context: self.context, title: "Chitgram", text: ChitgramStrings.get(195), actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: completion)
        ]), in: .window(.root))
    }
}

// Chitgram: the chat lock (Android `SecretLockScreenDialog` on opening a locked chat).
extension ChatControllerImpl {
    /// Covers the chat when it is locked and not opened yet.
    func chitgramApplyChatLock() {
        guard !self.chitgramUnlocked, self.chitgramLockOverlay == nil, let peerId = self.chatLocation.peerId, ChitgramLock.isLocked(peerId.toInt64()) else {
            return
        }
        let overlay = ChitgramChatLockOverlayView(theme: self.presentationData.theme, unlock: { [weak self] in
            self?.chitgramRequestUnlock()
        }, back: { [weak self] in
            guard let self else {
                return
            }
            if let navigationController = self.navigationController as? NavigationController {
                let _ = navigationController.popViewController(animated: true)
            } else {
                self.dismiss()
            }
        })
        overlay.frame = self.view.bounds
        self.view.addSubview(overlay)
        self.chitgramLockOverlay = overlay
    }

    /// Face ID / Touch ID right away, once; the passcode and the Unlock button stay for later tries.
    func chitgramPromptUnlockIfNeeded() {
        // Previews never get viewDidAppear, so this only runs for an opened chat.
        if self.chitgramLockOverlay != nil && !self.chitgramUnlockPrompted {
            self.chitgramUnlockPrompted = true
            self.chitgramRequestUnlock()
        }
    }

    func chitgramRequestUnlock() {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        let chatId = peerId.toInt64()
        chitgramUnlock(context: self.context, title: ChitgramStrings.get(252), push: { [weak self] c in
            (self?.navigationController as? NavigationController)?.pushViewController(c)
        }, check: { passcode in
            return ChitgramLock.check(chatId, passcode: passcode)
        }, completion: { [weak self] in
            guard let self else {
                return
            }
            self.chitgramUnlocked = true
            self.chitgramLockOverlay?.removeFromSuperview()
            self.chitgramLockOverlay = nil
        })
    }
}
