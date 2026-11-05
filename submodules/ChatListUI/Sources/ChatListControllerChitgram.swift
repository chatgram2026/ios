import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
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
