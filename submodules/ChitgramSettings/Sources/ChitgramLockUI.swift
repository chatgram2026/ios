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

private final class ChitgramPasscodeEntryArguments {
    let updateText: (String) -> Void
    let submit: () -> Void

    init(updateText: @escaping (String) -> Void, submit: @escaping () -> Void) {
        self.updateText = updateText
        self.submit = submit
    }
}

private enum ChitgramPasscodeEntryEntry: ItemListNodeEntry {
    case header(String)
    case input(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .input:
            return 1
        }
    }

    static func <(lhs: ChitgramPasscodeEntryEntry, rhs: ChitgramPasscodeEntryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramPasscodeEntryArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .input(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: ChitgramStrings.get(65), type: .password, returnKeyType: .done, sectionId: self.section, textUpdated: { value in
                arguments.updateText(value)
            }, action: {
                arguments.submit()
            })
        }
    }
}

/// The passcode itself, for when Face ID / Touch ID is not there or not used.
private func chitgramPasscodeEntryController(context: AccountContext, title: String, check: @escaping (String) -> Bool, completion: @escaping () -> Void) -> ViewController {
    let text = ValuePromise<String>("", ignoreRepeated: false)
    var textValue = ""
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?

    let submit: () -> Void = {
        if check(textValue) {
            popImpl?()
            completion()
        } else {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: ChitgramStrings.get(36), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
            textValue = ""
            text.set("")
        }
    }
    let arguments = ChitgramPasscodeEntryArguments(updateText: { value in
        textValue = value
    }, submit: {
        submit()
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, text.get())
    |> map { presentationData, text -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(title),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Done), style: .bold, enabled: true, action: {
                submit()
            }),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [ChitgramPasscodeEntryEntry.header(ChitgramStrings.get(65)), .input(text)], style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    popImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}

/// Opens something locked: Face ID / Touch ID first, then the passcode (Android `SecretLockScreenDialog`, where the
/// fingerprint is offered automatically and the passcode stays the fallback). `completion` runs only on success.
public func chitgramUnlock(context: AccountContext, title: String, push: @escaping (ViewController) -> Void, check: @escaping (String) -> Bool, completion: @escaping () -> Void) {
    let _ = (LocalAuth.auth(reason: title)
    |> deliverOnMainQueue).startStandalone(next: { success, _ in
        if success {
            completion()
        } else {
            push(chitgramPasscodeEntryController(context: context, title: title, check: check, completion: completion))
        }
    })
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

// MARK: The secret folder

private final class ChitgramSecretFolderArguments {
    let openChat: (EnginePeer) -> Void

    init(openChat: @escaping (EnginePeer) -> Void) {
        self.openChat = openChat
    }
}

private enum ChitgramSecretFolderEntry: ItemListNodeEntry {
    case chat(index: Int, peer: EnginePeer, title: String)
    case empty(String)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int64 {
        switch self {
        case let .chat(_, peer, _):
            return peer.id.toInt64()
        case .empty:
            return Int64.min
        case .footer:
            return Int64.max
        }
    }

    static func ==(lhs: ChitgramSecretFolderEntry, rhs: ChitgramSecretFolderEntry) -> Bool {
        switch lhs {
        case let .chat(lhsIndex, lhsPeer, lhsTitle):
            if case let .chat(rhsIndex, rhsPeer, rhsTitle) = rhs {
                return lhsIndex == rhsIndex && lhsPeer == rhsPeer && lhsTitle == rhsTitle
            }
            return false
        case let .empty(text):
            if case .empty(text) = rhs {
                return true
            }
            return false
        case let .footer(text):
            if case .footer(text) = rhs {
                return true
            }
            return false
        }
    }

    private var sortIndex: Int {
        switch self {
        case .empty:
            return -1
        case let .chat(index, _, _):
            return index
        case .footer:
            return Int.max
        }
    }

    static func <(lhs: ChitgramSecretFolderEntry, rhs: ChitgramSecretFolderEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramSecretFolderArguments
        switch self {
        case let .chat(_, peer, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openChat(peer)
            })
        case let .empty(text), let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// The chats in the secret folder. Opened from a long press on the chat list title, after the folder's passcode.
public func chitgramSecretFolderController(context: AccountContext) -> ViewController {
    var navigateImpl: ((EnginePeer) -> Void)?
    let arguments = ChitgramSecretFolderArguments(openChat: { peer in
        navigateImpl?(peer)
    })

    let peers = ChitgramPreferences.shared.changes
    |> mapToSignal { _ -> Signal<[EnginePeer], NoError> in
        let ids = ChitgramLock.secretChats().sorted().map { EnginePeer.Id($0) }
        return context.engine.data.get(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { peers -> [EnginePeer] in
            return ids.compactMap { peers[$0] ?? nil }
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, peers)
    |> map { presentationData, peers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ChitgramSecretFolderEntry] = []
        if peers.isEmpty {
            entries.append(.empty(ChitgramStrings.get(372)))
        } else {
            let sorted = peers.map { peer -> (EnginePeer, String) in
                return (peer, peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder))
            }.sorted(by: { $0.1.lowercased() < $1.1.lowercased() })
            for (index, item) in sorted.enumerated() {
                entries.append(.chat(index: index, peer: item.0, title: item.1))
            }
        }
        entries.append(.footer(ChitgramStrings.get(217)))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(213)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    // A chat in the folder opens, or goes back to the chat list (Android: its menu in the folder).
    navigateImpl = { [weak controller] peer in
        guard let controller else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        let navigationController = controller.navigationController as? NavigationController
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: title, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let navigationController else {
                        return
                    }
                    context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
                }),
                ActionSheetButtonItem(title: ChitgramStrings.get(216), color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    ChitgramLock.setSecret(peer.id.toInt64(), false)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        controller.present(actionSheet, in: .window(.root))
    }
    return controller
}

/// The long press on the chat list title: the folder's passcode, then its chats.
public func chitgramOpenSecretFolder(context: AccountContext, push: @escaping (ViewController) -> Void) {
    guard ChitgramLock.hasSecretPassword() else {
        return
    }
    chitgramUnlock(context: context, title: ChitgramStrings.get(213), push: push, check: { passcode in
        return ChitgramLock.checkSecretPassword(passcode)
    }, completion: {
        push(chitgramSecretFolderController(context: context))
    })
}
