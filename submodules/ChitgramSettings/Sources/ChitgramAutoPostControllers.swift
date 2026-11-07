import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI
import LocalizedPeerData
import ChitgramCore
import ChitgramEngine

// MARK: Words (Android `AutoPostActivity` companion)

/// "10 min", "2 h", "1 h 30 min", "1 day".
func chitgramAutoPostInterval(_ minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    if minutes == 24 * 60 {
        return ChitgramStrings.get(486)
    } else if hours > 0 && rest > 0 {
        return ChitgramStrings.format(540, hours, rest)
    } else if hours > 0 {
        return ChitgramStrings.format(485, hours)
    } else {
        return ChitgramStrings.format(484, rest)
    }
}

/// Active hours, or "all day" when start and end are the same hour.
private func chitgramAutoPostHours(_ task: ChitgramAutoPost.Task) -> String {
    if task.startHour == task.endHour {
        return ChitgramStrings.get(526)
    }
    return ChitgramStrings.format(492, task.startHour, task.endHour)
}

private let chitgramAutoPostDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "dd.MM HH:mm"
    return formatter
}()

private func chitgramAutoPostTime(_ timestamp: Int32) -> String {
    return chitgramAutoPostDateFormatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

/// The stored error code in plain words, or nil when there is nothing to tell.
private func chitgramAutoPostDescribeError(_ code: String?) -> String? {
    guard let code, !code.isEmpty else {
        return nil
    }
    let kind: String
    let argument: String
    if let separator = code.firstIndex(of: ":") {
        kind = String(code[code.startIndex ..< separator])
        argument = String(code[code.index(after: separator)...])
    } else {
        kind = code
        argument = ""
    }
    switch kind {
    case ChitgramAutoPost.errFlood:
        let until = Int32(argument) ?? 0
        if until <= Int32(Date().timeIntervalSince1970) {
            return nil
        }
        return ChitgramStrings.format(531, chitgramAutoPostTime(until))
    case ChitgramAutoPost.errSpam:
        return ChitgramStrings.get(532)
    case ChitgramAutoPost.errRemoved:
        return ChitgramStrings.format(533, argument)
    case ChitgramAutoPost.errSourceGone:
        return ChitgramStrings.get(534)
    case ChitgramAutoPost.errOther:
        return ChitgramStrings.format(535, argument)
    default:
        return ChitgramStrings.format(535, code)
    }
}

private func chitgramAutoPostSummary(context: AccountContext, task: ChitgramAutoPost.Task, running: Bool) -> String {
    var line: String
    if task.scheduleMode == ChitgramAutoPost.scheduleTimes {
        line = ChitgramStrings.format(542, task.targets.count, task.times.count)
    } else {
        line = ChitgramStrings.format(478, task.targets.count, chitgramAutoPostInterval(task.intervalMinutes))
    }
    // What it has actually done matters more than what it is configured to do.
    if task.sentCount > 0 {
        line += " · " + ChitgramStrings.format(514, task.sentCount)
    }
    let problem = !running ? ChitgramStrings.get(545) : chitgramAutoPostDescribeError(task.lastError)
    if let problem {
        return line + "\n\u{26A0}\u{FE0F} " + problem
    }
    if !task.enabled {
        return line + " · " + ChitgramStrings.get(480)
    }
    let next = ChitgramAutoPost.nextSend(context: context, task: task)
    if next > 0 {
        return line + " · " + ChitgramStrings.format(479, chitgramAutoPostTime(next))
    }
    return line
}

/// "Limit reached — get Premium", with the way to Premium on the toast.
private func chitgramAutoPostLimitToast(context: AccountContext, text: String, present: (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: ChitgramStrings.get(520)), elevatedLayout: false, action: { action in
        if case .undo = action {
            push(chitgramPremiumController(context: context))
        }
        return false
    }))
}

