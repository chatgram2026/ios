import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import LocalizedPeerData
import ChitgramCore

private enum ChitgramChatFinderState: Equatable {
    case empty
    case searching
    case found(EnginePeer)
    case notFound
}

private final class ChitgramChatFinderArguments {
    let updateQuery: (String) -> Void
    let open: (EnginePeer) -> Void

    init(updateQuery: @escaping (String) -> Void, open: @escaping (EnginePeer) -> Void) {
        self.updateQuery = updateQuery
        self.open = open
    }
}

private enum ChitgramChatFinderEntry: ItemListNodeEntry {
    case input(String)
    case hint(String)
    case found(EnginePeer, title: String, label: String)
    case status(String)

    var section: ItemListSectionId {
        switch self {
        case .input, .hint:
            return 0
        case .found, .status:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .input:
            return 0
        case .hint:
            return 1
        case .found:
            return 2
        case .status:
            return 3
        }
    }

    static func <(lhs: ChitgramChatFinderEntry, rhs: ChitgramChatFinderEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramChatFinderArguments
        switch self {
        case let .input(text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "@"), text: text, placeholder: ChitgramStrings.get(178), type: .username, returnKeyType: .search, sectionId: self.section, textUpdated: { value in
                arguments.updateQuery(value)
            }, action: {})
        case let .hint(text), let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .found(peer, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.open(peer)
            })
        }
    }
}

/// Removes what people paste around a username: "@", "t.me/", "https://t.me/".
private func chitgramUsername(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://", "t.me/", "telegram.me/", "@"] {
        if value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
    }
    if let slash = value.firstIndex(of: "/") {
        value = String(value[..<slash])
    }
    return value
}

/// Chitgram ▸ Suhbat topuvchi (Android `ChatFinder`): type a username, see whether it exists, open it.
func chitgramChatFinderController(context: AccountContext) -> ViewController {
    let query = ValuePromise<String>("", ignoreRepeated: true)
    var navigateImpl: ((EnginePeer) -> Void)?

    let arguments = ChitgramChatFinderArguments(updateQuery: { value in
        query.set(value)
    }, open: { peer in
        navigateImpl?(peer)
    })

    let state: Signal<(String, ChitgramChatFinderState), NoError> = query.get()
    |> mapToSignal { text -> Signal<(String, ChitgramChatFinderState), NoError> in
        let name = chitgramUsername(text)
        if name.count < 4 {
            return .single((text, .empty))
        }
        // A short pause first, so typing does not send a request per letter.
        let resolved: Signal<(String, ChitgramChatFinderState), NoError> = Signal<Void, NoError>.single(Void())
        |> delay(0.4, queue: Queue.mainQueue())
        |> mapToSignal { _ -> Signal<ResolvePeerResult, NoError> in
            return context.engine.peers.resolvePeerByName(name: name, referrer: nil)
        }
        |> mapToSignal { result -> Signal<(String, ChitgramChatFinderState), NoError> in
            switch result {
            case .progress:
                return .complete()
            case let .result(peer):
                if let peer {
                    return .single((text, .found(peer)))
                } else {
                    return .single((text, .notFound))
                }
            }
        }
        return .single((text, .searching))
        |> then(resolved)
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, state)
    |> map { presentationData, textAndState -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (text, finderState) = textAndState
        var entries: [ChitgramChatFinderEntry] = []
        entries.append(.input(text))
        entries.append(.hint(ChitgramStrings.get(124)))
        switch finderState {
        case .empty, .searching:
            break
        case let .found(peer):
            let username = peer.addressName.flatMap { "@\($0)" } ?? ""
            entries.append(.found(peer, title: peer.compactDisplayTitle, label: "\(username) · \(ChitgramStrings.get(180))"))
        case .notFound:
            entries.append(.status(ChitgramStrings.get(179)))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(123)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    navigateImpl = { [weak controller] peer in
        guard let navigationController = controller?.navigationController as? NavigationController else {
            return
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
    }
    return controller
}
