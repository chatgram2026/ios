import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import UndoUI
import PresentationDataUtils
import ChitgramCore
import ChitgramChat
import ChitgramSettings

extension PeerInfoScreenNode {
    /// Chitgram: the chat's ⋮ menu items from Android (`ChatActivity` header menu), placed after Telegram's own in the
    /// profile's More menu, which is where Telegram-iOS keeps a chat's actions.
    func chitgramMoreMenuItems(peer: EnginePeer) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = [.separator]

        // Default text style for every message sent (Android `TextStyleDialog`).
        items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(166), icon: { theme in
            return generateTintedImage(image: UIImage(systemName: "textformat"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            self?.chitgramOpenTextStyle()
        })))

        // Voice to text (Android `VoiceTranslateSheet`): dictate into the chat's input box.
        if self.peerId.namespace != Namespaces.Peer.SecretChat && chitgramVoiceInputIsAvailable() {
            items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(308), icon: { theme in
                return generateTintedImage(image: UIImage(systemName: "mic"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.chitgramOpenVoiceToText(peerId: peer.id)
            })))
        }

        // Auto-translate of outgoing messages (Android `AutoTranslatePicker`), where the account can write.
        if self.peerId.namespace != Namespaces.Peer.SecretChat {
            let current = ChitgramAutoTranslate.language(peer.id.toInt64())
            let title = ChitgramStrings.get(324) + (current.map { " \u{00B7} " + ChitgramAutoTranslate.displayName($0) } ?? "")
            items.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                return generateTintedImage(image: UIImage(systemName: "character.bubble"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.chitgramOpenAutoTranslate(peerId: peer.id)
            })))
        }

        // Chat id as the row's label; tapping copies it (Android `show_chat_id`).
        let chatId = chitgramRecognizableId(peer.id)
        items.append(.action(ContextMenuActionItem(text: chatId, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            UIPasteboard.general.string = chatId
            guard let self else {
                return
            }
            self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: "\(chatId) \(ChitgramStrings.get(41))"), elevatedLayout: false, action: { _ in return false }), in: .current)
        })))

        // Per-chat tools (Android `ChatFenixSettings`), not for secret chats.
        if self.peerId.namespace != Namespaces.Peer.SecretChat {
            items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(305), icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Settings"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                guard let self else {
                    return
                }
                self.controller?.push(chitgramChatToolsController(context: self.context, peerId: peer.id))
            })))
        }

        if case let .channel(channel) = peer {
            // Bulk approve or decline pending join requests, where the account may invite.
            if channel.flags.contains(.isCreator) || channel.adminRights?.rights.contains(.canInviteUsers) == true {
                items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(279), icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AddUser"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)
                    self?.chitgramOpenJoinRequests(peerId: peer.id)
                })))
            }
            // Join this public channel or group on every other signed-in account at once.
            if let username = channel.addressName, !username.isEmpty {
                items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(294), icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)
                    self?.chitgramJoinOnAllAccounts(username: username)
                })))
            }
        }
        return items
    }

    private func chitgramOpenVoiceToText(peerId: EnginePeer.Id) {
        let chat = peerId.toInt64()
        chitgramPresentVoiceToText(context: self.context, present: { [weak self] c in
            self?.controller?.present(c, in: .window(.root))
        }, completion: { [weak self] text in
            guard let self else {
                return
            }
            if ChitgramChatBridge.insert(chat: chat, text: text) {
                // Back to the chat, where the text now waits in the input box.
                let _ = (self.controller?.navigationController as? NavigationController)?.popViewController(animated: true)
            } else {
                UIPasteboard.general.string = text
                self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: text), elevatedLayout: false, action: { _ in return false }), in: .current)
            }
        })
    }

    private func chitgramOpenAutoTranslate(peerId: EnginePeer.Id) {
        let chat = peerId.toInt64()
        let current = ChitgramAutoTranslate.language(chat)
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: ChitgramStrings.get(325), parseMarkdown: false)]
        items.append(ActionSheetButtonItem(title: (current == nil ? "\u{2713} " : "") + ChitgramStrings.get(326), color: .accent, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            ChitgramAutoTranslate.setLanguage(chat, nil)
        }))
        for language in ChitgramAutoTranslate.languages {
            let title = (language == current ? "\u{2713} " : "") + ChitgramAutoTranslate.displayName(language)
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                ChitgramAutoTranslate.setLanguage(chat, language)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: ChitgramStrings.get(177), color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.controller?.present(actionSheet, in: .window(.root))
    }

    private func chitgramOpenTextStyle() {
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        let selected = ChitgramTextStyle.selected
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: ChitgramStrings.get(175), parseMarkdown: false)]
        for choice in ChitgramTextStyle.choices {
            let title = (choice.style == selected ? "\u{2713} " : "") + ChitgramStrings.get(choice.titleId)
            items.append(ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                ChitgramTextStyle.setSelected(choice.style)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: ChitgramStrings.get(177), color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.controller?.present(actionSheet, in: .window(.root))
    }

    private func chitgramOpenJoinRequests(peerId: EnginePeer.Id) {
        let context = self.context
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        let dismiss: () -> Void = { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }
        let process: (Bool) -> Void = { [weak self] approve in
            dismiss()
            let _ = (chitgramProcessAllJoinRequests(account: context.account, peerId: peerId, approve: approve)
            |> deliverOnMainQueue).startStandalone(completed: {
                guard let self else {
                    return
                }
                let text = "\(ChitgramStrings.get(285)) \(ChitgramStrings.get(approve ? 289 : 290))"
                self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            })
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: ChitgramStrings.get(279)),
                ActionSheetButtonItem(title: "\(ChitgramStrings.get(282)) · \(ChitgramStrings.get(285))", color: .accent, action: {
                    process(true)
                }),
                ActionSheetButtonItem(title: "\(ChitgramStrings.get(283)) · \(ChitgramStrings.get(285))", color: .destructive, action: {
                    process(false)
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: ChitgramStrings.get(291), color: .accent, font: .bold, action: {
                    dismiss()
                })
            ])
        ])
        self.controller?.present(actionSheet, in: .window(.root))
    }

    private func chitgramJoinOnAllAccounts(username: String) {
        let currentAccountPeerId = self.context.account.peerId
        self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(296), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)

        let joins = self.context.sharedContext.activeAccountContexts
        |> take(1)
        |> mapToSignal { accounts -> Signal<Int, NoError> in
            // A channel's access hash is per account, so each account resolves the name itself before joining.
            let signals: [Signal<Int, NoError>] = accounts.accounts.compactMap { _, accountContext, _ in
                if accountContext.account.peerId == currentAccountPeerId {
                    return nil
                }
                return accountContext.engine.peers.resolvePeerByName(name: username, referrer: nil)
                |> mapToSignal { result -> Signal<Int, NoError> in
                    guard case let .result(peer) = result, let peer else {
                        return .complete()
                    }
                    return accountContext.engine.peers.joinChannel(peerId: peer.id, hash: nil)
                    |> map { _ -> Int in
                        return 1
                    }
                    |> `catch` { _ -> Signal<Int, NoError> in
                        return .single(0)
                    }
                }
                |> take(1)
            }
            return combineLatest(signals)
            |> map { values -> Int in
                return values.reduce(0, +)
            }
        }
        let _ = (joins
        |> deliverOnMainQueue).startStandalone(next: { [weak self] joined in
            guard let self else {
                return
            }
            self.controller?.present(UndoOverlayController(presentationData: self.presentationData, content: .succeed(text: "\(joined) \(ChitgramStrings.get(295))", timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
        })
    }
}

/// The id Android shows for a chat (`fenixRecognizableId`): Bot API style, -100… for channels and supergroups,
/// minus for basic groups, the user id for users.
private func chitgramRecognizableId(_ peerId: EnginePeer.Id) -> String {
    let id = peerId.id._internalGetInt64Value()
    switch peerId.namespace {
    case Namespaces.Peer.CloudChannel:
        return "-100\(id)"
    case Namespaces.Peer.CloudGroup:
        return "-\(id)"
    default:
        return "\(id)"
    }
}