private func chitgramAutoPostToast(context: AccountContext, text: String, present: (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
}

/// Holds a picker's choice and hands it over when the picker closes (Android: `onFragmentDestroy`), so leaving a
/// picker after several taps is one edit, not one per tap.
private final class ChitgramAutoPostPickerSession<T> {
    var value: T
    private let completion: (T) -> Void

    init(value: T, completion: @escaping (T) -> Void) {
        self.value = value
        self.completion = completion
    }

    deinit {
        let value = self.value
        let completion = self.completion
        Queue.mainQueue().justDispatch {
            completion(value)
        }
    }
}

// MARK: Task list (Android `AutoPostActivity`)

private final class ChitgramAutoPostListArguments {
    let openTask: (Int64) -> Void
    let newTask: () -> Void
    let openPremium: () -> Void

    init(openTask: @escaping (Int64) -> Void, newTask: @escaping () -> Void, openPremium: @escaping () -> Void) {
        self.openTask = openTask
        self.newTask = newTask
        self.openPremium = openPremium
    }
}

private enum ChitgramAutoPostListEntry: ItemListNodeEntry {
    case header(String)
    case task(index: Int, id: Int64, title: String, summary: String)
    case newTask(String)
    case footer(String)
    case premium(String)
    case premiumFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .header, .task, .newTask, .footer:
            return 0
        case .premium, .premiumFooter:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case let .task(index, _, _, _):
            return 10 + Int32(index)
        case .newTask:
            return 1000
        case .footer:
            return 1001
        case .premium:
            return 2000
        case .premiumFooter:
            return 2001
        }
    }

    static func <(lhs: ChitgramAutoPostListEntry, rhs: ChitgramAutoPostListEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoPostListArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .task(_, id, title, summary):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: summary, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                arguments.openTask(id)
            })
        case let .newTask(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.newTask()
            })
        case let .footer(text), let .premiumFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .premium(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.openPremium()
            })
        }
    }
}

/// Auto messenger task list. Reached from the chat list menu, the message menu and the Premium page.
public func chitgramAutoPostController(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId
    // Android AutoPostActivity: the tasks other devices of the account keep come in when the list opens.
    ChitgramAutoPostCloud.pull(context: context)
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?

    let arguments = ChitgramAutoPostListArguments(openTask: { id in
        pushImpl?(chitgramAutoPostEditController(context: context, taskId: id))
    }, newTask: {
        let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)
        if ChitgramAutoPost.tasks(accountPeerId: accountPeerId).count >= ChitgramAutoPost.maxTasks(isPremium: isPremium) {
            chitgramAutoPostLimitToast(context: context, text: ChitgramStrings.get(489), present: { c in
                presentImpl?(c)
            }, push: { c in
                pushImpl?(c)
            })
            return
        }
        let task = ChitgramAutoPost.newTask(isPremium: isPremium)
        ChitgramAutoPost.put(accountPeerId: accountPeerId, task: task)
        pushImpl?(chitgramAutoPostEditController(context: context, taskId: task.id))
    }, openPremium: {
        pushImpl?(chitgramPremiumController(context: context))
    })

    ChitgramAutoPost.syncAll(context: context)
    // A fresh install may not know yet that this account has Premium; the limits shown depend on it.
    let _ = ChitgramPremium.refresh(context: context).startStandalone()

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ChitgramPreferences.shared.changes)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)
        let tasks = ChitgramAutoPost.tasks(accountPeerId: accountPeerId)
        let running = ChitgramAutoPost.runningIds(tasks: tasks, isPremium: isPremium)

        var entries: [ChitgramAutoPostListEntry] = []
        entries.append(.header(ChitgramStrings.get(464)))
        for (index, task) in tasks.enumerated() {
            entries.append(.task(index: index, id: task.id, title: task.title, summary: chitgramAutoPostSummary(context: context, task: task, running: running.contains(task.id))))
        }
        entries.append(.newTask(ChitgramStrings.get(465)))
        entries.append(.footer(tasks.isEmpty ? ChitgramStrings.get(494) : ChitgramStrings.get(481)))
        if !isPremium {
            // The free plan in plain numbers, and what Premium adds, right where the limits are felt.
            entries.append(.premium(ChitgramStrings.get(547)))
            entries.append(.premiumFooter(ChitgramStrings.format(482, ChitgramAutoPost.freeTasks, ChitgramAutoPost.freeTargets, ChitgramAutoPost.freeMinInterval)))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(463)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}

/// The message menu's "Add to auto messenger": a new task with this message as its template, or the task list
/// when the plan's task limit is reached (it offers Premium there).
public func chitgramAutoPostController(context: AccountContext, messageId: EngineMessage.Id) -> ViewController {
    let accountPeerId = context.account.peerId
    let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)
    if ChitgramAutoPost.tasks(accountPeerId: accountPeerId).count >= ChitgramAutoPost.maxTasks(isPremium: isPremium) {
        return chitgramAutoPostController(context: context)
    }
    var task = ChitgramAutoPost.newTask(isPremium: isPremium)
    task.sourceDialogId = messageId.peerId.toInt64()
    task.sourceIds = [messageId.id]
    task.enabled = false
    // Stored first: the editor works on the stored task by id, never on a detached copy.
    ChitgramAutoPost.put(accountPeerId: accountPeerId, task: task)
    return chitgramAutoPostEditController(context: context, taskId: task.id)
}

// MARK: Task editor (Android `AutoPostEditActivity`)

