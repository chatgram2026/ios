import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import ChitgramCore
import ChitgramEngine

private final class ChitgramPremiumArguments {
    let selectPlan: (Int) -> Void
    let pay: () -> Void
    let restore: () -> Void

    init(selectPlan: @escaping (Int) -> Void, pay: @escaping () -> Void, restore: @escaping () -> Void) {
        self.selectPlan = selectPlan
        self.pay = pay
        self.restore = restore
    }
}

private enum ChitgramPremiumEntry: ItemListNodeEntry {
    case intro(String)
    case status(String)
    case plansHeader(String)
    case plan(index: Int, title: String, label: String, selected: Bool)
    case pay(String, enabled: Bool)
    case restore(String)
    case payFooter(String)
    case perksHeader(String)
    case perk(index: Int, title: String, text: String)

    var section: ItemListSectionId {
        switch self {
        case .intro, .status:
            return 0
        case .plansHeader, .plan, .pay, .restore, .payFooter:
            return 1
        case .perksHeader, .perk:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .intro:
            return 0
        case .status:
            return 1
        case .plansHeader:
            return 10
        case let .plan(index, _, _, _):
            return 11 + Int32(index)
        case .pay:
            return 100
        case .restore:
            return 101
        case .payFooter:
            return 102
        case .perksHeader:
            return 200
        case let .perk(index, _, _):
            return 201 + Int32(index)
        }
    }

    static func <(lhs: ChitgramPremiumEntry, rhs: ChitgramPremiumEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramPremiumArguments
        switch self {
        case let .intro(text), let .payFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .status(text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .plansHeader(text), let .perksHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .plan(index, title, label, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: label, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectPlan(index)
            })
        case let .pay(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.pay()
            })
        case let .restore(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.restore()
            })
        case let .perk(_, title, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: text, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        }
    }
}

private func chitgramPlanTitle(_ plan: ChitgramPremium.Plan) -> String {
    if plan.months == 1 {
        return ChitgramStrings.get(431)
    } else if plan.months == 12 {
        return ChitgramStrings.get(432)
    } else if plan.months % 12 == 0 {
        return ChitgramStrings.format(551, plan.months / 12)
    } else {
        return ChitgramStrings.format(550, plan.months)
    }
}

/// Settings ▸ Chitgram ▸ Chitgram Premium (Android `ChitgramPremiumScreen`): the plans from the channel's price pin, the
/// status, the payment with Stars and what Premium unlocks.
func chitgramPremiumController(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId
    let selectedPlan = ValuePromise<Int>(0, ignoreRepeated: true)
    var selectedPlanValue = 0
    let isPaying = ValuePromise<Bool>(false, ignoreRepeated: true)
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    let showResult: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
    }
    let formatDate: (Int32) -> String = { timestamp in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        return stringForMediumDate(timestamp: timestamp, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, withTime: false)
    }

    let arguments = ChitgramPremiumArguments(selectPlan: { index in
        selectedPlanValue = index
        selectedPlan.set(index)
    }, pay: {
        let plans = ChitgramPremium.plans()
        guard selectedPlanValue < plans.count else {
            return
        }
        isPaying.set(true)
        let _ = (ChitgramPremium.buy(context: context, plan: plans[selectedPlanValue])
        |> deliverOnMainQueue).startStandalone(next: { result in
            isPaying.set(false)
            switch result {
            case let .activated(until):
                showResult(ChitgramStrings.format(439, formatDate(until)))
                // Confirm against the real history once Telegram has recorded the payment.
                let _ = (Signal<Int32?, NoError>.complete() |> delay(3.0, queue: Queue.mainQueue()) |> then(ChitgramPremium.refresh(context: context))).startStandalone()
            case .notEnoughStars:
                pushImpl?(context.sharedContext.makeStarsIntroScreen(context: context))
            case let .failed(reason):
                showResult(reason == "REACTION_INVALID" ? ChitgramStrings.get(441) : ChitgramStrings.format(440, reason))
            }
        })
    }, restore: {
        showResult(ChitgramStrings.get(444))
        let _ = (ChitgramPremium.refresh(context: context)
        |> deliverOnMainQueue).startStandalone(next: { until in
            if let until, until > Int32(Date().timeIntervalSince1970) {
                showResult(ChitgramStrings.format(439, formatDate(until)))
            } else {
                showResult(ChitgramStrings.get(442))
            }
        })
    })

    // The prices may have changed since the last look.
    let _ = ChitgramPremium.refreshPlans(context: context).startStandalone()

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, selectedPlan.get(), isPaying.get(), ChitgramPreferences.shared.changes)
    |> map { presentationData, selected, paying, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let plans = ChitgramPremium.plans()
        let until = ChitgramPremium.until(accountPeerId: accountPeerId)
        let isActive = until > Int32(Date().timeIntervalSince1970)

        var entries: [ChitgramPremiumEntry] = []
        entries.append(.intro(ChitgramStrings.get(629)))
        entries.append(.status(isActive ? ChitgramStrings.format(428, formatDate(until)) : ChitgramStrings.get(429)))

        entries.append(.plansHeader(ChitgramStrings.get(427)))
        let selectedIndex = min(selected, max(0, plans.count - 1))
        for (index, plan) in plans.enumerated() {
            entries.append(.plan(index: index, title: chitgramPlanTitle(plan), label: "\(plan.stars) \u{2B50}", selected: index == selectedIndex))
        }
        if selectedIndex < plans.count {
            let price = "\(plans[selectedIndex].stars)"
            entries.append(.pay(isActive ? ChitgramStrings.format(652, price) : ChitgramStrings.format(651, price), enabled: !paying))
        }
        entries.append(.restore(ChitgramStrings.get(435)))
        entries.append(.payFooter(ChitgramStrings.get(436)))

        entries.append(.perksHeader(ChitgramStrings.get(633)))
        entries.append(.perk(index: 0, title: ChitgramStrings.get(449), text: ChitgramStrings.get(634)))
        entries.append(.perk(index: 1, title: ChitgramStrings.get(568), text: ChitgramStrings.get(635)))
        entries.append(.perk(index: 2, title: ChitgramStrings.get(637), text: ChitgramStrings.get(638)))
        entries.append(.perk(index: 3, title: ChitgramStrings.get(451), text: ChitgramStrings.get(452)))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(427)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    // Keep the status fresh when the page opens.
    let _ = ChitgramPremium.refresh(context: context).startStandalone()
    return controller
}
