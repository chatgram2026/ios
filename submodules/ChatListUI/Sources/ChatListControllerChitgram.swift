import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import ContextUI
import TelegramPresentationData
import ChitgramCore
import ChitgramSettings

/// The ⋯ button's menu points at the button itself.
private final class ChitgramMenuReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceView: UIView

    init(controller: ViewController, sourceView: UIView) {
        self.controller = controller
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

extension ChatListControllerImpl {
    /// Chitgram's chat list menu (Android: the header ⋮ menu, after Night mode): Auto messenger, then Hide or Show
    /// stories when "Hide stories button" is on. The roulettes join it as they are ported.
    func chitgramOpenMenu(sourceView: UIView) {
        let context = self.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(463), icon: { theme in
            return generateTintedImage(image: UIImage(systemName: "clock.arrow.circlepath"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            self?.push(chitgramAutoPostController(context: context))
        })))
        if ChitgramPreferences.shared.bool(.hideStoryButtonInMenu) {
            let hidden = ChitgramPreferences.shared.bool(.hideStory)
            items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(hidden ? 230 : 136), icon: { theme in
                return generateTintedImage(image: UIImage(systemName: hidden ? "eye" : "eye.slash"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                ChitgramPreferences.shared.set(!hidden, for: .hideStory)
            })))
        }
        let contextController = makeContextController(presentationData: presentationData, source: .reference(ChitgramMenuReferenceContentSource(controller: self, sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(contextController)
    }
}

/// Chats moved into the secret folder in this session, kept out of the list through the pending-removal set until
/// the list's next update leaves them out on its own (Android: folder 100).
private var chitgramSecretPendingIds = Set<EnginePeer.Id>()

extension ChatListControllerImpl {
    /// The long press on the title: the secret folder's passcode, then its chats.
    func chitgramOpenSecretFolder() {
        guard ChitgramLock.hasSecretPassword() else {
            return
        }
        let context = self.context
        chitgramUnlock(context: context, digits: ChitgramLock.secretPasscodeDigits(), check: { passcode in
            return ChitgramLock.checkSecretPassword(passcode)
        }, completion: { [weak self] in
            self?.push(ChitgramSecretFolderController(context: context))
        })
    }

    /// The chat's menu item "Add to secret chat": hidden from the list at once.
    func chitgramMoveToSecretFolder(peerId: EnginePeer.Id) {
        ChitgramLock.setSecret(peerId.toInt64(), true)
        chitgramSecretPendingIds.insert(peerId)
        (self.displayNode as? ChatListControllerNode)?.effectiveContainerNode.updateState(onlyCurrent: false, { state in
            var state = state
            state.pendingRemovalItemIds.insert(ChatListNodeState.ItemId(peerId: peerId, threadId: nil))
            return state
        })
    }

    /// Back on the list: a chat taken out of the secret folder meanwhile shows again.
    func chitgramRefreshSecretChats() {
        let secret = ChitgramLock.secretChats()
        let returned = chitgramSecretPendingIds.filter { !secret.contains($0.toInt64()) }
        if returned.isEmpty {
            return
        }
        chitgramSecretPendingIds.subtract(returned)
        (self.displayNode as? ChatListControllerNode)?.effectiveContainerNode.updateState(onlyCurrent: false, { state in
            var state = state
            for peerId in returned {
                state.pendingRemovalItemIds.remove(ChatListNodeState.ItemId(peerId: peerId, threadId: nil))
            }
            return state
        })
    }
}

/// A folder's icon for "Folder icons" (Android `FolderIcons`): its own emoji when it has one, otherwise one for the
/// kind of chats it gathers.
func chitgramFolderIcon(emoticon: String?, categories: ChatListFilterPeerCategories) -> String {
    if let emoticon, !emoticon.isEmpty {
        return emoticon
    }
    if categories == .channels {
        return "\u{1F4E2}"
    } else if categories == .bots {
        return "\u{1F916}"
    } else if categories == .groups {
        return "\u{1F465}"
    } else if categories == .contacts || categories == .nonContacts || categories == [.contacts, .nonContacts] {
        return "\u{1F464}"
    }
    return "\u{1F4C1}"
}
