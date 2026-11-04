import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

/// The sections of Chitgram ▸ Sozlamalar, in Android's order (`FenixSettings.fillItems`). A section is added here
/// when its first feature is ported.
private enum ChitgramSettingsSection: Int32 {
    case stories

    /// Android string id of the section header.
    var titleId: Int {
        switch self {
        case .stories:
            return 135
        }
    }
}

/// The rows, in display order. `androidId` is the row's id in `FenixSettings`, kept for the
/// `tg://chatgram_settings/<key>` links.
private enum ChitgramSettingsRow: Int32 {
    case storyGhost
    case storyHide
    case storyDownload

    var section: ChitgramSettingsSection {
        switch self {
        case .storyGhost, .storyHide, .storyDownload:
            return .stories
        }
    }

    var androidId: Int {
        switch self {
        case .storyGhost:
            return 1
        case .storyHide:
            return 2
        case .storyDownload:
            return 17
        }
    }

    /// Android string ids of the title and of the line under it.
    var titleAndTextIds: (Int, Int) {
        switch self {
        case .storyGhost:
            return (232, 233)
        case .storyHide:
            return (136, 137)
        case .storyDownload:
            return (297, 298)
        }
    }

    var key: ChitgramPreferences.Key {
        switch self {
        case .storyGhost:
            return .ghostStory
        case .storyHide:
            return .hideStory
        case .storyDownload:
            return .storyDownload
        }
    }
}

private final class ChitgramSettingsArguments {
    let toggle: (ChitgramSettingsRow, Bool) -> Void

    init(toggle: @escaping (ChitgramSettingsRow, Bool) -> Void) {
        self.toggle = toggle
    }
}

private enum ChitgramSettingsEntry: ItemListNodeEntry {
    case header(ChitgramSettingsSection, String)
    case toggle(ChitgramSettingsRow, title: String, text: String, value: Bool)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _):
            return section.rawValue
        case let .toggle(row, _, _, _):
            return row.section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(section, _):
            return section.rawValue * 1000
        case let .toggle(row, _, _, _):
            return row.section.rawValue * 1000 + 1 + row.rawValue
        }
    }

    static func <(lhs: ChitgramSettingsEntry, rhs: ChitgramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramSettingsArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .toggle(row, title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(row, value)
            })
        }
    }
}

private func chitgramSettingsEntries() -> [ChitgramSettingsEntry] {
    let preferences = ChitgramPreferences.shared
    var entries: [ChitgramSettingsEntry] = []

    func toggle(_ row: ChitgramSettingsRow) {
        let (titleId, textId) = row.titleAndTextIds
        entries.append(.toggle(row, title: ChitgramStrings.get(titleId), text: ChitgramStrings.get(textId), value: preferences.bool(row.key)))
    }

    entries.append(.header(.stories, ChitgramStrings.get(ChitgramSettingsSection.stories.titleId)))
    toggle(.storyGhost)
    toggle(.storyHide)
    toggle(.storyDownload)

    return entries
}

/// Chitgram ▸ Sozlamalar (Android `FenixSettings`): Chitgram's switches, grouped and ordered as on Android.
public func chitgramSettingsController(context: AccountContext) -> ViewController {
    let arguments = ChitgramSettingsArguments(toggle: { row, value in
        ChitgramPreferences.shared.set(value, for: row.key)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        ChitgramStrings.setLanguageCode(presentationData.strings.primaryComponent.languageCode)

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(ChitgramSectionRow.settings.titleId)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: chitgramSettingsEntries(),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
