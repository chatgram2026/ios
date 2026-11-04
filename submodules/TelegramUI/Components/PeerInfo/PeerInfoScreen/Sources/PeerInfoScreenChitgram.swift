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

extension PeerInfoScreenNode {
    /// Chitgram: the chat's ⋮ menu items from Android (`ChatActivity` header menu), placed after Telegram's own in the
    /// profile's More menu, which is where Telegram-iOS keeps a chat's actions.
    func chitgramMoreMenuItems(peer: EnginePeer) -> [ContextMenuItem] {
        var items: [ContextMenuItem] = [.separator]

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
