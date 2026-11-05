import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import UndoUI
import TelegramCore
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

    /// Lets the chat's profile menu put text into this chat's input box ("Voice to text").
    func chitgramRegisterInputBridge() {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        ChitgramChatBridge.register(chat: peerId.toInt64(), insert: { [weak self] text in
            guard let self else {
                return false
            }
            let state = self.presentationInterfaceState.interfaceState.composeInputState
            let length = state.inputText.length
            let separator = length > 0 ? " " : ""
            self.updateTextInputState(state.replacingFlatRange(NSRange(location: length, length: 0), with: separator + text))
            return true
        })
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

/// The default text style (Android `TextStyleDialog.changeTextStyle`): any formatting is cleared, then the chosen
/// style covers the whole message; Regular only clears.
func chitgramApplyTextStyle(_ attributes: [EngineMessage.Attribute], text: String) -> [EngineMessage.Attribute] {
    let style = ChitgramTextStyle.selected
    if style == ChitgramTextStyle.none || text.isEmpty {
        return attributes
    }
    var entities: [MessageTextEntity] = []
    var result: [EngineMessage.Attribute] = []
    for attribute in attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            entities = attribute.entities
        } else {
            result.append(attribute)
        }
    }
    entities = entities.filter { entity in
        switch entity.type {
        case .Bold, .Italic, .Code, .Strikethrough, .Underline, .Spoiler, .BlockQuote:
            return false
        default:
            return true
        }
    }
    let type: MessageTextEntityType?
    switch style {
    case ChitgramTextStyle.bold:
        type = .Bold
    case ChitgramTextStyle.italic:
        type = .Italic
    case ChitgramTextStyle.mono:
        type = .Code
    case ChitgramTextStyle.strikethrough:
        type = .Strikethrough
    case ChitgramTextStyle.underline:
        type = .Underline
    case ChitgramTextStyle.spoiler:
        type = .Spoiler
    case ChitgramTextStyle.quote:
        type = .BlockQuote(isCollapsed: false)
    default:
        type = nil
    }
    if let type {
        entities.append(MessageTextEntity(range: 0 ..< (text as NSString).length, type: type))
    }
    if !entities.isEmpty {
        result.append(TextEntitiesMessageAttribute(entities: entities))
    }
    return result
}

// Chitgram: the text the last auto-translate put in the input box; sending that text sends it as it is.
private var chitgramAutoTranslatedText: String?
private var chitgramAutoTranslating = false

extension ChatControllerImpl {
    /// Auto-translate (Android `AutoTranslate`): with a language set for this chat, the first Send translates the
    /// typed text and shows it in the input box; the second Send sends it. True when the send should wait.
    func chitgramAutoTranslateBeforeSend(_ state: ChatTextInputState) -> Bool {
        guard let peerId = self.chatLocation.peerId, let language = ChitgramAutoTranslate.language(peerId.toInt64()) else {
            return false
        }
        let text = state.inputText.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if text == chitgramAutoTranslatedText {
            chitgramAutoTranslatedText = nil
            return false
        }
        if chitgramAutoTranslating {
            return true
        }
        chitgramAutoTranslating = true
        self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(327), timeout: 1.5, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        let _ = (self.context.engine.messages.translate(text: text, toLang: language)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] result in
            chitgramAutoTranslating = false
            guard let self else {
                return
            }
            if let (translated, _) = result, !translated.isEmpty {
                chitgramAutoTranslatedText = translated
                self.updateTextInputState(ChatTextInputState(inputText: NSAttributedString(string: translated)))
            } else {
                // Nothing to show: the next Send sends the text as it is.
                chitgramAutoTranslatedText = text
                self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(328), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            }
        }, error: { [weak self] _ in
            chitgramAutoTranslating = false
            chitgramAutoTranslatedText = text
            guard let self else {
                return
            }
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(328), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        })
        return true
    }
}
