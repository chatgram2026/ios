import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import ChitgramCore

private final class ChitgramTabBarArguments {
    let toggle: (Int, Bool) -> Void
    let reorder: () -> Void
    let setStart: (Int) -> Void
    let setExtra: (Int) -> Void
    let setLabels: (Int) -> Void
    let reset: () -> Void

    init(toggle: @escaping (Int, Bool) -> Void, reorder: @escaping () -> Void, setStart: @escaping (Int) -> Void, setExtra: @escaping (Int) -> Void, setLabels: @escaping (Int) -> Void, reset: @escaping () -> Void) {
        self.toggle = toggle
        self.reorder = reorder
        self.setStart = setStart
        self.setExtra = setExtra
        self.setLabels = setLabels
        self.reset = reset
    }
}

private enum ChitgramTabBarEntry: ItemListNodeEntry {
    case tabsHeader(String)
    case tab(index: Int, tab: Int, title: String, visible: Bool, enabled: Bool)
    case order(title: String, value: String)
    case tabsFooter(String)
    case extraHeader(String)
    case extra(value: Int, title: String, selected: Bool)
    case extraFooter(String)
    case labelsHeader(String)
    case labels(value: Int, title: String, selected: Bool)
    case startHeader(String)
    case start(index: Int, tab: Int, title: String, selected: Bool)
    case reset(String)

    var section: ItemListSectionId {
        switch self {
        case .tabsHeader, .tab, .order, .tabsFooter:
            return 0
        case .extraHeader, .extra, .extraFooter:
            return 1
        case .labelsHeader, .labels:
            return 2
        case .startHeader, .start:
            return 3
        case .reset:
            return 4
        }
    }

    var stableId: Int32 {
        switch self {
        case .tabsHeader:
            return 0
        case let .tab(index, _, _, _, _):
            return 10 + Int32(index)
        case .order:
            return 50
        case .tabsFooter:
            return 51
        case .extraHeader:
            return 60
        case let .extra(value, _, _):
            return 61 + Int32(value)
        case .extraFooter:
            return 69
        case .labelsHeader:
            return 70
        case let .labels(value, _, _):
            return 71 + Int32(value)
        case .startHeader:
            return 100
        case let .start(index, _, _, _):
            return 110 + Int32(index)
        case .reset:
            return 200
        }
    }

    static func <(lhs: ChitgramTabBarEntry, rhs: ChitgramTabBarEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramTabBarArguments
        switch self {
        case let .tabsHeader(text), let .startHeader(text), let .extraHeader(text), let .labelsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .tab(_, tab, title, visible, enabled):
            // Refusals (Chats, or fewer than two tabs) leave the switch where it was.
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: visible, enableInteractiveChanges: false, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(tab, value)
            })
        case let .order(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.reorder()
            })
        case let .extra(value, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setExtra(value)
            })
        case let .labels(value, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setLabels(value)
            })
        case let .extraFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .tabsFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .start(_, tab, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setStart(tab)
            })
        case let .reset(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.reset()
            })
        }
    }
}

private func chitgramTabTitle(_ tab: Int, strings: PresentationStrings) -> String {
    switch tab {
    case ChitgramTabs.contacts:
        return strings.Contacts_Title
    case ChitgramTabs.calls:
        return strings.Calls_TabTitle
    case ChitgramTabs.settings:
        return strings.Settings_Title
    default:
        return strings.DialogList_Title
    }
}

/// Settings ▸ Chitgram ▸ Sozlamalar ▸ Tab bar (Android `TabBarSettings`): which tabs show, their order and the tab
/// the app opens on. The bar follows each change at once.
func chitgramTabBarController(context: AccountContext) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    let toast: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }

    let arguments = ChitgramTabBarArguments(toggle: { tab, value in
        if tab == ChitgramTabs.chats {
            toast(ChitgramStrings.get(424))
        } else if !ChitgramTabs.setVisible(tab, value) {
            toast(ChitgramStrings.get(425))
        }
    }, reorder: {
        // Each choice moves that tab to the front, so any order is a few taps away.
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: ChitgramStrings.get(408), parseMarkdown: false)]
        let order = ChitgramTabs.order()
        for tab in order.dropFirst() {
            items.append(ActionSheetButtonItem(title: "\u{2B06}\u{FE0E} " + chitgramTabTitle(tab, strings: presentationData.strings), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                var updated = ChitgramTabs.order().filter { $0 != tab }
                updated.insert(tab, at: 0)
                ChitgramTabs.setOrder(updated)
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        presentImpl?(actionSheet)
    }, setStart: { tab in
        ChitgramTabs.setStartTab(tab)
    }, setExtra: { value in
        ChitgramTabs.setExtraButton(value)
    }, setLabels: { value in
        ChitgramTabs.setLabelsMode(value)
    }, reset: {
        ChitgramTabs.reset()
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let order = ChitgramTabs.order()
        var entries: [ChitgramTabBarEntry] = []
        entries.append(.tabsHeader(ChitgramStrings.get(408)))
        for (index, tab) in order.enumerated() {
            entries.append(.tab(index: index, tab: tab, title: chitgramTabTitle(tab, strings: strings), visible: ChitgramTabs.isVisible(tab), enabled: tab != ChitgramTabs.chats))
        }
        let visibleOrder = order.filter { ChitgramTabs.isVisible($0) }.map { chitgramTabTitle($0, strings: strings) }.joined(separator: " · ")
        entries.append(.order(title: ChitgramStrings.get(406), value: visibleOrder))
        entries.append(.tabsFooter(ChitgramStrings.get(407)))

        let extra = ChitgramTabs.extraButton()
        entries.append(.extraHeader(ChitgramStrings.get(410)))
        entries.append(.extra(value: ChitgramTabs.extraNone, title: ChitgramStrings.get(411), selected: extra == ChitgramTabs.extraNone))
        entries.append(.extra(value: ChitgramTabs.extraSearch, title: ChitgramStrings.get(412), selected: extra == ChitgramTabs.extraSearch))
        entries.append(.extra(value: ChitgramTabs.extraNewMessage, title: ChitgramStrings.get(413), selected: extra == ChitgramTabs.extraNewMessage))
        entries.append(.extra(value: ChitgramTabs.extraSaved, title: ChitgramStrings.get(414), selected: extra == ChitgramTabs.extraSaved))
        entries.append(.extraFooter(ChitgramStrings.get(426)))

        let labels = ChitgramTabs.labelsMode()
        entries.append(.labelsHeader(ChitgramStrings.get(415)))
        entries.append(.labels(value: ChitgramTabs.labelsAll, title: ChitgramStrings.get(416), selected: labels == ChitgramTabs.labelsAll))
        entries.append(.labels(value: ChitgramTabs.labelsSelected, title: ChitgramStrings.get(417), selected: labels == ChitgramTabs.labelsSelected))
        entries.append(.labels(value: ChitgramTabs.labelsNone, title: ChitgramStrings.get(418), selected: labels == ChitgramTabs.labelsNone))

        entries.append(.startHeader(ChitgramStrings.get(422)))
        let start = ChitgramTabs.startTab()
        for (index, tab) in order.filter({ ChitgramTabs.isVisible($0) }).enumerated() {
            entries.append(.start(index: index, tab: tab, title: chitgramTabTitle(tab, strings: strings), selected: tab == start))
        }
        entries.append(.reset(ChitgramStrings.get(423)))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(406)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
