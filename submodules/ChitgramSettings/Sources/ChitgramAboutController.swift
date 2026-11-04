import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

/// The Telegram release this tree is built on (Android keeps the same constant, `AboutScreen.TELEGRAM_BASE`).
private let chitgramTelegramBase = "13.1.2"
private let chitgramSupportAdmin = "shoxxohs"
private let chitgramChannel = "chitgram_org"

private final class ChitgramAboutArguments {
    let openUrl: (String) -> Void

    init(openUrl: @escaping (String) -> Void) {
        self.openUrl = openUrl
    }
}

private enum ChitgramAboutEntry: ItemListNodeEntry {
    case appHeader(String)
    case version(title: String, value: String)
    case telegramBase(value: String)
    case supportHeader(String)
    case support(title: String, handle: String)
    case channel(title: String, handle: String)
    case companyHeader(String)
    case companyText(String)

    var section: ItemListSectionId {
        switch self {
        case .appHeader, .version, .telegramBase:
            return 0
        case .supportHeader, .support, .channel:
            return 1
        case .companyHeader, .companyText:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .appHeader:
            return 0
        case .version:
            return 1
        case .telegramBase:
            return 2
        case .supportHeader:
            return 3
        case .support:
            return 4
        case .channel:
            return 5
        case .companyHeader:
            return 6
        case .companyText:
            return 7
        }
    }

    static func <(lhs: ChitgramAboutEntry, rhs: ChitgramAboutEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAboutArguments
        switch self {
        case let .appHeader(text), let .supportHeader(text), let .companyHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .version(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .telegramBase(value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Telegram", label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .support(title, handle), let .channel(title, handle):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "@\(handle)", sectionId: self.section, style: .blocks, action: {
                arguments.openUrl("https://t.me/\(handle)")
            })
        case let .companyText(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// Chitgram ▸ Ilova haqida (Android `AboutScreen`): the version and the Telegram base, support and the channel, the
/// company.
func chitgramAboutController(context: AccountContext) -> ViewController {
    var openUrlImpl: ((String) -> Void)?
    let arguments = ChitgramAboutArguments(openUrl: { url in
        openUrlImpl?(url)
    })
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries: [ChitgramAboutEntry] = [
            .appHeader(ChitgramStrings.get(366)),
            .version(title: "Chitgram", value: version),
            .telegramBase(value: chitgramTelegramBase),
            .supportHeader(ChitgramStrings.get(356)),
            .support(title: ChitgramStrings.get(357), handle: chitgramSupportAdmin),
            .channel(title: ChitgramStrings.get(404), handle: chitgramChannel),
            .companyHeader(ChitgramStrings.get(361)),
            .companyText("\(ChitgramStrings.get(364))\n\n\(ChitgramStrings.get(367))\n\(ChitgramStrings.get(368))")
        ]
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(355)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    openUrlImpl = { [weak controller] url in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: url, forceExternal: false, presentationData: presentationData, navigationController: controller?.navigationController as? NavigationController, dismissInput: {})
    }
    return controller
}
