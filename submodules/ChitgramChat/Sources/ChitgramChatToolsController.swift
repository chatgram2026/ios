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
import ChitgramCore
import ChitgramSettings

private final class ChitgramChatToolsArguments {
    let toggleOneTime: (Bool) -> Void
    let toggleAutoText: (Bool) -> Void
    let editAutoText: () -> Void
    let toggleLock: () -> Void

    init(toggleOneTime: @escaping (Bool) -> Void, toggleAutoText: @escaping (Bool) -> Void, editAutoText: @escaping () -> Void, toggleLock: @escaping () -> Void) {
        self.toggleOneTime = toggleOneTime
        self.toggleAutoText = toggleAutoText
        self.editAutoText = editAutoText
        self.toggleLock = toggleLock
    }
}

private enum ChitgramChatToolsEntry: ItemListNodeEntry {
    case header(String)
    case oneTime(Bool)
    case autoText(Bool)
    case autoTextEdit(String)
    case lock(Bool)
    case lockFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .lock, .lockFooter:
            return 1
        default:
            return 0
        }
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .oneTime:
            return 1
        case .autoText:
            return 2
        case .autoTextEdit:
            return 3
        case .lock:
            return 4
        case .lockFooter:
            return 5
        }
    }

    static func <(lhs: ChitgramChatToolsEntry, rhs: ChitgramChatToolsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramChatToolsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .oneTime(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(306), text: ChitgramStrings.get(307), value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleOneTime(value)
            })
        case let .autoText(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(300), text: ChitgramStrings.get(301), value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleAutoText(value)
            })
        case let .autoTextEdit(current):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(302), label: current, sectionId: self.section, style: .blocks, action: {
                arguments.editAutoText()
            })
        case let .lock(isLocked):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(isLocked ? 247 : 246), kind: isLocked ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.toggleLock()
            })
        case let .lockFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// A chat's Chitgram tools (Android `ChatFenixSettings`, "Chitgram Sozlamalar" in the chat menu): one-time voice
/// messages now; the auto-added text and the chat lock join it as they are ported.
public func chitgramChatToolsController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let chatId = peerId.toInt64()
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentControllerImpl: ((ViewController) -> Void)?
    let showToast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }
    let arguments = ChitgramChatToolsArguments(toggleOneTime: { value in
        ChitgramPerChat.setOneTimeMedia(chatId, value)
    }, toggleAutoText: { value in
        var autoText = ChitgramPerChat.autoText(chatId)
        autoText.active = value
        ChitgramPerChat.setAutoText(chatId, autoText)
    }, editAutoText: {
        pushControllerImpl?(chitgramAutoTextEditorController(context: context, chatId: chatId))
    }, toggleLock: {
        let push: (ViewController) -> Void = { c in
            pushControllerImpl?(c)
        }
        if ChitgramLock.isLocked(chatId) {
            // Unlocking asks for the chat's passcode first.
            chitgramUnlock(context: context, digits: ChitgramLock.passcodeDigits(forChat: chatId), check: { passcode in
                return ChitgramLock.check(chatId, passcode: passcode)
            }, completion: {
                ChitgramLock.unlock(chatId)
            })
            return
        }
        // Android: "How to lock this chat?" — with the common passcode, or a passcode of its own.
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: ChitgramStrings.get(248), parseMarkdown: false),
                ActionSheetButtonItem(title: ChitgramStrings.get(249), color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    if ChitgramLock.hasCommonPassword() {
                        ChitgramLock.addCommonLock(chatId)
                    } else {
                        chitgramSetupPasscode(context: context, push: push, completion: { passcode, numeric in
                            ChitgramLock.setCommonPassword(passcode, numeric: numeric)
                            ChitgramLock.addCommonLock(chatId)
                            showToast(ChitgramStrings.get(38))
                        })
                    }
                }),
                ActionSheetButtonItem(title: ChitgramStrings.get(250), color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    chitgramSetupPasscode(context: context, push: push, completion: { passcode, numeric in
                        ChitgramLock.addIndividualLock(chatId, passcode: passcode, numeric: numeric)
                        showToast(ChitgramStrings.get(38))
                    })
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentControllerImpl?(actionSheet)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [ChitgramChatToolsEntry] = [
            .header(ChitgramStrings.get(305)),
            .oneTime(ChitgramPerChat.isOneTimeMedia(chatId)),
            .autoText(ChitgramPerChat.autoText(chatId).active),
            .autoTextEdit(ChitgramPerChat.autoText(chatId).text),
            .lock(ChitgramLock.isLocked(chatId)),
            .lockFooter(ChitgramStrings.get(341))
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(305)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}

private enum ChitgramAutoTextEditorEntry: ItemListNodeEntry {
    case text(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: ChitgramAutoTextEditorEntry, rhs: ChitgramAutoTextEditorEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let update = arguments as! (String) -> Void
        switch self {
        case let .text(text):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: ChitgramStrings.get(300), maxLength: nil, sectionId: self.section, style: .blocks, minimalHeight: 120.0, textUpdated: { value in
                update(value)
            })
        }
    }
}

/// The chat's auto text (Android `AutoTextEditor`): saved as you type.
private func chitgramAutoTextEditorController(context: AccountContext, chatId: Int64) -> ViewController {
    let update: (String) -> Void = { value in
        var autoText = ChitgramPerChat.autoText(chatId)
        autoText.text = value
        ChitgramPerChat.setAutoText(chatId, autoText)
    }
    let initialText = ChitgramPerChat.autoText(chatId).text
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(302)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [ChitgramAutoTextEditorEntry.text(initialText)], style: .blocks, animateChanges: false)
        return (controllerState, (listState, update))
    }
    return ItemListController(context: context, state: signal)
}
