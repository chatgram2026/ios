import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

/// The sections of Chitgram ▸ Sozlamalar, in Android's order (`FenixSettings.fillItems`). A section is added here
/// when its first feature is ported.
private enum ChitgramSettingsSection: Int32 {
    case stories
    case messages
    case download
    case autoAnswer
    case privacy

    /// Android string id of the section header.
    var titleId: Int {
        switch self {
        case .stories:
            return 135
        case .messages:
            return 234
        case .download:
            return 237
        case .autoAnswer:
            return 228
        case .privacy:
            return 244
        }
    }
}

/// The rows, in display order. `androidId` is the row's id in `FenixSettings`, kept for the
/// `tg://chatgram_settings/<key>` links.
private enum ChitgramSettingsRow: Int32 {
    case storyGhost
    case storyHide
    case storyDownload
    case editSave
    case deleteSave
    case downloadStop
    case autoAnswerActive
    case autoAnswerText
    case ghostMode
    case ghostRead
    case ghostOnline
    case ghostTyping
    case ghostUpload
    case ghostButton
    case hideSponsored

    var section: ChitgramSettingsSection {
        switch self {
        case .storyGhost, .storyHide, .storyDownload:
            return .stories
        case .editSave, .deleteSave:
            return .messages
        case .downloadStop:
            return .download
        case .autoAnswerActive, .autoAnswerText:
            return .autoAnswer
        case .ghostMode, .ghostRead, .ghostOnline, .ghostTyping, .ghostUpload, .ghostButton, .hideSponsored:
            return .privacy
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
        case .editSave:
            return 20
        case .deleteSave:
            return 21
        case .downloadStop:
            return 5
        case .autoAnswerActive:
            return 6
        case .autoAnswerText:
            return 7
        case .ghostMode:
            return 22
        case .ghostRead:
            return 34
        case .ghostOnline:
            return 35
        case .ghostTyping:
            return 36
        case .ghostUpload:
            return 37
        case .ghostButton:
            return 26
        case .hideSponsored:
            return 38
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
        case .editSave:
            return (23, 72)
        case .deleteSave:
            return (31, 235)
        case .downloadStop:
            return (183, 196)
        case .autoAnswerActive:
            return (228, 239)
        case .autoAnswerText:
            // A button: its title only.
            return (238, -1)
        case .ghostMode:
            return (32, 245)
        case .ghostRead:
            return (558, 559)
        case .ghostOnline:
            return (560, 561)
        case .ghostTyping:
            return (562, 563)
        case .ghostUpload:
            return (564, 565)
        case .ghostButton:
            return (342, 343)
        case .hideSponsored:
            return (566, 567)
        }
    }

    /// The Chitgram switch behind the row, for rows that are a plain switch.
    var preferenceKey: ChitgramPreferences.Key? {
        switch self {
        case .storyGhost:
            return .ghostStory
        case .storyHide:
            return .hideStory
        case .storyDownload:
            return .storyDownload
        case .editSave:
            return .saveEdited
        case .autoAnswerActive:
            return .autoAnswerActive
        case .ghostMode:
            return .ghost
        case .ghostRead:
            return .ghostHideRead
        case .ghostOnline:
            return .ghostHideOnline
        case .ghostTyping:
            return .ghostHideTyping
        case .ghostUpload:
            return .ghostHideUpload
        case .ghostButton:
            return .ghostButton
        case .hideSponsored:
            return .hideSponsored
        case .deleteSave, .downloadStop, .autoAnswerText:
            return nil
        }
    }
}

/// What the switches show: Chitgram's own preferences, plus the Telegram settings some rows drive.
private struct ChitgramSettingsState {
    var autoDownload: MediaAutoDownloadSettings

    func isOn(_ row: ChitgramSettingsRow) -> Bool {
        let preferences = ChitgramPreferences.shared
        if let key = row.preferenceKey {
            return preferences.bool(key)
        }
        switch row {
        case .deleteSave:
            // Android stores this one as a mode number (`delete_check_key`).
            return preferences.int(.deletedCheckType) != ChitgramPreferences.DeletedCheckType.off.rawValue
        case .downloadStop:
            // Android: stopped when every network preset is off (`FenixSettings.isAutoDownloadStopped`).
            return !self.autoDownload.cellular.enabled && !self.autoDownload.wifi.enabled
        default:
            return false
        }
    }
}

