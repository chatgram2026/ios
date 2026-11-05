import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Android's dialog id for a chat stored as `EnginePeer.Id.toInt64()`: a user's id, minus a basic group's id, and
/// -100… for a channel. The cloud copy carries Android's ids, so a task reads the same on both apps.
func chitgramAndroidDialogId(_ value: Int64) -> Int64 {
    let peerId = EnginePeer.Id(value)
    let id = peerId.id._internalGetInt64Value()
    if peerId.namespace == Namespaces.Peer.CloudGroup {
        return -id
    } else if peerId.namespace == Namespaces.Peer.CloudChannel {
        return -1_000_000_000_000 - id
    } else {
        return id
    }
}

/// The reverse of `chitgramAndroidDialogId`.
func chitgramPeerIdValue(androidDialogId value: Int64) -> Int64 {
    if value > 0 {
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(value)).toInt64()
    } else if value < -1_000_000_000_000 {
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudChannel, id: EnginePeer.Id.Id._internalFromInt64Value(-value - 1_000_000_000_000)).toInt64()
    } else {
        return EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(-value)).toInt64()
    }
}

/// Auto messenger tasks kept in the account itself (Android `AutoPostCloud`), so another phone on the same account,
/// iPhone or Android, sees them: messages scheduled a year ahead in Saved Messages, rewritten long before their date.
///
/// Every copy carries its configuration version (`rev`) and statistics time (`statsAt`); on disagreement the newer
/// wins. A deleted task leaves a small "deleted" marker so the other devices delete it too. Main queue only.
public enum ChitgramAutoPostCloud {
    public static let tag = "#chitgram_autopost"
    private static let head = "\u{2699}\u{FE0F} Chitgram \u{00B7} avto xabar sozlamasi \u{2014} o'chirmang"
    private static let version = "v1"
    /// Payload characters per message, as in the settings copy.
    private static let chunk = 3500
    /// Telegram schedules at most a year ahead.
    private static let keepSeconds: Int32 = 360 * 24 * 60 * 60
    /// A copy with less than this left before its date is written again.
    private static let refreshBefore: Int32 = 200 * 24 * 60 * 60
    /// Statistics-only updates are shared at most this often; configuration changes go out at once.
    private static let statsPushThrottle: Double = 60 * 60
    private static let tombstoneKeepMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    private struct Version: Hashable, Comparable {
        let rev: Int64
        let statsAt: Int64

        static func <(lhs: Version, rhs: Version) -> Bool {
            if lhs.rev != rhs.rev {
                return lhs.rev < rhs.rev
            }
            return lhs.statsAt < rhs.statsAt
        }
    }

    private struct Entry {
        let taskId: Int64
        let version: Version
        let part: Int
        let total: Int
        let data: String
        let messageId: Int32
        let date: Int32
    }

    /// True while this device is reading the tasks from the cloud.
    public private(set) static var isPulling = false
    private static var pullWaiters: [() -> Void] = []
    private static var pushQueue: [Int64] = []
    private static var pushing = false
    private static var lastPush: [Int64: Double] = [:]

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func millis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    // MARK: Deleted here, marker not written yet

    private static func forgottenKey(_ accountPeerId: EnginePeer.Id) -> String {
        return "chitgram_autopost_forgotten_\(accountPeerId.toInt64())"
    }

    /// Tasks deleted on this device whose "deleted" marker is not written yet; the cloud copy must not revive them.
    private static func forgottenIds(_ accountPeerId: EnginePeer.Id) -> Set<Int64> {
        let values = self.defaults.stringArray(forKey: self.forgottenKey(accountPeerId)) ?? []
        return Set(values.compactMap { Int64($0) })
    }

    private static func setForgotten(_ accountPeerId: EnginePeer.Id, id: Int64, _ add: Bool) {
        var values = self.forgottenIds(accountPeerId)
        if add {
            values.insert(id)
        } else {
            values.remove(id)
        }
        self.defaults.set(values.map { String($0) }, forKey: self.forgottenKey(accountPeerId))
    }

    /// A task was deleted here: remember it until every device can learn about it.
    public static func forget(context: AccountContext, id: Int64) {
        self.setForgotten(context.account.peerId, id: id, true)
        self.push(context: context, id: id, force: true)
    }

    // MARK: Reading

