import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import LocalizedPeerData
import ChitgramCore

/// Chitgram auto messenger (Android `autopost/AutoPost`): repeats a message into chosen chats on a schedule.
///
/// Sending uses Telegram's own scheduled messages: upcoming sends are queued on the server ahead of time, so they go
/// out even when the phone is off. The app tops the queue up whenever it is opened.
///
/// The rules that keep it correct are Android's:
///  - One source of truth: every change goes through `update` / `edit` on the stored copy, never a copy a screen
///    loaded earlier, or an edit would leave the old queue running next to the new one.
///  - All network traffic goes through `Pacer`, one request at a time; a whole fill fired at once is what makes
///    Telegram answer FLOOD_WAIT.
///  - Telegram keeps at most 100 scheduled messages per chat, so a task never queues more than `perChatLimit`.
///
/// Everything here runs on the main queue. Chats are stored as `EnginePeer.Id.toInt64()`. Tasks are shared with the
/// account's other devices through `ChitgramAutoPostCloud`; only the device that owns a task fills its queue.
public enum ChitgramAutoPost {
    public static let modeCopy = 0
    public static let modeForward = 1

    public static let scheduleInterval = 0
    public static let scheduleTimes = 1

    /// Free plan: one task into two chats, at most hourly. Premium lifts all three.
    public static let freeTasks = 1
    public static let freeTargets = 2
    public static let freeMinInterval = 60
    public static let premiumTasks = 10
    public static let premiumTargets = 100
    public static let premiumMinInterval = 10
    public static let maxTimes = 12
    public static let maxTexts = 5
    public static let maxSources = 5

    /// How far ahead the queue may reach, and how many rounds a task keeps queued at most.
    private static let horizonSeconds: Int32 = 3 * 24 * 60 * 60
    private static let maxRoundsAhead = 40
    /// Telegram allows 100 scheduled messages per chat; leave room for the ones the user schedules by hand.
    private static let perChatLimit = 80
    /// Scheduling requests one refill may send (about four minutes at the pacer's pace).
    private static let requestBudget = 400
    private static let refillThrottleSeconds: Double = 10 * 60
    /// Spread the sends so a round never fires into every chat in the same second.
    private static let targetSpacingSeconds: Int32 = 25
    /// Telegram refuses a schedule_date that is not safely in the future, so "now" means a few seconds ahead.
    private static let firstSendDelaySeconds: Int32 = 20
    /// A task whose owner device has not refilled it for this long is taken over (Android `TAKEOVER_AFTER_SECONDS`).
    private static let takeoverAfterSeconds: Int32 = 20 * 60 * 60

    // Codes kept in Task.lastError; the screens turn them into words.
    public static let errFlood = "FLOOD"
    public static let errSpam = "SPAM"
    public static let errRemoved = "REMOVED"
    public static let errSourceGone = "SOURCE_GONE"
    public static let errOther = "OTHER"

    public struct Task: Codable, Equatable {
        // Configuration; every user edit bumps `rev`.
        public var id: Int64 = 0
        public var enabled: Bool = true
        public var name: String = ""
        public var mode: Int = ChitgramAutoPost.modeCopy
        /// Template messages taken from a real chat (Saved Messages), or empty when `texts` is used.
        public var sourceDialogId: Int64 = 0
        public var sourceIds: [Int32] = []
        /// Typed variants, used when there is no source message.
        public var texts: [String] = []
        public var targets: [Int64] = []
        public var scheduleMode: Int = ChitgramAutoPost.scheduleInterval
        public var intervalMinutes: Int = 60
        public var startHour: Int = 9
        public var endHour: Int = 22
        /// Minutes of the day for `scheduleTimes`, sorted.
        public var times: [Int] = []
        public var rev: Int64 = 0
        public var owner: String = ""

        // Run state and statistics.
        public var variantIndex: Int = 0
        /// Time of the last round put in the queue; the next one follows the schedule from here.
        public var lastSlot: Int32 = 0
        public var createdAt: Int32 = 0
        public var sentCount: Int = 0
        public var lastSentAt: Int32 = 0
        public var lastError: String?
        public var pausedUntil: Int32 = 0
        public var ownerSeen: Int32 = 0
        public var queuedSnapshot: Int = 0
        public var nextSnapshot: Int32 = 0
        public var statsAt: Int64 = 0

        // This device only.
        /// Bumped whenever the queue is thrown away; a reply to an older request is then deleted, not kept.
        public var queueGen: Int = 0
        public var uploaded: Bool = false
        /// Messages this device queued: "peerId:messageId:sendTime". Past entries move into `sentCount`.
        public var scheduled: [String] = []

        public init() {
        }

        public var variantCount: Int {
            return !self.sourceIds.isEmpty ? self.sourceIds.count : max(1, self.texts.count)
        }

        public var title: String {
            if !self.name.isEmpty {
                return self.name
            } else if let text = self.texts.first {
                return String(text.prefix(40))
            } else {
                return "#\(self.id % 1000)"
            }
        }