/// Lives as long as the editor. When it goes, an edited task gets a fresh queue (one rebuild for the whole visit,
/// not one per tap), and a new task left empty is dropped.
private final class ChitgramAutoPostEditSession {
    let context: AccountContext
    let taskId: Int64
    var dirty = false

    init(context: AccountContext, taskId: Int64) {
        self.context = context
        self.taskId = taskId
    }

    deinit {
        let context = self.context
        let taskId = self.taskId
        let dirty = self.dirty
        Queue.mainQueue().justDispatch {
            if dirty {
                ChitgramAutoPost.reschedule(context: context, id: taskId)
            }
            ChitgramAutoPost.dropIfEmpty(accountPeerId: context.account.peerId, id: taskId)
        }
    }
}

private final class ChitgramAutoPostEditArguments {
    let session: ChitgramAutoPostEditSession
    let selectMode: (Int) -> Void
    let chooseSaved: () -> Void
    let editText: (Int) -> Void
    let addTargets: () -> Void
    let selectScheduleMode: (Int) -> Void
    let removeTime: (Int) -> Void
    let addTime: () -> Void
    let chooseInterval: () -> Void
    let chooseHours: () -> Void
    let toggleEnabled: () -> Void
    let delete: () -> Void

    init(session: ChitgramAutoPostEditSession, selectMode: @escaping (Int) -> Void, chooseSaved: @escaping () -> Void, editText: @escaping (Int) -> Void, addTargets: @escaping () -> Void, selectScheduleMode: @escaping (Int) -> Void, removeTime: @escaping (Int) -> Void, addTime: @escaping () -> Void, chooseInterval: @escaping () -> Void, chooseHours: @escaping () -> Void, toggleEnabled: @escaping () -> Void, delete: @escaping () -> Void) {
        self.session = session
        self.selectMode = selectMode
        self.chooseSaved = chooseSaved
        self.editText = editText
        self.addTargets = addTargets
        self.selectScheduleMode = selectScheduleMode
        self.removeTime = removeTime
        self.addTime = addTime
        self.chooseInterval = chooseInterval
        self.chooseHours = chooseHours
        self.toggleEnabled = toggleEnabled
        self.delete = delete
    }
}

private enum ChitgramAutoPostEditEntry: ItemListNodeEntry {
    case error(String)
    case statsHeader(String)
    case stat(index: Int, title: String, value: String)
    case messageHeader(String)
    case source(title: String, label: String)
    case mode(index: Int, title: String, selected: Bool)
    case chooseSaved(String)
    case text(index: Int, text: String)
    case addText(String)
    case messageFooter(String)
    case targetsHeader(String)
    case target(index: Int, title: String)
    case addTargets(String)
    case targetsFooter(String)
    case scheduleHeader(String)
    case scheduleMode(index: Int, title: String, selected: Bool)
    case time(index: Int, title: String)
    case addTime(String)
    case interval(title: String, value: String)
    case hours(title: String, value: String)
    case enabled(title: String, value: Bool)
    case scheduleFooter(String)
    case delete(String)

    var section: ItemListSectionId {
        switch self {
        case .error:
            return 0
        case .statsHeader, .stat:
            return 1
        case .messageHeader, .source, .mode, .chooseSaved, .text, .addText, .messageFooter:
            return 2
        case .targetsHeader, .target, .addTargets, .targetsFooter:
            return 3
        case .scheduleHeader, .scheduleMode, .time, .addTime, .interval, .hours, .enabled, .scheduleFooter:
            return 4
        case .delete:
            return 5
        }
    }

    var stableId: Int32 {
        switch self {
        case .error:
            return 0
        case .statsHeader:
            return 10
        case let .stat(index, _, _):
            return 11 + Int32(index)
        case .messageHeader:
            return 100
        case .source:
            return 101
        case let .mode(index, _, _):
            return 102 + Int32(index)
        case .chooseSaved:
            return 110
        case let .text(index, _):
            return 120 + Int32(index)
        case .addText:
            return 140
        case .messageFooter:
            return 141
        case .targetsHeader:
            return 200
        case let .target(index, _):
            return 1000 + Int32(index)
        case .addTargets:
            return 1200
        case .targetsFooter:
            return 1201
        case .scheduleHeader:
            return 1300
        case let .scheduleMode(index, _, _):
            return 1301 + Int32(index)
        case let .time(index, _):
            return 1310 + Int32(index)
        case .addTime:
            return 1330
        case .interval:
            return 1331
        case .hours:
            return 1332
        case .enabled:
            return 1333
        case .scheduleFooter:
            return 1334
        case .delete:
            return 1400
        }
    }

