import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramStringFormatting
import ItemListUI
import PresentationDataUtils
import AccountContext
import ChitgramCore

private final class ChitgramKeywordArguments {
    let toggle: (Bool) -> Void
    let updateDraft: (String) -> Void
    let addDraft: () -> Void
    let removeWord: (Int, String) -> Void

    init(toggle: @escaping (Bool) -> Void, updateDraft: @escaping (String) -> Void, addDraft: @escaping () -> Void, removeWord: @escaping (Int, String) -> Void) {
        self.toggle = toggle
        self.updateDraft = updateDraft
        self.addDraft = addDraft
        self.removeWord = removeWord
    }
}

private enum ChitgramKeywordEntry: ItemListNodeEntry {
    case enabled(Bool)
    case wordsHeader(String)
    case word(index: Int, word: String)
    case add(draft: String)
    case wordsFooter(String)
    case hitsHeader(String)
    case hit(index: Int, title: String, detail: String)
    case noHits(String)

    var section: ItemListSectionId {
        switch self {
        case .enabled:
            return 0
        case .wordsHeader, .word, .add, .wordsFooter:
            return 1
        case .hitsHeader, .hit, .noHits:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .enabled:
            return 0
        case .wordsHeader:
            return 10
        case let .word(index, _):
            return 100 + Int32(index)
        case .add:
            return 900
        case .wordsFooter:
            return 901
        case .hitsHeader:
            return 1000
        case let .hit(index, _, _):
            return 1001 + Int32(index)
        case .noHits:
            return 9999
        }
    }

    static func <(lhs: ChitgramKeywordEntry, rhs: ChitgramKeywordEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramKeywordArguments
        switch self {
        case let .enabled(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ChitgramStrings.get(568), text: ChitgramStrings.get(569), value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(value)
            })
        case let .wordsHeader(text), let .hitsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .word(index, word):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: word, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.removeWord(index, word)
            })
        case let .add(draft):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: draft, placeholder: ChitgramStrings.get(575), type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, sectionId: self.section, textUpdated: { value in
                arguments.updateDraft(value)
            }, action: {
                arguments.addDraft()
            })
        case let .wordsFooter(text), let .noHits(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .hit(_, title, detail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: detail, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        }
    }
}

/// Chitgram ▸ Sozlamalar ▸ Kalit so'z kuzatuvchisi (Android `KeywordActivity`): the switch, the words (tap one to
/// drop it, type a new one at the end), and what was found.
public func chitgramKeywordWatchController(context: AccountContext) -> ViewController {
    let keywords = ChitgramKeywords.shared
    let draft = ValuePromise<String>("", ignoreRepeated: true)
    var draftValue = ""
    var presentControllerImpl: ((ViewController) -> Void)?

    let arguments = ChitgramKeywordArguments(toggle: { value in
        keywords.isEnabled = value
    }, updateDraft: { value in
        draftValue = value
        draft.set(value)
    }, addDraft: {
        if keywords.add(draftValue) {
            draftValue = ""
            draft.set("")
        }
    }, removeWord: { index, word in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: word, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                keywords.remove(at: index)
            })
        ]))
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, draft.get(), ChitgramPreferences.shared.changes)
    |> map { presentationData, draftText, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ChitgramKeywordEntry] = []
        entries.append(.enabled(keywords.isEnabled))

        let words = keywords.words
        entries.append(.wordsHeader(ChitgramStrings.format(572, words.count, keywords.maxWords)))
        for (index, word) in words.enumerated() {
            entries.append(.word(index: index, word: word))
        }
        if words.count < keywords.maxWords {
            entries.append(.add(draft: draftText))
        }
        entries.append(.wordsFooter(ChitgramStrings.format(573, ChitgramKeywords.freeWords)))

        entries.append(.hitsHeader(ChitgramStrings.get(571)))
        let hits = keywords.hits
        if hits.isEmpty {
            entries.append(.noHits(ChitgramStrings.get(574)))
        } else {
            for (index, hit) in hits.prefix(100).enumerated() {
                let date = stringForMediumDate(timestamp: hit.date, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
                entries.append(.hit(index: index, title: hit.text, detail: "«\(hit.word)» · \(hit.chatTitle) · \(date)"))
            }
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(568)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    return controller
}
