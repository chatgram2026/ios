import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

private enum ChitgramPlaceholderEntry: ItemListNodeEntry {
    case text(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: ChitgramPlaceholderEntry, rhs: ChitgramPlaceholderEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section, textAlignment: .center)
        }
    }
}

/// The screen a row of the Chitgram section opens. Rows whose feature is not ported yet open a page with
/// the row's title, so the section already has its final shape and order.
///
/// App theme and App cache are Telegram's own screens; the Settings tab opens those itself.
public func chitgramSectionController(context: AccountContext, row: ChitgramSectionRow) -> ViewController {
    switch row {
    case .settings:
        return chitgramSettingsController(context: context)
    case .chatFinder:
        return chitgramChatFinderController(context: context)
    case .about:
        return chitgramAboutController(context: context)
    default:
        break
    }

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        ChitgramStrings.setLanguageCode(presentationData.strings.primaryComponent.languageCode)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(row.title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: [ChitgramPlaceholderEntry.text(row.title)],
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, ()))
    }
    return ItemListController(context: context, state: signal)
}
