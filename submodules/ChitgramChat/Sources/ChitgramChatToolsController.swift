import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

private final class ChitgramChatToolsArguments {
    let toggleOneTime: (Bool) -> Void

    init(toggleOneTime: @escaping (Bool) -> Void) {
        self.toggleOneTime = toggleOneTime
    }
}

private enum ChitgramChatToolsEntry: ItemListNodeEntry {
    case header(String)
    case oneTime(Bool)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .oneTime:
            return 1
        }
    }

    static func <(lhs: ChitgramChatToolsEntry, rhs: ChitgramChatToolsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramChatToolsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .oneTime(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(306), text: ChitgramStrings.get(307), value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleOneTime(value)
            })
        }
    }
}

/// A chat's Chitgram tools (Android `ChatFenixSettings`, "Chitgram Sozlamalar" in the chat menu): one-time voice
/// messages now; the auto-added text and the chat lock join it as they are ported.
public func chitgramChatToolsController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let chatId = peerId.toInt64()
    let arguments = ChitgramChatToolsArguments(toggleOneTime: { value in
        ChitgramPerChat.setOneTimeMedia(chatId, value)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [ChitgramChatToolsEntry] = [
            .header(ChitgramStrings.get(305)),
            .oneTime(ChitgramPerChat.isOneTimeMedia(chatId))
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(305)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