        // Android's JSON keys, so the two apps keep one format.
        enum CodingKeys: String, CodingKey {
            case id, enabled, name, mode, sourceDialogId, sourceIds, texts, targets, scheduleMode
            case intervalMinutes = "interval"
            case startHour, endHour, times, rev, owner, variantIndex, lastSlot, createdAt, sentCount, lastSentAt
            case lastError, pausedUntil, ownerSeen
            case queuedSnapshot = "queued"
            case nextSnapshot = "next"
            case statsAt, queueGen, uploaded, scheduled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self.mode = try container.decodeIfPresent(Int.self, forKey: .mode) ?? ChitgramAutoPost.modeCopy
            self.sourceDialogId = try container.decodeIfPresent(Int64.self, forKey: .sourceDialogId) ?? 0
            self.sourceIds = try container.decodeIfPresent([Int32].self, forKey: .sourceIds) ?? []
            self.texts = try container.decodeIfPresent([String].self, forKey: .texts) ?? []
            self.targets = try container.decodeIfPresent([Int64].self, forKey: .targets) ?? []
            self.scheduleMode = try container.decodeIfPresent(Int.self, forKey: .scheduleMode) ?? ChitgramAutoPost.scheduleInterval
            self.intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
            self.startHour = try container.decodeIfPresent(Int.self, forKey: .startHour) ?? 9
            self.endHour = try container.decodeIfPresent(Int.self, forKey: .endHour) ?? 22
            self.times = try container.decodeIfPresent([Int].self, forKey: .times) ?? []
            self.rev = try container.decodeIfPresent(Int64.self, forKey: .rev) ?? 0
            self.owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
            self.variantIndex = try container.decodeIfPresent(Int.self, forKey: .variantIndex) ?? 0
            self.lastSlot = try container.decodeIfPresent(Int32.self, forKey: .lastSlot) ?? 0
            self.createdAt = try container.decodeIfPresent(Int32.self, forKey: .createdAt) ?? 0
            self.sentCount = try container.decodeIfPresent(Int.self, forKey: .sentCount) ?? 0
            self.lastSentAt = try container.decodeIfPresent(Int32.self, forKey: .lastSentAt) ?? 0
            self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            self.pausedUntil = try container.decodeIfPresent(Int32.self, forKey: .pausedUntil) ?? 0
            self.ownerSeen = try container.decodeIfPresent(Int32.self, forKey: .ownerSeen) ?? 0
            self.queuedSnapshot = try container.decodeIfPresent(Int.self, forKey: .queuedSnapshot) ?? 0
            self.nextSnapshot = try container.decodeIfPresent(Int32.self, forKey: .nextSnapshot) ?? 0
            self.statsAt = try container.decodeIfPresent(Int64.self, forKey: .statsAt) ?? 0
            self.queueGen = try container.decodeIfPresent(Int.self, forKey: .queueGen) ?? 0
            self.uploaded = try container.decodeIfPresent(Bool.self, forKey: .uploaded) ?? false
            self.scheduled = try container.decodeIfPresent([String].self, forKey: .scheduled) ?? []
        }
    }

    // MARK: Storage

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func tasksKey(_ accountPeerId: EnginePeer.Id) -> String {
        return "chitgram_autopost_tasks_\(accountPeerId.toInt64())"
    }

    /// Random id of this installation, used to tell which device owns a task.
    public static func installId() -> String {
        if let value = self.defaults.string(forKey: "chitgram_autopost_install_id") {
            return value
        }
        let value = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        self.defaults.set(value, forKey: "chitgram_autopost_install_id")
        return value
    }

    public static func tasks(accountPeerId: EnginePeer.Id) -> [Task] {
        guard let data = self.defaults.data(forKey: self.tasksKey(accountPeerId)), let tasks = try? JSONDecoder().decode([Task].self, from: data) else {
            return []
        }
        return tasks
    }

    /// Whether a chat is a target of any task: a post that goes out there is the auto messenger's, not news.
    public static func isTarget(accountPeerId: EnginePeer.Id, peerId: EnginePeer.Id) -> Bool {
        let value = peerId.toInt64()
        return self.tasks(accountPeerId: accountPeerId).contains(where: { $0.targets.contains(value) })
    }

    static func save(_ tasks: [Task], accountPeerId: EnginePeer.Id) {
        if let data = try? JSONEncoder().encode(tasks) {
            self.defaults.set(data, forKey: self.tasksKey(accountPeerId))
        }
        self.notifyChanged()
    }

    public static func task(accountPeerId: EnginePeer.Id, id: Int64) -> Task? {
        return self.tasks(accountPeerId: accountPeerId).first(where: { $0.id == id })
    }

    /// Adds a new task (or replaces one wholesale).
    public static func put(accountPeerId: EnginePeer.Id, task: Task) {
        var task = task
        if task.owner.isEmpty {
            task.owner = self.installId()
        }
        if task.rev == 0 {
            task.rev = self.millis()
        }
        var tasks = self.tasks(accountPeerId: accountPeerId)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        self.save(tasks, accountPeerId: accountPeerId)
    }

