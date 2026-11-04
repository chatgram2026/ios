import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

private enum ChitgramEditHistoryEntry: ItemListNodeEntry {
    case header(index: Int32, title: String)
    case text(index: Int32, text: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(index, _), let .text(index, _):
            return index
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(index, _):
            return index * 2
        case let .text(index, _):
            return index * 2 + 1
        }
    }

    static func <(lhs: ChitgramEditHistoryEntry, rhs: ChitgramEditHistoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .header(_, title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: self.section)
        case let .text(_, text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
        }
    }
}

/// Chitgram "Tahrirlar tarixi" (Android `ui/message_history/MessageHistory`): every kept version of an edited
/// message, oldest first, each under the date it was written, and the current text last.
public func chitgramEditHistoryController(context: AccountContext, currentText: String, currentDate: Int32, versions: [ChitgramEditHistory.Version]) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ChitgramEditHistoryEntry] = []
        var index: Int32 = 0
        func add(text: String, date: Int32) {
            let title = stringForMediumDate(timestamp: date, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
            entries.append(.header(index: index, title: title))
            entries.append(.text(index: index, text: text))
            index += 1
        }
        for version in versions {
            add(text: version.text, date: version.date)
        }
        add(text: currentText, date: currentDate)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(390)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, ()))
    }
    return ItemListController(context: context, state: signal)
}