    static func <(lhs: ChitgramAutoPostEditEntry, rhs: ChitgramAutoPostEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoPostEditArguments
        switch self {
        case let .error(text), let .messageFooter(text), let .targetsFooter(text), let .scheduleFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .statsHeader(text), let .messageHeader(text), let .targetsHeader(text), let .scheduleHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .stat(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .source(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.chooseSaved()
            })
        case let .mode(index, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectMode(index)
            })
        case let .chooseSaved(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.chooseSaved()
            })
        case let .text(index, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.editText(index)
            })
        case let .addText(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.editText(-1)
            })
        case let .target(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.addTargets()
            })
        case let .addTargets(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addTargets()
            })
        case let .scheduleMode(index, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectScheduleMode(index)
            })
        case let .time(index, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.removeTime(index)
            })
        case let .addTime(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addTime()
            })
        case let .interval(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.chooseInterval()
            })
        case let .hours(title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.chooseHours()
            })
        case let .enabled(title, value):
            // The switch can be refused (no message or chat yet), so it follows the stored state, not the tap.
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enableInteractiveChanges: false, sectionId: self.section, style: .blocks, updated: { _ in
                arguments.toggleEnabled()
            })
        case let .delete(text):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: text, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.delete()
            })
        }
    }
}

/// Create or edit one task: what to send, where and when. The screen holds only the task's id; every edit is
/// applied to the stored task and every redraw reads it back.
public func chitgramAutoPostEditController(context: AccountContext, taskId: Int64) -> ViewController {
    let accountPeerId = context.account.peerId
    let session = ChitgramAutoPostEditSession(context: context, taskId: taskId)
    // Redraws the screen when an action was refused, so a switch that did not change springs back.
    let refresh = ValuePromise<Int>(0, ignoreRepeated: true)
    var refreshValue = 0
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?

    let currentTask: () -> ChitgramAutoPost.Task? = {
        return ChitgramAutoPost.task(accountPeerId: accountPeerId, id: taskId)
    }
    let toast: (String) -> Void = { text in
        chitgramAutoPostToast(context: context, text: text, present: { c in
            presentImpl?(c)
        })
    }
    let premiumToast: (String) -> Void = { text in
        chitgramAutoPostLimitToast(context: context, text: text, present: { c in
            presentImpl?(c)
        }, push: { c in
            pushImpl?(c)
        })
    }

    // Applies an edit to the stored task. The moment the task gets both a message and a chat it starts: choosing
    // both is the instruction to start, and the first message goes out right away. Not for the on/off switch.
    let changed: (Bool, (inout ChitgramAutoPost.Task) -> Void) -> Void = { startIfReady, f in
        guard let task = currentTask() else {
            return
        }
        let wasReady = ChitgramAutoPost.isReady(task)
        guard let updated = ChitgramAutoPost.edit(accountPeerId: accountPeerId, id: taskId, f) else {
            return
        }
        session.dirty = true
        if startIfReady && !wasReady && ChitgramAutoPost.isReady(updated) {
            ChitgramAutoPost.edit(accountPeerId: accountPeerId, id: taskId, { task in
                task.enabled = true
            })
            ChitgramAutoPost.reschedule(context: context, id: taskId)
            session.dirty = false
            toast(ChitgramStrings.get(513))
        }
    }

    let addTime: () -> Void = {
        guard let task = currentTask() else {
            return
        }
        if task.times.count >= ChitgramAutoPost.maxTimes {
            toast(ChitgramStrings.format(541, ChitgramAutoPost.maxTimes))
            return
        }
        // Suggest the first full hour from 09:00 that is not taken yet.
        let suggestion = (9 ... 23).map { $0 * 60 }.first(where: { !task.times.contains($0) }) ?? 12 * 60
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        chitgramPresentTimePicker(presentationData: presentationData, title: ChitgramStrings.get(525), currentMinutes: suggestion, present: { c in
            presentImpl?(c)
        }, picked: { minute in
            guard let task = currentTask() else {
                return
            }
            // On the free plan fixed times must also be the minimum interval apart, or they would sidestep it.
            let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)
            let gap = isPremium ? 0 : ChitgramAutoPost.minInterval(isPremium: false)
            let tooClose = task.times.contains(where: { other in
                let distance = abs(other - minute)
                if distance == 0 {
                    return false
                }
                return min(distance, 24 * 60 - distance) < gap
            })
            if tooClose {
                premiumToast(ChitgramStrings.format(546, gap))
            } else if !task.times.contains(minute) {
                changed(true, { task in
                    task.times.append(minute)
                    task.times.sort()
                })
            }
        })
    }

    let arguments = ChitgramAutoPostEditArguments(session: session, selectMode: { index in
        let mode = index == 0 ? ChitgramAutoPost.modeCopy : ChitgramAutoPost.modeForward
        // Tapping the option already chosen is not an edit (it would needlessly rebuild the queue).
        if currentTask()?.mode != mode {
            changed(true, { task in
                task.mode = mode
            })
        }
    }, chooseSaved: {
        guard let task = currentTask() else {
            return
        }
        let selected = task.sourceDialogId == accountPeerId.toInt64() ? task.sourceIds : []
        pushImpl?(chitgramAutoPostSavedController(context: context, selected: selected, completion: { picked in
            guard let task = currentTask() else {
                return
            }
            if picked != task.sourceIds || (!picked.isEmpty && task.sourceDialogId != accountPeerId.toInt64()) {
                changed(true, { task in
                    task.sourceIds = picked
                    task.sourceDialogId = accountPeerId.toInt64()
                    if !picked.isEmpty {
                        task.texts = []
                    }
                    task.variantIndex = 0
                })
            }
        }))
    }, editText: { index in
        let texts = currentTask()?.texts ?? []
        let current = index >= 0 && index < texts.count ? texts[index] : ""
        pushImpl?(chitgramAutoPostTextController(context: context, text: current, completion: { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let texts = currentTask()?.texts ?? []
            let previous: String? = index >= 0 && index < texts.count ? texts[index] : nil
            if value == previous || (value.isEmpty && previous == nil) {
                return
            }
            changed(true, { task in
                if value.isEmpty {
                    if index >= 0 && index < task.texts.count {
                        task.texts.remove(at: index)
                    }
                } else if index >= 0 && index < task.texts.count {
                    task.texts[index] = value
                } else {
                    task.texts.append(value)
                }
            })
        }))
    }, addTargets: {
        guard let task = currentTask() else {
            return
        }
        let limit = ChitgramAutoPost.maxTargets(isPremium: ChitgramAutoPost.isPremium(accountPeerId: accountPeerId))
        pushImpl?(chitgramAutoPostTargetsController(context: context, selected: task.targets, limit: limit, completion: { selected in
            // Leaving the picker untouched is not an edit.
            if Set(selected) != Set(currentTask()?.targets ?? []) {
                changed(true, { task in
                    task.targets = selected
                })
            }
        }))
    }, selectScheduleMode: { index in
        let mode = index == 0 ? ChitgramAutoPost.scheduleInterval : ChitgramAutoPost.scheduleTimes
        if currentTask()?.scheduleMode != mode {
            changed(true, { task in
                task.scheduleMode = mode
            })
        }
        if mode == ChitgramAutoPost.scheduleTimes && (currentTask()?.times.isEmpty ?? false) {
            addTime()
        }
    }, removeTime: { index in
        let times = (currentTask()?.times ?? []).sorted()
        guard index >= 0 && index < times.count else {
            return
        }
        let minute = times[index]
        changed(true, { task in
            task.times.removeAll(where: { $0 == minute })
        })
    }, addTime: {
        addTime()
    }, chooseInterval: {
        guard let task = currentTask() else {
            return
        }
        let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        chitgramPresentIntervalPicker(presentationData: presentationData, currentMinutes: task.intervalMinutes, minMinutes: ChitgramAutoPost.minInterval(isPremium: isPremium), isPremium: isPremium, present: { c in
            presentImpl?(c)
        }, openPremium: {
            pushImpl?(chitgramPremiumController(context: context))
        }, picked: { minutes in
            if minutes != currentTask()?.intervalMinutes {
                changed(true, { task in
                    task.intervalMinutes = minutes
                })
            }
        })
    }, chooseHours: {
        guard let task = currentTask() else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        chitgramPresentHoursPicker(presentationData: presentationData, startHour: task.startHour, endHour: task.endHour, present: { c in
            presentImpl?(c)
        }, picked: { start, end in
            guard let task = currentTask() else {
                return
            }
            if start != task.startHour || end != task.endHour {
                changed(true, { task in
                    task.startHour = start
                    task.endHour = end
                })
            }
        })
    }, toggleEnabled: {
        guard let task = currentTask() else {
            return
        }
        if !task.enabled && !ChitgramAutoPost.isReady(task) {
            let hasMessage = !task.sourceIds.isEmpty || !task.texts.isEmpty
            let code = task.scheduleMode == ChitgramAutoPost.scheduleTimes && task.times.isEmpty && hasMessage ? 538 : 490
            toast(ChitgramStrings.get(code))
            refreshValue += 1
            refresh.set(refreshValue)
            return
        }
        changed(false, { task in
            task.enabled = !task.enabled
        })
    }, delete: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(textAlertController(context: context, title: nil, text: ChitgramStrings.get(477), actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: presentationData.strings.Common_Delete, action: {
                session.dirty = false
                ChitgramAutoPost.remove(context: context, id: taskId)
                popImpl?()
            })
        ]))
    })

    ChitgramAutoPost.syncAll(context: context)

    let taskAndPeers = ChitgramPreferences.shared.changes
    |> mapToSignal { _ -> Signal<(ChitgramAutoPost.Task?, [EnginePeer.Id: EnginePeer?]), NoError> in
        let task = currentTask()
        let peerIds = (task?.targets ?? []).map { EnginePeer.Id($0) }
        return context.engine.data.get(EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { peers -> (ChitgramAutoPost.Task?, [EnginePeer.Id: EnginePeer?]) in
            return (task, peers)
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, taskAndPeers, refresh.get())
    |> map { presentationData, taskAndPeers, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (taskValue, peers) = taskAndPeers
        var entries: [ChitgramAutoPostEditEntry] = []
        if let task = taskValue {
            let isPremium = ChitgramAutoPost.isPremium(accountPeerId: accountPeerId)

            // What went wrong, in words.
            if let error = chitgramAutoPostDescribeError(task.lastError) {
                entries.append(.error("\u{26A0}\u{FE0F} " + error))
            }

            // Statistics, once the task has a history.
            let queued = ChitgramAutoPost.queued(task)
            if task.sentCount > 0 || queued > 0 {
                entries.append(.statsHeader(ChitgramStrings.get(461)))
                var stats: [(String, String)] = []
                stats.append((ChitgramStrings.get(462), "\(task.sentCount)"))
                stats.append((ChitgramStrings.get(508), "\(queued)"))
                stats.append((ChitgramStrings.get(509), task.lastSentAt > 0 ? chitgramAutoPostTime(task.lastSentAt) : ChitgramStrings.get(512)))
                let next = ChitgramAutoPost.nextSend(context: context, task: task)
                stats.append((ChitgramStrings.get(510), next > 0 ? chitgramAutoPostTime(next) : ChitgramStrings.get(task.enabled ? 512 : 480)))
                let ends = ChitgramAutoPost.queueEnds(context: context, task: task)
                if ends > 0 {
                    stats.append((ChitgramStrings.get(536), chitgramAutoPostTime(ends)))
                }
                if task.createdAt > 0 {
                    stats.append((ChitgramStrings.get(511), chitgramAutoPostTime(task.createdAt)))
                }
                stats.append((ChitgramStrings.get(529), ChitgramStrings.get(528)))
                for (index, stat) in stats.enumerated() {
                    entries.append(.stat(index: index, title: stat.0, value: stat.1))
                }
            }

            // Message.
            entries.append(.messageHeader(ChitgramStrings.get(466)))
            if !task.sourceIds.isEmpty {
                let title = task.sourceDialogId == accountPeerId.toInt64() ? ChitgramStrings.get(495) : ChitgramStrings.get(467)
                entries.append(.source(title: title, label: ChitgramStrings.format(507, task.sourceIds.count)))
                // How it is delivered is chosen right here, next to the message itself.
                entries.append(.mode(index: 0, title: ChitgramStrings.get(468), selected: task.mode == ChitgramAutoPost.modeCopy))
                entries.append(.mode(index: 1, title: ChitgramStrings.get(469), selected: task.mode == ChitgramAutoPost.modeForward))
            } else {
                entries.append(.chooseSaved(ChitgramStrings.get(505)))
                for (index, text) in task.texts.enumerated() {
                    entries.append(.text(index: index, text: String(text.prefix(60))))
                }
                if task.texts.count < ChitgramAutoPost.maxTexts {
                    entries.append(.addText(ChitgramStrings.get(task.texts.isEmpty ? 506 : 470)))
                }
            }
            entries.append(.messageFooter(ChitgramStrings.get(496)))

            // Where.
            let limit = ChitgramAutoPost.maxTargets(isPremium: isPremium)
            entries.append(.targetsHeader(ChitgramStrings.get(471)))
            for (index, target) in task.targets.enumerated() {
                let peerId = EnginePeer.Id(target)
                let title: String
                if peerId == accountPeerId {
                    title = presentationData.strings.DialogList_SavedMessages
                } else if let peer = peers[peerId] ?? nil {
                    title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                } else {
                    title = "\(target)"
                }
                entries.append(.target(index: index, title: title))
            }
            entries.append(.addTargets(ChitgramStrings.get(472)))
            if task.targets.count > limit {
                // Chats kept from a Premium period: say plainly which ones still get the message.
                entries.append(.targetsFooter(ChitgramStrings.format(544, limit)))
            }

            // When.
            entries.append(.scheduleHeader(ChitgramStrings.get(473)))
            entries.append(.scheduleMode(index: 0, title: ChitgramStrings.get(522), selected: task.scheduleMode == ChitgramAutoPost.scheduleInterval))
            entries.append(.scheduleMode(index: 1, title: ChitgramStrings.get(523), selected: task.scheduleMode == ChitgramAutoPost.scheduleTimes))
            if task.scheduleMode == ChitgramAutoPost.scheduleTimes {
                for (index, minute) in task.times.sorted().enumerated() {
                    entries.append(.time(index: index, title: String(format: "%02d:%02d", minute / 60, minute % 60)))
                }
                if task.times.count < ChitgramAutoPost.maxTimes {
                    entries.append(.addTime(ChitgramStrings.get(524)))
                }
            } else {
                entries.append(.interval(title: ChitgramStrings.get(474), value: chitgramAutoPostInterval(task.intervalMinutes)))
                entries.append(.hours(title: ChitgramStrings.get(475), value: chitgramAutoPostHours(task)))
            }
            entries.append(.enabled(title: ChitgramStrings.get(476), value: task.enabled))
            if task.scheduleMode == ChitgramAutoPost.scheduleTimes && !task.times.isEmpty {
                entries.append(.scheduleFooter(ChitgramStrings.get(539) + "\n\n" + ChitgramStrings.get(481)))
            } else {
                entries.append(.scheduleFooter(ChitgramStrings.get(481)))
            }

            entries.append(.delete(ChitgramStrings.get(477)))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(463)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}

// MARK: Typed message variant

private final class ChitgramAutoPostTextArguments {
    let updateText: (String) -> Void

    init(updateText: @escaping (String) -> Void) {
        self.updateText = updateText
    }
}

private enum ChitgramAutoPostTextEntry: ItemListNodeEntry {
    case text(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        return 0
    }

    static func <(lhs: ChitgramAutoPostTextEntry, rhs: ChitgramAutoPostTextEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoPostTextArguments
        switch self {
        case let .text(text):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: ChitgramStrings.get(493), maxLength: nil, sectionId: self.section, style: .blocks, minimalHeight: 160.0, textUpdated: { value in
                arguments.updateText(value)
            })
        }
    }
}

/// One typed variant of the message. Saving an empty text removes the variant.
private func chitgramAutoPostTextController(context: AccountContext, text: String, completion: @escaping (String) -> Void) -> ViewController {
    var currentText = text
    var popImpl: (() -> Void)?
    let arguments = ChitgramAutoPostTextArguments(updateText: { value in
        currentText = value
    })

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(466)),
            leftNavigationButton: nil,
            rightNavigationButton: ItemListNavigationButton(content: .text(presentationData.strings.Common_Save), style: .bold, enabled: true, action: {
                completion(currentText)
                popImpl?()
            }),
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        // The field owns the text while the screen is open, so redraws must not fight the typing.
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [ChitgramAutoPostTextEntry.text(text)], style: .blocks, focusItemTag: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    popImpl = { [weak controller] in
        controller?.view.endEditing(true)
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}

// MARK: Messages from Saved Messages (Android `AutoPostSavedActivity`)

private final class ChitgramAutoPostCheckArguments {
    let toggle: (Int64) -> Void

    init(toggle: @escaping (Int64) -> Void) {
        self.toggle = toggle
    }
}

private enum ChitgramAutoPostCheckEntry: ItemListNodeEntry {
    case header(String)
    case placeholder(String)
    case option(index: Int, id: Int64, title: String, checked: Bool)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .header:
            return 0
        case .placeholder:
            return 1
        case let .option(index, _, _, _):
            return 10 + Int32(index)
        case .footer:
            return 100000
        }
    }

    static func <(lhs: ChitgramAutoPostCheckEntry, rhs: ChitgramAutoPostCheckEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChitgramAutoPostCheckArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .placeholder(text), let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .option(_, id, title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.toggle(id)
            })
        }
    }
}