private final class ChitgramSettingsArguments {
    let toggle: (ChitgramSettingsRow, Bool) -> Void
    let open: (ChitgramSettingsRow) -> Void

    init(toggle: @escaping (ChitgramSettingsRow, Bool) -> Void, open: @escaping (ChitgramSettingsRow) -> Void) {
        self.toggle = toggle
        self.open = open
    }
}

private enum ChitgramSettingsEntry: ItemListNodeEntry {
    case header(ChitgramSettingsSection, String)
    case toggle(ChitgramSettingsRow, title: String, text: String, value: Bool)
    case button(ChitgramSettingsRow, title: String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _):
            return section.rawValue
        case let .toggle(row, _, _, _), let .button(row, _):
            return row.section.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(section, _):
            return section.rawValue * 1000
        case let .toggle(row, _, _, _), let .button(row, _):
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
        case let .button(row, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.open(row)
            })
        }
    }
}

private func chitgramSettingsEntries(state: ChitgramSettingsState) -> [ChitgramSettingsEntry] {
    var entries: [ChitgramSettingsEntry] = []

    func header(_ section: ChitgramSettingsSection) {
        entries.append(.header(section, ChitgramStrings.get(section.titleId)))
    }
    func toggle(_ row: ChitgramSettingsRow) {
        let (titleId, textId) = row.titleAndTextIds
        entries.append(.toggle(row, title: ChitgramStrings.get(titleId), text: ChitgramStrings.get(textId), value: state.isOn(row)))
    }
    func button(_ row: ChitgramSettingsRow) {
        entries.append(.button(row, title: ChitgramStrings.get(row.titleAndTextIds.0)))
    }

    header(.stories)
    toggle(.storyGhost)
    toggle(.storyHide)
    toggle(.storyDownload)

    header(.messages)
    toggle(.editSave)
    toggle(.deleteSave)

    header(.download)
    toggle(.downloadStop)

    header(.autoAnswer)
    toggle(.autoAnswerActive)
    button(.autoAnswerText)

    header(.privacy)
    toggle(.ghostMode)
    // With the master switch on everything below it is hidden anyway, so the four rows show only while it is off
    // (on Android too: checked rows that change nothing when tapped read as broken).
    if !state.isOn(.ghostMode) {
        toggle(.ghostRead)
        toggle(.ghostOnline)
        toggle(.ghostTyping)
        toggle(.ghostUpload)
    }
    toggle(.ghostButton)
    toggle(.hideSponsored)

    return entries
}

/// Chitgram ▸ Sozlamalar (Android `FenixSettings`): Chitgram's switches, grouped and ordered as on Android.
public func chitgramSettingsController(context: AccountContext) -> ViewController {
    let preferences = ChitgramPreferences.shared
    var pushControllerImpl: ((ViewController) -> Void)?
    let arguments = ChitgramSettingsArguments(toggle: { row, value in
        if let key = row.preferenceKey {
            preferences.set(value, for: key)
            return
        }
        switch row {
        case .deleteSave:
            preferences.set(value ? ChitgramPreferences.DeletedCheckType.keep.rawValue : ChitgramPreferences.DeletedCheckType.off.rawValue, for: .deletedCheckType)
        case .downloadStop:
            // Telegram's own automatic download, off (or back on) for mobile data and Wi-Fi at once.
            let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.cellular.enabled = !value
                settings.wifi.enabled = !value
                return settings
            }).startStandalone()
        default:
            break
        }
    }, open: { row in
        switch row {
        case .autoAnswerText:
            pushControllerImpl?(chitgramAutoAnswerTextController(context: context))
        default:
            break
        }
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        context.sharedContext.automaticMediaDownloadSettings,
        preferences.changes
    )
    |> map { presentationData, autoDownload, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
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
            entries: chitgramSettingsEntries(state: ChitgramSettingsState(autoDownload: autoDownload)),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
