import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import ContextUI
import TelegramPresentationData
import UndoUI
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
    /// Chitgram's chat list menu (Android: the header ⋮ menu, after Night mode): the auto messenger, then the
    /// roulettes.
    func chitgramOpenMenu(sourceView: UIView) {
        let context = self.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        ChitgramStrings.setLanguageCode(presentationData.strings.primaryComponent.languageCode)
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: ChitgramStrings.get(463), icon: { theme in
            return generateTintedImage(image: UIImage(systemName: "clock.arrow.circlepath"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.dismissWithoutContent)
            self?.push(chitgramAutoPostController(context: context))
        })))
        // The roulettes, in Android's order; "Coming soon" until they are built.
        for (title, symbol) in [(ChitgramStrings.get(698), "waveform"), (ChitgramStrings.get(787), "video")] {
            items.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                return generateTintedImage(image: UIImage(systemName: symbol), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: ChitgramStrings.get(447), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            })))
        }
        let contextController = makeContextController(presentationData: presentationData, source: .reference(ChitgramMenuReferenceContentSource(controller: self, sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        self.presentInGlobalOverlay(contextController)
    }
}