    /// Load → change → save on the stored copy. Gives the updated task, or nil if it no longer exists.
    @discardableResult
    public static func update(accountPeerId: EnginePeer.Id, id: Int64, _ f: (inout Task) -> Void) -> Task? {
        var tasks = self.tasks(accountPeerId: accountPeerId)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        f(&tasks[index])
        self.save(tasks, accountPeerId: accountPeerId)
        return tasks[index]
    }

    /// A user edit: a new configuration version, and this device becomes the one that sends it.
    @discardableResult
    public static func edit(accountPeerId: EnginePeer.Id, id: Int64, _ f: (inout Task) -> Void) -> Task? {
        return self.update(accountPeerId: accountPeerId, id: id, { task in
            f(&task)
            task.rev = self.millis()
            task.owner = self.installId()
        })
    }

    /// A fresh task, not stored yet.
    public static func newTask(isPremium: Bool) -> Task {
        var task = Task()
        task.id = self.millis()
        task.intervalMinutes = max(60, self.minInterval(isPremium: isPremium))
        task.owner = self.installId()
        task.rev = self.millis()
        return task
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": "chitgram_autopost"])
    }

    private static func millis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func now(_ context: AccountContext) -> Int32 {
        return context.account.network.getApproximateRemoteTimestamp()
    }

    // MARK: Limits

    public static func isPremium(accountPeerId: EnginePeer.Id) -> Bool {
        return ChitgramPremium.isActive(accountPeerId: accountPeerId)
    }

    /// Ids of the tasks the current plan runs: all with Premium, the oldest `freeTasks` without. Tasks made under
    /// Premium are kept when it ends; they wait, they are not deleted.
    public static func runningIds(tasks: [Task], isPremium: Bool) -> Set<Int64> {
        if isPremium {
            return Set(tasks.map(\.id))
        }
        return Set(tasks.sorted(by: { $0.id < $1.id }).prefix(self.freeTasks).map(\.id))
    }

    public static func maxTasks(isPremium: Bool) -> Int {
        return isPremium ? self.premiumTasks : self.freeTasks
    }

    public static func maxTargets(isPremium: Bool) -> Int {
        return isPremium ? self.premiumTargets : self.freeTargets
    }

    public static func minInterval(isPremium: Bool) -> Int {
        return isPremium ? self.premiumMinInterval : self.freeMinInterval
    }

    /// Chats the current plan sends to: all with Premium, the first `freeTargets` without.
    static func planTargets(_ task: Task, isPremium: Bool) -> [Int64] {
        return Array(task.targets.prefix(self.maxTargets(isPremium: isPremium)))
    }

    /// True when the task has what it needs to start: something to send and somewhere to send it.
    public static func isReady(_ task: Task) -> Bool {
        return !task.targets.isEmpty && (!task.sourceIds.isEmpty || !task.texts.isEmpty) && (task.scheduleMode != self.scheduleTimes || !task.times.isEmpty)
    }

    public static func isMine(_ task: Task) -> Bool {
        return task.owner.isEmpty || task.owner == self.installId()
    }

    // MARK: Statistics

    private static func entryParts(_ entry: String) -> (peerId: Int64, messageId: Int32, date: Int32)? {
        let parts = entry.split(separator: ":")
        guard parts.count >= 3, let peerId = Int64(parts[0]), let messageId = Int32(parts[1]), let date = Int32(parts[2]) else {
            return nil
        }
        return (peerId, messageId, date)
    }

    /// Moves queue entries whose send time has passed into the counters, so "sent" and "in queue" stay true without
    /// asking the server. True when the task changed.
    static func syncStats(_ task: inout Task, now: Int32) -> Bool {
        var changed = false
        var remaining: [String] = []
        for entry in task.scheduled {
            if let parts = self.entryParts(entry), parts.date <= now {
                task.sentCount += 1
                task.lastSentAt = max(task.lastSentAt, parts.date)
                changed = true
            } else {
                remaining.append(entry)
            }
        }
        if changed {
            task.scheduled = remaining
            self.snapshot(&task, now: now)
        }
        return changed
    }

    /// Refreshes the statistics of every task, e.g. when a screen showing them opens.
    public static func syncAll(context: AccountContext) {
        let now = self.now(context)
        var tasks = self.tasks(accountPeerId: context.account.peerId)
        var changed = false
        for index in tasks.indices {
            if self.syncStats(&tasks[index], now: now) {
                changed = true
            }
        }
        if changed {
            self.save(tasks, accountPeerId: context.account.peerId)
        }
    }

    /// Messages still waiting on Telegram's servers.
    public static func queued(_ task: Task) -> Int {
        return self.isMine(task) ? task.scheduled.count : task.queuedSnapshot
    }

    private static func futureDates(_ task: Task, now: Int32) -> [Int32] {
        return task.scheduled.compactMap { self.entryParts($0)?.date }.filter { $0 > now }
    }

