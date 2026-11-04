import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

private final class ChitgramAutoAnswerTextArguments {
    let updateText: (String) -> Void

    init(updateText: @escaping (String) -> Void) {
        self.updateText = updateText
    }
}

private enum ChitgramAutoAnswerTextEntry: ItemListNodeEntry {
    case text(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: ChitgramAutoAnswerTextEntry, rhs: ChitgramAutoAnswerTextEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoAnswerTextArguments
        switch self {
        case let .text(text):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: ChitgramStrings.get(238), maxLength: nil, sectionId: self.section, style: .blocks, minimalHeight: 120.0, textUpdated: { value in
                arguments.updateText(value)
            })
        }
    }
}

/// The auto answer's reply (Android `AutoAnswerMenu`): a plain text field that saves as you type, no Done button.
func chitgramAutoAnswerTextController(context: AccountContext) -> ViewController {
    let arguments = ChitgramAutoAnswerTextArguments(updateText: { value in
        ChitgramPreferences.shared.set(value, for: .autoAnswerText)
    })
    // Read once: the field owns the text while the screen is open, so redraws must not fight the typing.
    let initialText = ChitgramPreferences.shared.string(.autoAnswerText)

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(228)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [ChitgramAutoAnswerTextEntry.text(initialText)], style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