    /// Reads the cloud copies and merges them into this device's tasks, then runs `done`.
    public static func pull(context: AccountContext, done: (() -> Void)? = nil) {
        if let done {
            self.pullWaiters.append(done)
        }
        if self.isPulling {
            return
        }
        self.isPulling = true
        self.fetch(context: context, completion: { entries in
            if let entries {
                self.merge(context: context, entries: entries)
            }
            self.isPulling = false
            let waiters = self.pullWaiters
            self.pullWaiters = []
            for waiter in waiters {
                waiter()
            }
            ChitgramAutoPost.syncAll(context: context)
        })
    }

    private static func fetch(context: AccountContext, completion: @escaping ([Entry]?) -> Void) {
        let _ = (chitgramScheduledPosts(account: context.account, peerId: context.account.peerId)
        |> deliverOnMainQueue).startStandalone(next: { posts in
            completion(posts?.compactMap(self.parse))
        })
    }

    private static func parse(_ post: ChitgramChannelPost) -> Entry? {
        let lines = post.text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(self.tag) }) else {
            return nil
        }
        let head = lines[index].trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard head.count >= 7, head[1] == self.version, let taskId = Int64(head[2]), let rev = Int64(head[3]), let statsAt = Int64(head[4]), let part = Int(head[5]), let total = Int(head[6]) else {
            return nil
        }
        let data = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
        return Entry(taskId: taskId, version: Version(rev: rev, statsAt: statsAt), part: part, total: total, data: data, messageId: post.id, date: post.date)
    }

    private static func merge(context: AccountContext, entries: [Entry]) {
        let accountPeerId = context.account.peerId
        let now = context.account.network.getApproximateRemoteTimestamp()
        var remote: [Int64: ChitgramAutoPost.Task] = [:]
        var deleted: [Int64: Int64] = [:]
        var stale: [Int32] = []
        var refresh = Set<Int64>()

        for (taskId, list) in Dictionary(grouping: entries, by: { $0.taskId }) {
            let versions = Dictionary(grouping: list, by: { $0.version }).sorted(by: { $0.key > $1.key })
            var chosen: Version?
            for (version, parts) in versions {
                guard let total = parts.first?.total, total >= 0 else {
                    continue
                }
                if total == 0 {
                    // The "deleted" marker.
                    deleted[taskId] = version.rev
                    chosen = version
                    if self.millis() - version.rev > self.tombstoneKeepMillis {
                        stale.append(contentsOf: parts.map { $0.messageId })
                    }
                    break
                }
                // A version still being written by another device is incomplete: skip it, don't touch it.
                var pieces: [String] = []
                for index in 1 ... total {
                    if let piece = parts.first(where: { $0.part == index }) {
                        pieces.append(piece.data)
                    }
                }
                if pieces.count != total {
                    continue
                }
                guard var task = self.decode(pieces.joined()) else {
                    continue
                }
                if task.owner.isEmpty {
                    // Never let a device think a foreign task is its own.
                    task.owner = "?"
                }
                remote[taskId] = task
                chosen = version
                if (parts.map { $0.date }.min() ?? 0) < now + self.refreshBefore {
                    refresh.insert(taskId)
                }
                break
            }
            // Older versions are leftovers of earlier writes.
            if let chosen {
                for entry in list where entry.version < chosen {
                    stale.append(entry.messageId)
                }
            }
        }

        let me = ChitgramAutoPost.installId()
        var tasks = ChitgramAutoPost.tasks(accountPeerId: accountPeerId)
        let forgotten = self.forgottenIds(accountPeerId)
        for (id, cloud) in remote {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                if forgotten.contains(id) {
                    // Deleted here, marker on its way.
                    continue
                }
                var cloud = cloud
                cloud.uploaded = true
                tasks.append(cloud)
                continue
            }
            var local = tasks[index]
            if cloud.rev > local.rev {
                let wasMine = ChitgramAutoPost.isMine(local)
                self.copyConfig(from: cloud, to: &local)
                if wasMine && cloud.owner != me {
                    // Another device edited or took over the task and now fills its queue: stop doing it here.
                    local.queueGen += 1
                    local.scheduled = []
                }
            }
            if cloud.statsAt > local.statsAt && !ChitgramAutoPost.isMine(local) {
                self.copyStats(from: cloud, to: &local)
            }
            local.uploaded = true
            tasks[index] = local
        }

        var queuedToDelete: [(Int64, Int32)] = []
        for (id, markerRev) in deleted {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else {
                continue
            }
            if tasks[index].rev > markerRev {
                // Edited here after it was deleted there: keep it.
                continue
            }
            for entry in tasks[index].scheduled {
                let parts = entry.split(separator: ":")
                guard parts.count >= 2, let peerId = Int64(parts[0]), let messageId = Int32(parts[1]) else {
                    continue
                }
                let date = parts.count >= 3 ? (Int32(parts[2]) ?? Int32.max) : Int32.max
                if date > now {
                    queuedToDelete.append((peerId, messageId))
                }
            }
            tasks.remove(at: index)
        }
        ChitgramAutoPost.save(tasks, accountPeerId: accountPeerId)
        ChitgramAutoPost.addPendingDeletes(context: context, queuedToDelete)

        if !stale.isEmpty {
            self.deleteMessages(context: context, ids: stale)
        }
        for task in tasks {
            let missing = remote[task.id] == nil && deleted[task.id] == nil
            if missing && task.uploaded {
                // Written before but gone without a "deleted" marker: removed by hand. Put it back.
                self.push(context: context, id: task.id, force: true)
            } else if !task.uploaded && ChitgramAutoPost.isReady(task) {
                self.push(context: context, id: task.id, force: true)
            } else if refresh.contains(task.id) {
                self.push(context: context, id: task.id, force: true)
            }
        }
    }

    private static func copyConfig(from: ChitgramAutoPost.Task, to: inout ChitgramAutoPost.Task) {
        to.enabled = from.enabled
        to.name = from.name
        to.mode = from.mode
        to.sourceDialogId = from.sourceDialogId
        to.sourceIds = from.sourceIds
        to.texts = from.texts
        to.targets = from.targets
        to.scheduleMode = from.scheduleMode
        to.intervalMinutes = from.intervalMinutes
        to.startHour = from.startHour
        to.endHour = from.endHour
        to.times = from.times
        to.rev = from.rev
        to.owner = from.owner
    }

    private static func copyStats(from: ChitgramAutoPost.Task, to: inout ChitgramAutoPost.Task) {
        to.variantIndex = from.variantIndex
        to.lastSlot = from.lastSlot
        to.createdAt = from.createdAt
        to.sentCount = from.sentCount
        to.lastSentAt = from.lastSentAt
        to.lastError = from.lastError
        to.pausedUntil = from.pausedUntil
        to.ownerSeen = from.ownerSeen
        to.queuedSnapshot = from.queuedSnapshot
        to.nextSnapshot = from.nextSnapshot
        to.statsAt = from.statsAt
    }

    // MARK: Writing

    /// Shares the task's current state (or its deletion) with the other devices. `force` is for configuration
    /// changes; statistics-only updates are throttled.
    public static func push(context: AccountContext, id: Int64, force: Bool) {
        let now = Date().timeIntervalSince1970
        if !force && now - (self.lastPush[id] ?? 0.0) < self.statsPushThrottle {
            return
        }
        if !self.pushQueue.contains(id) {
            self.pushQueue.append(id)
        }
        if !self.pushing {
            self.pushing = true
            Queue.mainQueue().justDispatch {
                self.nextPush(context: context)
            }
        }
    }

    private static func nextPush(context: AccountContext) {
        guard !self.pushQueue.isEmpty else {
            self.pushing = false
            return
        }
        let id = self.pushQueue.removeFirst()
        let accountPeerId = context.account.peerId
        // Read first: never overwrite an edit another device made meanwhile, and learn which old copies to remove.
        self.fetch(context: context, completion: { entries in
            guard let entries else {
                // Offline: the next refill tries again.
                self.pushing = false
                return
            }
            self.merge(context: context, entries: entries)
            let existing = entries.filter { $0.taskId == id }
            let task = ChitgramAutoPost.task(accountPeerId: accountPeerId, id: id)
            var texts: [String] = []
            if let task {
                if !task.uploaded && !ChitgramAutoPost.isReady(task) {
                    // Nothing worth sharing yet.
                    self.continuePushing(context: context)
                    return
                }
                if task.owner.isEmpty {
                    ChitgramAutoPost.update(accountPeerId: accountPeerId, id: id, { $0.owner = ChitgramAutoPost.installId() })
                }
                let current = existing.filter { $0.version == Version(rev: task.rev, statsAt: task.statsAt) }
                let now = context.account.network.getApproximateRemoteTimestamp()
                let aging = !current.isEmpty && (current.map { $0.date }.min() ?? 0) < now + self.refreshBefore
                if !current.isEmpty && !aging {
                    ChitgramAutoPost.update(accountPeerId: accountPeerId, id: id, { $0.uploaded = true })
                    self.continuePushing(context: context)
                    return
                }
                // Same content but the copy is getting old: write it again under a fresh statistics time.
                let fresh: ChitgramAutoPost.Task
                if aging {
                    fresh = ChitgramAutoPost.update(accountPeerId: accountPeerId, id: id, { $0.statsAt = self.millis() }) ?? task
                } else {
                    fresh = ChitgramAutoPost.task(accountPeerId: accountPeerId, id: id) ?? task
                }
                guard let payload = self.encode(fresh) else {
                    self.continuePushing(context: context)
                    return
                }
                var chunks: [String] = []
                var start = payload.startIndex
                while start < payload.endIndex {
                    let end = payload.index(start, offsetBy: self.chunk, limitedBy: payload.endIndex) ?? payload.endIndex
                    chunks.append(String(payload[start ..< end]))
                    start = end
                }
                let version = Version(rev: fresh.rev, statsAt: fresh.statsAt)
                texts = chunks.enumerated().map { index, data in self.format(id: id, version: version, part: index + 1, total: chunks.count, data: data) }
            } else {
                if existing.contains(where: { $0.total == 0 }) {
                    self.setForgotten(accountPeerId, id: id, false)
                    self.continuePushing(context: context)
                    return
                }
                texts = [self.format(id: id, version: Version(rev: self.millis(), statsAt: 0), part: 1, total: 0, data: "-")]
            }
            self.send(context: context, texts: texts, completion: { ok in
                if ok {
                    self.lastPush[id] = Date().timeIntervalSince1970
                    if task == nil {
                        self.setForgotten(accountPeerId, id: id, false)
                    } else {
                        ChitgramAutoPost.update(accountPeerId: accountPeerId, id: id, { $0.uploaded = true })
                    }
                    self.deleteMessages(context: context, ids: existing.map { $0.messageId })
                }
                self.continuePushing(context: context)
            })
        })
    }

    private static func continuePushing(context: AccountContext) {
        Queue.mainQueue().after(0.3, {
            self.nextPush(context: context)
        })
    }

    private static func format(id: Int64, version: Version, part: Int, total: Int, data: String) -> String {
        return "\(self.head)\n\(self.tag) \(self.version) \(id) \(version.rev) \(version.statsAt) \(part) \(total)\n\(data)"
    }

    /// Writes the texts as scheduled Saved Messages, in order, one at a time; false on the first failure.
    private static func send(context: AccountContext, texts: [String], completion: @escaping (Bool) -> Void) {
        let account = context.account
        let selfId = account.peerId
        let base = account.network.getApproximateRemoteTimestamp() + self.keepSeconds
        func sendText(_ index: Int) {
            if index >= texts.count {
                completion(true)
                return
            }
            let _ = (chitgramScheduleText(account: account, peerId: selfId, text: texts[index], scheduleDate: base + Int32(index))
            |> deliverOnMainQueue).startStandalone(next: { outcome in
                if case .queued = outcome {
                    sendText(index + 1)
                } else {
                    completion(false)
                }
            })
        }
        sendText(0)
    }

    private static func deleteMessages(context: AccountContext, ids: [Int32]) {
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start ..< min(start + 100, ids.count)])
            start += 100
            let _ = chitgramDeleteScheduledMessages(account: context.account, peerId: context.account.peerId, ids: chunk).startStandalone()
        }
    }

    // MARK: Encoding (Android's JSON, Android's chat ids, without this device's own fields)

    private static let localKeys = ["queueGen", "uploaded", "scheduled"]

    private static func encode(_ task: ChitgramAutoPost.Task) -> String? {
        guard let data = try? JSONEncoder().encode(task), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        for key in self.localKeys {
            object[key] = nil
        }
        if task.sourceDialogId != 0 {
            object["sourceDialogId"] = NSNumber(value: chitgramAndroidDialogId(task.sourceDialogId))
        }
        object["targets"] = task.targets.map { NSNumber(value: chitgramAndroidDialogId($0)) }
        guard let json = try? JSONSerialization.data(withJSONObject: object), let string = String(data: json, encoding: .utf8) else {
            return nil
        }
        return ChitgramGzip.pack(string)
    }

    private static func decode(_ data: String) -> ChitgramAutoPost.Task? {
        guard let json = ChitgramGzip.unpack(data), let jsonData = json.data(using: .utf8), var object = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        for key in self.localKeys {
            object[key] = nil
        }
        if let source = (object["sourceDialogId"] as? NSNumber)?.int64Value, source != 0 {
            object["sourceDialogId"] = NSNumber(value: chitgramPeerIdValue(androidDialogId: source))
        }
        if let targets = object["targets"] as? [NSNumber] {
            object["targets"] = targets.map { NSNumber(value: chitgramPeerIdValue(androidDialogId: $0.int64Value)) }
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(ChitgramAutoPost.Task.self, from: normalized)
    }
}