    /// Next send time of a task, or 0 when it is off.
    public static func nextSend(context: AccountContext, task: Task) -> Int32 {
        if !task.enabled || task.targets.isEmpty {
            return 0
        }
        let now = self.now(context)
        if !self.isMine(task) {
            return task.nextSnapshot > now ? task.nextSnapshot : 0
        }
        return self.futureDates(task, now: now).min() ?? 0
    }

    /// Last queued send: until then the queue keeps going even with the phone off.
    public static func queueEnds(context: AccountContext, task: Task) -> Int32 {
        return self.futureDates(task, now: self.now(context)).max() ?? 0
    }

    private static func snapshot(_ task: inout Task, now: Int32) {
        task.queuedSnapshot = task.scheduled.count
        task.nextSnapshot = self.futureDates(task, now: now).min() ?? 0
        task.statsAt = self.millis()
    }

    // MARK: Refill

    /// Tops up the server queue of every enabled task. Cheap and throttled, safe to call on every launch and resume.
    public static func refill(context: AccountContext) {
        let accountPeerId = context.account.peerId
        self.flushDeletes(context: context)
        let key = "chitgram_autopost_refill_\(accountPeerId.toInt64())"
        let last = self.defaults.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if now - last < self.refillThrottleSeconds {
            return
        }
        self.defaults.set(now, forKey: key)
        // Read the cloud first: another device may have edited, taken over or deleted a task meanwhile.
        ChitgramAutoPostCloud.pull(context: context, done: {
            self.refillNow(context: context)
        })
    }

    public static func refillNow(context: AccountContext) {
        let accountPeerId = context.account.peerId
        let isPremium = self.isPremium(accountPeerId: accountPeerId)
        let now = self.now(context)
        var tasks = self.tasks(accountPeerId: accountPeerId)
        for index in tasks.indices {
            let _ = self.syncStats(&tasks[index], now: now)
        }
        self.save(tasks, accountPeerId: accountPeerId)
        let running = self.runningIds(tasks: tasks, isPremium: isPremium)
        let active = tasks.filter { $0.enabled && self.isReady($0) && now >= $0.pausedUntil && running.contains($0.id) }
        if active.isEmpty {
            return
        }
        let budget = max(20, self.requestBudget / active.count)
        for task in active {
            if self.isMine(task) {
                self.fill(context: context, id: task.id, budget: budget)
            } else if now - task.ownerSeen > self.takeoverAfterSeconds {
                self.takeOver(context: context, id: task.id, budget: budget)
            }
        }
    }

    /// Puts the task's next rounds into the queue, breadth-first and within `budget` requests.
    private static func fill(context: AccountContext, id: Int64, budget: Int) {
        let accountPeerId = context.account.peerId
        let isPremium = self.isPremium(accountPeerId: accountPeerId)
        var tasks = self.tasks(accountPeerId: accountPeerId)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return
        }
        var task = tasks[index]
        if !task.enabled || !self.isReady(task) {
            return
        }
        let now = self.now(context)
        let minInterval = self.minInterval(isPremium: isPremium)
        if task.intervalMinutes < minInterval {
            task.intervalMinutes = minInterval
        }
        if task.owner.isEmpty {
            task.owner = self.installId()
        }

