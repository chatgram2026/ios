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

private final class ChitgramAutoAcceptArguments {
    let toggleEnabled: (Bool) -> Void
    let toggleEverywhere: (Bool) -> Void
    let selectAll: () -> Void
    let toggleChat: (EnginePeer.Id) -> Void

    init(toggleEnabled: @escaping (Bool) -> Void, toggleEverywhere: @escaping (Bool) -> Void, selectAll: @escaping () -> Void, toggleChat: @escaping (EnginePeer.Id) -> Void) {
        self.toggleEnabled = toggleEnabled
        self.toggleEverywhere = toggleEverywhere
        self.selectAll = selectAll
        self.toggleChat = toggleChat
    }
}

private enum ChitgramAutoAcceptEntry: ItemListNodeEntry {
    case enabled(title: String, text: String, value: Bool)
    case whereHeader(String)
    case everywhere(title: String, text: String, value: Bool)
    case chatsHeader(String)
    case selectAll(String)
    case chat(index: Int, peerId: EnginePeer.Id, title: String, checked: Bool)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .enabled:
            return 0
        case .whereHeader, .everywhere:
            return 1
        case .chatsHeader, .selectAll, .chat, .footer:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .enabled:
            return 0
        case .whereHeader:
            return 1
        case .everywhere:
            return 2
        case .chatsHeader:
            return 3
        case .selectAll:
            return 4
        case let .chat(index, _, _, _):
            return 10 + Int32(index)
        case .footer:
            return 100000
        }
    }

    static func <(lhs: ChitgramAutoAcceptEntry, rhs: ChitgramAutoAcceptEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoAcceptArguments
        switch self {
        case let .enabled(title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEnabled(value)
            })
        case let .whereHeader(text), let .chatsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .everywhere(title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleEverywhere(value)
            })
        case let .selectAll(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.selectAll()
            })
        case let .chat(_, peerId, title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggleChat(peerId)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// Chitgram ▸ Sozlamalar ▸ auto-accept of join requests (Android `AutoAcceptActivity`): the switch, and where it
/// applies — every chat the account can add members to, or only the ones ticked here.
func chitgramAutoAcceptController(context: AccountContext) -> ViewController {
    let account = context.account.peerId.toInt64()

    // The chats this account can approve requests in, by title: the rows of the picker.
    let candidates: Signal<[(EnginePeer.Id, String)], NoError> = combineLatest(
        context.engine.messages.chatList(group: .root, count: 5000) |> take(1),
        context.engine.messages.chatList(group: .archive, count: 2000) |> take(1),
        context.sharedContext.presentationData |> take(1)
    )
    |> map { root, archive, presentationData -> [(EnginePeer.Id, String)] in
        var result: [(EnginePeer.Id, String)] = []
        var seen = Set<EnginePeer.Id>()
        for item in root.items + archive.items {
            guard let peer = item.renderedPeer.peer, seen.insert(peer.id).inserted else {
                continue
            }
            switch peer {
            case let .channel(channel):
                if channel.participationStatus != .member || !channel.hasPermission(.inviteMembers) {
                    continue
                }
            case let .legacyGroup(group):
                if group.membership != .Member {
                    continue
                }
                switch group.role {
                case .creator, .admin:
                    break
                case .member:
                    continue
                }
            default:
                continue
            }
            result.append((peer.id, peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)))
        }
        return result.sorted(by: { $0.1.lowercased() < $1.1.lowercased() })
    }
    let candidatesPromise = Promise<[(EnginePeer.Id, String)]>()
    candidatesPromise.set(candidates)
    var currentCandidates: [EnginePeer.Id] = []

    let arguments = ChitgramAutoAcceptArguments(toggleEnabled: { value in
        ChitgramPreferences.shared.set(value, for: .autoAcceptJoin)
    }, toggleEverywhere: { value in
        ChitgramAutoAccept.setAcceptsEverywhere(account: account, value)
    }, selectAll: {
        let ids = Set(currentCandidates.map { $0.toInt64() })
        let chosen = ChitgramAutoAccept.chosen(account: account)
        ChitgramAutoAccept.setChosen(account: account, chosen.isSuperset(of: ids) ? [] : ids)
    }, toggleChat: { peerId in
        var chosen = ChitgramAutoAccept.chosen(account: account)
        let value = peerId.toInt64()
        if chosen.contains(value) {
            chosen.remove(value)
        } else {
            chosen.insert(value)
        }
        ChitgramAutoAccept.setChosen(account: account, chosen)
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, candidatesPromise.get(), ChitgramPreferences.shared.changes)
    |> map { presentationData, candidates, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        currentCandidates = candidates.map { $0.0 }
        var entries: [ChitgramAutoAcceptEntry] = []
        let enabled = ChitgramPreferences.shared.bool(.autoAcceptJoin)
        entries.append(.enabled(title: ChitgramStrings.get(263), text: ChitgramStrings.get(264), value: enabled))
        if enabled {
            let everywhere = ChitgramAutoAccept.acceptsEverywhere(account: account)
            entries.append(.whereHeader(ChitgramStrings.get(609)))
            entries.append(.everywhere(title: ChitgramStrings.get(610), text: ChitgramStrings.get(611), value: everywhere))
            if !everywhere {
                if candidates.isEmpty {
                    entries.append(.footer(ChitgramStrings.get(614)))
                } else {
                    let ids = Set(candidates.map { $0.0.toInt64() })
                    let chosen = ChitgramAutoAccept.chosen(account: account).intersection(ids)
                    entries.append(.chatsHeader(ChitgramStrings.format(612, chosen.count)))
                    entries.append(.selectAll(ChitgramStrings.get(chosen.count == candidates.count ? 376 : 375)))
                    for (index, candidate) in candidates.enumerated() {
                        entries.append(.chat(index: index, peerId: candidate.0, title: candidate.1, checked: chosen.contains(candidate.0.toInt64())))
                    }
                    entries.append(.footer(ChitgramStrings.get(613)))
                }
            }
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(263)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
