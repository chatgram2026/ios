import Foundation

/// Chitgram profile badges, seen only inside Chitgram (Android `ChitgramBadges`): a Chitgram Premium member may pick an
/// emoji that shows after their name wherever Telegram draws an emoji status. A real Telegram emoji status always
/// wins, and nothing of ours reaches Telegram's servers or its database: the emoji is added where the status is read.
///
/// Who has what lives in Firestore, `badges/{telegramUserId}` = { e: emoji document id (0 = mark only), u: Premium end
/// in unix seconds }. Users met in the app are looked up in batches at most once per `ttl`, found badges are kept on
/// disk so they show at once on the next launch, and a badge whose `u` has passed stops showing. The lookups and
/// writes are the engine's (`lookup`); this store is thread-safe, since statuses are read on any thread.
public final class ChitgramBadges {
    public struct Badge: Equatable {
        public let emoji: Int64
        public let until: Int64

        public init(emoji: Int64, until: Int64) {
            self.emoji = emoji
            self.until = until
        }
    }

    public static let shared = ChitgramBadges()

    /// Stands for the Chitgram mark in the verification icon slot (Android `LOGO_ICON`); real document ids are positive.
    public static let markFileId: Int64 = -0x4347_4D41_524B

    /// Official Chitgram peers: @chitgram_bot (a user) and @chitgram_org (a channel), as on Android.
    private static let officialUsers: Set<Int64> = [8654927238]
    private static let officialChats: Set<Int64> = [4295910076]

    public static func isOfficialChat(_ channelId: Int64) -> Bool {
        return self.officialChats.contains(channelId)
    }

    /// The mark before the name: a Chitgram Premium member (a badge in force) or an official account.
    public func hasMark(userId: Int64) -> Bool {
        if ChitgramBadges.officialUsers.contains(userId) {
            return true
        }
        self.want(userId)
        return self.active(userId: userId) != nil
    }

    /// Posted on the main queue when looked-up badges changed.
    public static let didUpdateNotification = Notification.Name("ChitgramBadgesDidUpdate")

    private static let ttl: Double = 6 * 60 * 60
    /// After a failed lookup the same users are asked again only after this.
    private static let retry: Double = 10 * 60
    private static let flushDelay: Double = 1.2
    private static let storeKey = "chitgram_badges"

    private let lock = NSLock()
    private var badges: [Int64: Badge] = [:]
    private var checkedAt: [Int64: Double] = [:]
    private var pending = Set<Int64>()
    private var flushScheduled = false
    private var loaded = false

    /// Set by the engine at launch: looks the users up and answers through `apply` or `retryLater`.
    public var lookup: (([Int64]) -> Void)?

    private init() {
    }

    private func ensureLoaded() {
        if self.loaded {
            return
        }
        self.loaded = true
        guard let stored = ChitgramPreferences.shared.userDefaults.dictionary(forKey: ChitgramBadges.storeKey) else {
            return
        }
        for (key, value) in stored {
            guard let id = Int64(key), let pair = value as? [NSNumber], pair.count >= 2 else {
                continue
            }
            self.badges[id] = Badge(emoji: pair[0].int64Value, until: pair[1].int64Value)
        }
    }

    private func saveLocked() {
        let now = Int64(Date().timeIntervalSince1970)
        var stored: [String: [NSNumber]] = [:]
        for (id, badge) in self.badges where badge.until > now {
            stored[String(id)] = [NSNumber(value: badge.emoji), NSNumber(value: badge.until)]
        }
        ChitgramPreferences.shared.userDefaults.set(stored, forKey: ChitgramBadges.storeKey)
    }

    /// The user's badge while it lasts.
    public func active(userId: Int64) -> Badge? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.ensureLoaded()
        guard let badge = self.badges[userId], badge.until > Int64(Date().timeIntervalSince1970) else {
            return nil
        }
        return badge
    }

    /// The emoji after a user's name, if they have one; asks for a lookup when the user is due. Any thread.
    public func emoji(forUserId userId: Int64) -> Int64? {
        self.want(userId)
        guard let badge = self.active(userId: userId), badge.emoji != 0 else {
            return nil
        }
        return badge.emoji
    }

    /// Queues a lookup of the user unless they were looked up recently.
    public func want(_ userId: Int64) {
        if userId <= 0 {
            return
        }
        self.lock.lock()
        let now = Date().timeIntervalSince1970
        if let last = self.checkedAt[userId], now - last < ChitgramBadges.ttl {
            self.lock.unlock()
            return
        }
        let inserted = self.pending.insert(userId).inserted
        let schedule = inserted && !self.flushScheduled && self.lookup != nil
        if schedule {
            self.flushScheduled = true
        }
        self.lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + ChitgramBadges.flushDelay, execute: {
                self.flush()
            })
        }
    }

    /// Forgets when the user was looked up, so the next `want` asks again (Premium bought or the emoji changed).
    public func refresh(_ userId: Int64) {
        self.lock.lock()
        self.checkedAt[userId] = nil
        self.lock.unlock()
        self.want(userId)
    }

    private func flush() {
        self.lock.lock()
        self.flushScheduled = false
        let ids = Array(self.pending)
        self.pending.removeAll()
        let now = Date().timeIntervalSince1970
        for id in ids {
            self.checkedAt[id] = now
        }
        let lookup = self.lookup
        self.lock.unlock()
        if !ids.isEmpty {
            lookup?(ids)
        }
    }

    /// The answer for `checked`: `found` holds those that have a badge document. Main queue.
    public func apply(found: [Int64: Badge], checked: [Int64]) {
        self.lock.lock()
        self.ensureLoaded()
        var changed = false
        for id in checked {
            let badge = found[id]
            if self.badges[id] != badge {
                self.badges[id] = badge
                changed = true
            }
        }
        if changed {
            self.saveLocked()
        }
        self.lock.unlock()
        if changed {
            NotificationCenter.default.post(name: ChitgramBadges.didUpdateNotification, object: nil)
        }
    }

    /// A lookup failed (no network, rules not set yet): ask again after `retry`, not after the full `ttl`.
    public func retryLater(_ ids: [Int64]) {
        self.lock.lock()
        let at = Date().timeIntervalSince1970 - ChitgramBadges.ttl + ChitgramBadges.retry
        for id in ids {
            self.checkedAt[id] = at
        }
        self.lock.unlock()
    }

    /// The account's own badge was written.
    public func setOwn(userId: Int64, badge: Badge) {
        self.lock.lock()
        self.ensureLoaded()
        self.badges[userId] = badge
        self.checkedAt[userId] = Date().timeIntervalSince1970
        self.saveLocked()
        self.lock.unlock()
        NotificationCenter.default.post(name: ChitgramBadges.didUpdateNotification, object: nil)
    }
}