        let targets = self.planTargets(task, isPremium: isPremium)
        let minGap = isPremium ? 0 : Int32(minInterval * 60)
        var perChat = self.futurePerChat(tasks, now: now)
        var rounds = targets.map { target in self.futureCount(task, target: target, now: now) }.max() ?? 0
        var requests = 0
        var fresh = task.lastSlot == 0 && task.sentCount == 0 && task.scheduled.isEmpty && task.scheduleMode == self.scheduleInterval
        // At least one round per refill even when the task has more chats than its share of the budget.
        while rounds < self.maxRoundsAhead && (requests == 0 || requests + targets.count <= budget) {
            let slot = fresh ? now + self.firstSendDelaySeconds : self.nextSlot(task, now: now, minGap: minGap)
            if slot <= 0 || slot > now + self.horizonSeconds {
                break
            }
            // The very first round goes out at once and close together; later rounds are spread out.
            self.enqueueRound(context: context, task: task, targets: targets, slot: slot, perChat: &perChat, spacingOverride: fresh ? 2 : -1)
            fresh = false
            requests += targets.count
            task.lastSlot = slot
            task.variantIndex = (task.variantIndex + 1) % task.variantCount
            rounds += 1
        }
        if task.createdAt == 0 && task.lastSlot > 0 {
            task.createdAt = now
        }
        task.ownerSeen = now
        self.snapshot(&task, now: now)
        tasks[index] = task
        self.save(tasks, accountPeerId: accountPeerId)
        ChitgramAutoPostCloud.push(context: context, id: id, force: false)
    }

    // MARK: Taking over from a silent device

    /// The owner device has not refilled this task for a long time (lost, logged out, uninstalled). Before queueing
    /// anything, find what it already queued so this device continues after it instead of on top of it.
    private static func takeOver(context: AccountContext, id: Int64, budget: Int) {
        guard let snapshot = self.task(accountPeerId: context.account.peerId, id: id) else {
            return
        }
        self.sweep(context: context, task: snapshot, completion: { found in
            let now = self.now(context)
            self.update(accountPeerId: context.account.peerId, id: id, { task in
                task.owner = self.installId()
                task.rev = self.millis()
                task.ownerSeen = now
                task.scheduled = found.map { "\($0.peerId):\($0.messageId):\($0.date)" }
                if let last = found.map({ $0.date }).max(), last > task.lastSlot {
                    task.lastSlot = last
                }
            })
            self.fill(context: context, id: id, budget: budget)
            // Ownership moved: say so at once, so the old owner stands down if it comes back.
            ChitgramAutoPostCloud.push(context: context, id: id, force: true)
        })
    }

    /// The task's messages in its chats' scheduled lists, recognised by content: the task's text with no media, or
    /// the same text and kind of media as one of its source messages.
    private static func sweep(context: AccountContext, task: Task, completion: @escaping ([(peerId: Int64, messageId: Int32, date: Int32)]) -> Void) {
        let account = context.account
        let sources: Signal<[ChitgramChannelPost], NoError>
        if task.sourceIds.isEmpty {
            sources = .single([])
        } else {
            sources = chitgramPostsById(account: account, peerId: EnginePeer.Id(task.sourceDialogId), ids: task.sourceIds)
        }
        let _ = (sources
        |> deliverOnMainQueue).startStandalone(next: { sources in
            var found: [(peerId: Int64, messageId: Int32, date: Int32)] = []
            var remaining = task.targets
            func next() {
                if remaining.isEmpty {
                    completion(found)
                    return
                }
                let target = remaining.removeFirst()
                let _ = (chitgramScheduledPosts(account: account, peerId: EnginePeer.Id(target))
                |> deliverOnMainQueue).startStandalone(next: { posts in
                    for post in posts ?? [] where self.matches(post, task: task, sources: sources) {
                        found.append((target, post.id, post.date))
                    }
                    next()
                })
            }
            next()
        })
    }

    private static func matches(_ post: ChitgramChannelPost, task: Task, sources: [ChitgramChannelPost]) -> Bool {
        if post.text.contains(ChitgramAutoPostCloud.tag) {
            // Our own settings copy in Saved Messages.
            return false
        }
        if task.sourceIds.isEmpty {
            return post.media == .none && task.texts.contains(post.text)
        }
        return sources.contains(where: { $0.text == post.text && $0.media == post.media })
    }

    /// The next round after `lastSlot`, following the task's schedule; 0 = none. `minGap` keeps fixed times at least
    /// that far apart (the free plan's hourly minimum applies to them as well).
    private static func nextSlot(_ task: Task, now: Int32, minGap: Int32) -> Int32 {
        if task.scheduleMode == self.scheduleTimes {
            if task.times.isEmpty {
                return 0
            }
            let after = task.lastSlot == 0 ? now + 60 : max(now + 60, task.lastSlot + max(0, minGap - 1))
            return self.nextTimeSlot(after: after, times: task.times)
        } else {
            let base = task.lastSlot == 0 ? now + 120 : max(now + 120, task.lastSlot + Int32(task.intervalMinutes * 60))
            return self.nextAllowedTime(base, task: task)
        }
    }

    /// First moment strictly after `after` that falls on one of `times` (minutes of the day).
    public static func nextTimeSlot(after: Int32, times: [Int]) -> Int32 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(after)))
        let sorted = times.sorted()
        for day in 0 ... 7 {
            guard let dayStart = calendar.date(byAdding: .day, value: day, to: startOfDay) else {
                continue
            }
            for minute in sorted {
                if let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart) {
                    let value = Int32(date.timeIntervalSince1970)
                    if value > after {
                        return value
                    }
                }
            }
        }
        return 0
    }

    /// Moves `time` into the task's active hours (e.g. 09:00–22:00), jumping to the next day when needed.
    public static func nextAllowedTime(_ time: Int32, task: Task) -> Int32 {
        if task.startHour == task.endHour {
            return time
        }
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: Double(time))
        let hour = calendar.component(.hour, from: date)
        let inWindow: Bool
        if task.startHour < task.endHour {
            inWindow = hour >= task.startHour && hour < task.endHour
        } else {
            // The window crosses midnight.
            inWindow = hour >= task.startHour || hour < task.endHour
        }
        if inWindow {
            return time
        }
        var day = calendar.startOfDay(for: date)
        if hour >= task.endHour && task.startHour <= hour {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        guard let shiftedDate = calendar.date(bySettingHour: task.startHour, minute: 0, second: 0, of: day) else {
            return time
        }
        let shifted = Int32(shiftedDate.timeIntervalSince1970)
        return shifted <= time ? shifted + 24 * 60 * 60 : shifted
    }

    private static func futureCount(_ task: Task, target: Int64, now: Int32) -> Int {
        return task.scheduled.filter { entry in
            guard let parts = self.entryParts(entry) else {
                return false
            }
            return parts.peerId == target && parts.date > now
        }.count
    }

    private static func futurePerChat(_ tasks: [Task], now: Int32) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for task in tasks {
            for entry in task.scheduled {
                if let parts = self.entryParts(entry), parts.date > now {
                    result[parts.peerId, default: 0] += 1
                }
            }
        }
        return result
    }

    /// One round: this slot's message to every target, each a few seconds after the previous.
    private static func enqueueRound(context: AccountContext, task: Task, targets: [Int64], slot: Int32, perChat: inout [Int64: Int], spacingOverride: Int32) {
        let exact = task.scheduleMode == self.scheduleTimes
        let spacing: Int32
        if spacingOverride >= 0 {
            spacing = spacingOverride
        } else if exact {
            // Fixed times should land close to the time the user picked.
            spacing = 8
        } else {
            spacing = self.targetSpacingSeconds
        }
        let jitter: Int32 = (exact || spacingOverride >= 0) ? 5 : 60
        for (index, target) in targets.enumerated() {
            if perChat[target, default: 0] >= self.perChatLimit {
                continue
            }
            perChat[target, default: 0] += 1
            let at = slot + Int32(index) * spacing + Int32.random(in: 0 ..< jitter)
            guard let request = self.scheduleRequest(context: context, task: task, target: target, at: at) else {
                continue
            }
            let taskId = task.id
            let queueGen = task.queueGen
            ChitgramAutoPostPacer.shared.add(ChitgramAutoPostPacer.Job(context: context, taskId: taskId, scheduling: true, perform: request, completion: { outcome in
                self.onScheduled(context: context, taskId: taskId, queueGen: queueGen, target: target, outcome: outcome)
            }))
        }
    }

    /// The request for one send; it takes the earliest date Telegram still accepts when it finally goes out.
    private static func scheduleRequest(context: AccountContext, task: Task, target: Int64, at: Int32) -> ((Int32) -> Signal<ChitgramScheduleOutcome, NoError>)? {
        let account = context.account
        let targetPeerId = EnginePeer.Id(target)
        if !task.sourceIds.isEmpty {
            let sourcePeerId = EnginePeer.Id(task.sourceDialogId)
            let messageId = task.sourceIds[task.variantIndex % task.sourceIds.count]
            let dropAuthor = task.mode == self.modeCopy
            return { minDate in
                return chitgramScheduleForward(account: account, fromPeerId: sourcePeerId, messageId: messageId, toPeerId: targetPeerId, dropAuthor: dropAuthor, scheduleDate: max(at, minDate))
            }
        }
        if !task.texts.isEmpty {
            let text = task.texts[task.variantIndex % task.texts.count]
            return { minDate in
                return chitgramScheduleText(account: account, peerId: targetPeerId, text: text, scheduleDate: max(at, minDate))
            }
        }
        return nil
    }

    private static func onScheduled(context: AccountContext, taskId: Int64, queueGen: Int, target: Int64, outcome: ChitgramScheduleOutcome) {
        let accountPeerId = context.account.peerId
        switch outcome {
        case let .queued(messages):
            if messages.isEmpty {
                return
            }
            var tasks = self.tasks(accountPeerId: accountPeerId)
            guard let index = tasks.firstIndex(where: { $0.id == taskId }), tasks[index].queueGen == queueGen, tasks[index].enabled else {
                // The task was edited, stopped or deleted while this request was on its way: the message belongs to a
                // queue that no longer exists, so it must not go out.
                for message in messages {
                    self.addPendingDelete(context: context, peerId: target, messageId: message.id)
                }
                return
            }
            for message in messages {
                tasks[index].scheduled.append("\(target):\(message.id):\(message.date)")
            }
            self.snapshot(&tasks[index], now: self.now(context))
            self.save(tasks, accountPeerId: accountPeerId)
        case let .failed(error):
            self.onSendError(context: context, taskId: taskId, target: target, error: error)
        case .done:
            break
        }
    }

    /// A refused chat is dropped from the task; account-level trouble stops or pauses the whole task, because
    /// carrying on is exactly what gets an account limited.
    private static func onSendError(context: AccountContext, taskId: Int64, target: Int64, error: String) {
        let accountPeerId = context.account.peerId
        let refusedPrefixes = ["CHAT_WRITE_FORBIDDEN", "CHANNEL_PRIVATE", "USER_BANNED_IN_CHANNEL", "CHAT_SEND_", "PEER_ID_INVALID", "CHAT_ADMIN_REQUIRED", "CHAT_RESTRICTED", "CHANNEL_INVALID"]
        if error.hasPrefix("FLOOD_WAIT") || error.hasPrefix("SLOWMODE_WAIT") || error.hasPrefix("SCHEDULE_TOO_MUCH") || error.hasPrefix("SCHEDULE_DATE") {
            // The pacer or the next round deals with these.
            return
        } else if error == "PEER_FLOOD" {
            self.update(accountPeerId: accountPeerId, id: taskId, { task in
                task.enabled = false
                task.lastError = self.errSpam
            })
        } else if error.hasPrefix("MESSAGE_ID_INVALID") || error.hasPrefix("MESSAGE_IDS_EMPTY") || error == "MESSAGE_EMPTY" {
            self.update(accountPeerId: accountPeerId, id: taskId, { task in
                task.enabled = false
                task.lastError = self.errSourceGone
            })
        } else if refusedPrefixes.contains(where: { error.hasPrefix($0) }) {
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: EnginePeer.Id(target)))
            |> deliverOnMainQueue).startStandalone(next: { peer in
                let title = peer?.compactDisplayTitle ?? "\(target)"
                self.update(accountPeerId: accountPeerId, id: taskId, { task in
                    if let index = task.targets.firstIndex(of: target) {
                        task.targets.remove(at: index)
                        task.lastError = "\(self.errRemoved):\(title)"
                        task.rev = self.millis()
                    }
                    if task.targets.isEmpty {
                        task.enabled = false
                    }
                })
                ChitgramAutoPostCloud.push(context: context, id: taskId, force: true)
            })
        } else {
            self.update(accountPeerId: accountPeerId, id: taskId, { task in
                task.lastError = "\(self.errOther):\(error)"
            })
        }
        ChitgramAutoPostCloud.push(context: context, id: taskId, force: true)
    }

    /// Pauses every task after Telegram asked to wait; they resume by themselves on a later refill.
    static func onFlood(context: AccountContext, seconds: Int32) {
        let accountPeerId = context.account.peerId
        let until = self.now(context) + seconds
        var tasks = self.tasks(accountPeerId: accountPeerId)
        for index in tasks.indices where tasks[index].enabled {
            tasks[index].pausedUntil = until
            tasks[index].lastError = "\(self.errFlood):\(until)"
        }
        self.save(tasks, accountPeerId: accountPeerId)
    }

    // MARK: Cancelling

    /// Throws the task's queue away: the messages this device queued are deleted by id.
    private static func cancelQueue(context: AccountContext, id: Int64) {
        let now = self.now(context)
        var toDelete: [(Int64, Int32)] = []
        self.update(accountPeerId: context.account.peerId, id: id, { task in
            let _ = self.syncStats(&task, now: now)
            task.queueGen += 1
            for entry in task.scheduled {
                if let parts = self.entryParts(entry), parts.date > now {
                    toDelete.append((parts.peerId, parts.messageId))
                }
            }
            task.scheduled = []
            task.lastSlot = 0
            self.snapshot(&task, now: now)
        })
        ChitgramAutoPostPacer.shared.dropTask(id)
        self.addPendingDeletes(context: context, toDelete)
    }

    /// After an edit: throw the old queue away and build a fresh one.
    public static func reschedule(context: AccountContext, id: Int64) {
        self.cancelQueue(context: context, id: id)
        let now = self.now(context)
        self.update(accountPeerId: context.account.peerId, id: id, { task in
            task.lastError = nil
            task.pausedUntil = 0
            task.owner = self.installId()
            task.ownerSeen = now
        })
        self.fill(context: context, id: id, budget: self.requestBudget)
        ChitgramAutoPostCloud.push(context: context, id: id, force: true)
    }

    /// Deletes a task: its queue and the stored copy.
    public static func remove(context: AccountContext, id: Int64) {
        self.cancelQueue(context: context, id: id)
        let accountPeerId = context.account.peerId
        self.save(self.tasks(accountPeerId: accountPeerId).filter { $0.id != id }, accountPeerId: accountPeerId)
        // The "deleted" marker for the other devices, and no reviving from the cloud copy meanwhile.
        ChitgramAutoPostCloud.forget(context: context, id: id)
    }

    /// A brand-new task the user left without choosing anything is not worth keeping.
    public static func dropIfEmpty(accountPeerId: EnginePeer.Id, id: Int64) {
        guard let task = self.task(accountPeerId: accountPeerId, id: id) else {
            return
        }
        if !task.uploaded && task.sourceIds.isEmpty && task.texts.isEmpty && task.targets.isEmpty {
            self.save(self.tasks(accountPeerId: accountPeerId).filter { $0.id != id }, accountPeerId: accountPeerId)
        }
    }

    // MARK: Deleting scheduled messages, reliably

    /// Messages that must not go out are written down before the delete request is sent, and crossed off only when
    /// Telegram confirms. If the app dies in between, the next launch finishes the job; an orphaned queued message
    /// would otherwise go out days later.
    private static func pendingDeletesKey(_ accountPeerId: EnginePeer.Id) -> String {
        return "chitgram_autopost_pending_del_\(accountPeerId.toInt64())"
    }

    private static func pendingDeletes(_ accountPeerId: EnginePeer.Id) -> [String] {
        return self.defaults.stringArray(forKey: self.pendingDeletesKey(accountPeerId)) ?? []
    }

    private static func addPendingDelete(context: AccountContext, peerId: Int64, messageId: Int32) {
        self.addPendingDeletes(context: context, [(peerId, messageId)])
    }

    static func addPendingDeletes(context: AccountContext, _ entries: [(Int64, Int32)]) {
        if entries.isEmpty {
            return
        }
        let accountPeerId = context.account.peerId
        var pending = self.pendingDeletes(accountPeerId)
        for (peerId, messageId) in entries {
            let entry = "\(peerId):\(messageId)"
            if !pending.contains(entry) {
                pending.append(entry)
            }
        }
        self.defaults.set(pending, forKey: self.pendingDeletesKey(accountPeerId))
        self.flushDeletes(context: context)
    }

    private static var deletesInFlight = Set<String>()

    /// Batched per chat on the next main-queue turn, so a cancel of hundreds of messages is a few requests.
    private static func flushDeletes(context: AccountContext) {
        let accountPeerId = context.account.peerId
        Queue.mainQueue().justDispatch {
            var byPeer: [Int64: [Int32]] = [:]
            for entry in self.pendingDeletes(accountPeerId) {
                if self.deletesInFlight.contains(entry) {
                    continue
                }
                let parts = entry.split(separator: ":")
                guard parts.count >= 2, let peerId = Int64(parts[0]), let messageId = Int32(parts[1]) else {
                    continue
                }
                byPeer[peerId, default: []].append(messageId)
            }
            for (peerId, ids) in byPeer {
                var start = 0
                while start < ids.count {
                    let chunk = Array(ids[start ..< min(start + 100, ids.count)])
                    start += 100
                    let entries = chunk.map { "\(peerId):\($0)" }
                    self.deletesInFlight.formUnion(entries)
                    let account = context.account
                    ChitgramAutoPostPacer.shared.add(ChitgramAutoPostPacer.Job(context: context, taskId: 0, scheduling: false, perform: { _ in
                        return chitgramDeleteScheduledMessages(account: account, peerId: EnginePeer.Id(peerId), ids: chunk)
                    }, completion: { outcome in
                        self.deletesInFlight.subtract(entries)
                        var finished = false
                        switch outcome {
                        case .done, .queued:
                            finished = true
                        case let .failed(error):
                            // Nothing left to delete (already sent or already gone): cross it off as well.
                            finished = error.contains("MESSAGE_ID") || error == "PEER_ID_INVALID"
                        }
                        if finished {
                            let remaining = self.pendingDeletes(accountPeerId).filter { !entries.contains($0) }
                            self.defaults.set(remaining, forKey: self.pendingDeletesKey(accountPeerId))
                        }
                    }))
                }
            }
        }
    }
}

