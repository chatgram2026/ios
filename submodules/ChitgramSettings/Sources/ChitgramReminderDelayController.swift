import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

/// The choices of the reminder delay; Android's picker goes from 1 to 59 minutes.
private let chitgramReminderDelays: [Int] = [1, 2, 3, 5, 10, 15, 20, 30, 45, 59]

private final class ChitgramReminderDelayArguments {
    let select: (Int) -> Void

    init(select: @escaping (Int) -> Void) {
        self.select = select
    }
}

private enum ChitgramReminderDelayEntry: ItemListNodeEntry {
    case delay(index: Int32, minutes: Int, title: String, selected: Bool)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case let .delay(index, _, _, _):
            return index
        }
    }

    static func <(lhs: ChitgramReminderDelayEntry, rhs: ChitgramReminderDelayEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramReminderDelayArguments
        switch self {
        case let .delay(_, minutes, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(minutes)
            })
        }
    }
}

/// "Eslatma vaqti" (Android: the reminder delay picker): how many minutes a message may stay unread.
func chitgramReminderDelayController(context: AccountContext) -> ViewController {
    var dismissImpl: (() -> Void)?
    let arguments = ChitgramReminderDelayArguments(select: { minutes in
        ChitgramPreferences.shared.set(minutes, for: .reminderDelayMin)
        dismissImpl?()
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let current = ChitgramPreferences.shared.int(.reminderDelayMin)
        var entries: [ChitgramReminderDelayEntry] = []
        for (index, minutes) in chitgramReminderDelays.enumerated() {
            entries.append(.delay(index: Int32(index), minutes: minutes, title: "\(minutes) \(ChitgramStrings.get(273))", selected: minutes == current))
        }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(272)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