/// A short one-line description of a Saved Message, so the list reads like a chat.
private func chitgramAutoPostPreview(_ post: ChitgramChannelPost) -> String {
    let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: String?
    switch post.media {
    case .none:
        kind = nil
    case .photo:
        kind = ChitgramStrings.get(497)
    case .video:
        kind = ChitgramStrings.get(498)
    case .file:
        kind = ChitgramStrings.get(499)
    case .other:
        kind = ChitgramStrings.get(500)
    }
    if let kind, !text.isEmpty {
        return "\(kind) · \(text.prefix(50))"
    } else if let kind {
        return kind
    } else if !text.isEmpty {
        return String(text.prefix(60))
    } else {
        return ChitgramStrings.get(500)
    }
}

/// Picks the messages a task sends, straight from Saved Messages: the user posts there once whatever they want
/// to send (text, photo, video, poll…) and the task forwards it on schedule.
private func chitgramAutoPostSavedController(context: AccountContext, selected: [Int32], completion: @escaping ([Int32]) -> Void) -> ViewController {
    let session = ChitgramAutoPostPickerSession<[Int32]>(value: selected, completion: completion)
    let chosen = ValuePromise<[Int32]>(selected, ignoreRepeated: true)
    var presentImpl: ((ViewController) -> Void)?

    let arguments = ChitgramAutoPostCheckArguments(toggle: { id in
        let messageId = Int32(clamping: id)
        var value = session.value
        if let index = value.firstIndex(of: messageId) {
            value.remove(at: index)
        } else {
            if value.count >= ChitgramAutoPost.maxSources {
                chitgramAutoPostToast(context: context, text: ChitgramStrings.format(507, ChitgramAutoPost.maxSources), present: { c in
                    presentImpl?(c)
                })
                return
            }
            value.append(messageId)
        }
        session.value = value
        chosen.set(value)
    })

    let posts: Signal<[ChitgramChannelPost]?, NoError> = .single(nil)
    |> then(chitgramRecentPosts(account: context.account, peerId: context.account.peerId, limit: 60)
    |> map { posts -> [ChitgramChannelPost]? in
        return posts.filter { $0.id > 0 }
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, posts, chosen.get())
    |> map { presentationData, posts, chosenIds -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ChitgramAutoPostCheckEntry] = []
        entries.append(.header(ChitgramStrings.get(466)))
        if let posts {
            if posts.isEmpty {
                entries.append(.footer(ChitgramStrings.get(496)))
            } else {
                for (index, post) in posts.enumerated() {
                    entries.append(.option(index: index, id: Int64(post.id), title: chitgramAutoPostPreview(post), checked: chosenIds.contains(post.id)))
                }
                entries.append(.footer(ChitgramStrings.get(496)))
            }
        } else {
            entries.append(.placeholder("\u{2026}"))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(495)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    return controller
}

// MARK: Chats to send to (Android `AutoPostTargetsActivity`)

/// Groups and channels the account may post in, plus Saved Messages (handy for trying a task out).
private func chitgramAutoPostTargetsController(context: AccountContext, selected: [Int64], limit: Int, completion: @escaping ([Int64]) -> Void) -> ViewController {
    let session = ChitgramAutoPostPickerSession<[Int64]>(value: selected, completion: completion)
    let chosen = ValuePromise<[Int64]>(selected, ignoreRepeated: true)
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    let arguments = ChitgramAutoPostCheckArguments(toggle: { id in
        var value = session.value
        if let index = value.firstIndex(of: id) {
            value.remove(at: index)
        } else {
            if value.count >= limit {
                chitgramAutoPostLimitToast(context: context, text: ChitgramStrings.get(489), present: { c in
                    presentImpl?(c)
                }, push: { c in
                    pushImpl?(c)
                })
                return
            }
            value.append(id)
        }
        session.value = value
        chosen.set(value)
    })

    let accountPeerId = context.account.peerId
    let options: Signal<[(Int64, EnginePeer?)], NoError> = combineLatest(
        context.engine.messages.chatList(group: .root, count: 500) |> take(1),
        context.engine.messages.chatList(group: .archive, count: 200) |> take(1)
    )
    |> map { root, archive -> [(Int64, EnginePeer?)] in
        var result: [(Int64, EnginePeer?)] = [(accountPeerId.toInt64(), nil)]
        var seen = Set<Int64>([accountPeerId.toInt64()])
        for item in root.items + archive.items {
            guard let peer = item.renderedPeer.peer else {
                continue
            }
            switch peer {
            case .legacyGroup, .channel:
                break
            default:
                continue
            }
            if case let .channel(channel) = peer, channel.flags.contains(.isForum) {
                continue
            }
            if !canSendMessagesToPeer(peer) {
                continue
            }
            let value = peer.id.toInt64()
            if seen.insert(value).inserted {
                result.append((value, peer))
            }
        }
        return result
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, options, chosen.get())
    |> map { presentationData, options, chosenIds -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [ChitgramAutoPostCheckEntry] = []
        // How many are picked out of how many allowed, so the limit never comes as a surprise.
        entries.append(.header("\(ChitgramStrings.get(471)) · \(chosenIds.count)/\(limit)"))
        for (index, option) in options.enumerated() {
            let title: String
            if let peer = option.1 {
                title = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            } else {
                title = presentationData.strings.DialogList_SavedMessages
            }
            entries.append(.option(index: index, id: option.0, title: title, checked: chosenIds.contains(option.0)))
        }

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(ChitgramStrings.get(487)),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    return controller
}