/// Every auto messenger request goes out one at a time, about 1.5 per second. Telegram tolerates that; a few hundred
/// at once is what it answers with FLOOD_WAIT. On FLOOD_WAIT the pacer waits as told; a long wait drops the pending
/// sends (the tasks pause and refill later) but never the deletes.
final class ChitgramAutoPostPacer {
    struct Job {
        let context: AccountContext
        let taskId: Int64
        let scheduling: Bool
        /// Takes the earliest schedule date Telegram still accepts at the moment the request leaves.
        let perform: (Int32) -> Signal<ChitgramScheduleOutcome, NoError>
        let completion: (ChitgramScheduleOutcome) -> Void
    }

    static let shared = ChitgramAutoPostPacer()

    private static let pace: Double = 0.65
    private static let maxInlineWaitSeconds: Int32 = 120

    private var queue: [Job] = []
    private var running = false
    private let disposable = MetaDisposable()

    private init() {
    }

    func add(_ job: Job) {
        self.queue.append(job)
        if !self.running {
            self.running = true
            Queue.mainQueue().justDispatch {
                self.next()
            }
        }
    }

    /// Forgets the queued sends of a task whose queue was just thrown away.
    func dropTask(_ taskId: Int64) {
        self.queue.removeAll(where: { $0.scheduling && $0.taskId == taskId })
    }

    private func next() {
        guard !self.queue.isEmpty else {
            self.running = false
            return
        }
        let job = self.queue.removeFirst()
        // A send that waited in line must still be scheduled in the future, or Telegram rejects it.
        let minDate = job.context.account.network.getApproximateRemoteTimestamp() + 10
        self.disposable.set((job.perform(minDate)
        |> deliverOnMainQueue).startStrict(next: { [weak self] outcome in
            guard let self else {
                return
            }
            if case let .failed(error) = outcome, error.hasPrefix("FLOOD_WAIT_"), let wait = Int32(error.dropFirst("FLOOD_WAIT_".count)) {
                if wait <= ChitgramAutoPostPacer.maxInlineWaitSeconds {
                    // The same request again after the wait.
                    self.queue.insert(job, at: 0)
                    Queue.mainQueue().after(Double(wait) + ChitgramAutoPostPacer.pace, {
                        self.next()
                    })
                } else {
                    // Gaps are fine, a burst of retries is not.
                    self.queue.removeAll(where: { $0.scheduling })
                    if job.scheduling {
                        job.completion(outcome)
                    }
                    ChitgramAutoPost.onFlood(context: job.context, seconds: wait)
                    Queue.mainQueue().after(ChitgramAutoPostPacer.pace, {
                        self.next()
                    })
                }
                return
            }
            job.completion(outcome)
            Queue.mainQueue().after(ChitgramAutoPostPacer.pace, {
                self.next()
            })
        }))
    }
}
