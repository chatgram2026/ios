import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Chitgram Premium paid in Telegram Stars, with no server of our own (Android `premium/ChitgramPremium`).
///
/// Prices come from a pinned post in @chitgram_org written as "months-stars" pairs ("1-400 12-4000"). Buying sends an
/// anonymous paid ⭐ reaction to the channel's latest post; Premium is then read back from the account's own outgoing
/// Stars history, so it belongs to the Telegram account, survives reinstalls and any device can restore it. Each
/// payment's period is locked the first time it is seen, so a later price change never shortens it.
public enum ChitgramPremium {
    public struct Plan: Equatable {
        public let months: Int
        public let stars: Int64
    }

    public enum BuyResult {
        case activated(until: Int32)
        case notEnoughStars
        case failed(String)
    }

    public static let channelUsername = "chitgram_org"
    public static let defaultPlans: [Plan] = [Plan(months: 1, stars: 400), Plan(months: 12, stars: 4000)]
    /// One paid reaction carries at most this many Stars.
    private static let maxStars: Int64 = 10000
    private static let maxMonths = 24
    private static let daySeconds: Int64 = 24 * 60 * 60
    /// A just-paid reaction can take a moment to show up in the history; the local grant is trusted this long.
    private static let pendingTrustSeconds: Int32 = 10 * 60
    private static let maxHistoryPages = 30

    private static let plansKey = "chitgram_premium_plans"

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func now() -> Int32 {
        return Int32(Date().timeIntervalSince1970)
    }

    // MARK: Plans

    public static func plans() -> [Plan] {
        return self.parsePlans(self.defaults.string(forKey: self.plansKey) ?? "") ?? self.defaultPlans
    }

    /// "1-400 12-4000" → plans, or nil when the text is not a price list. Besides the pairs the post may only hold
    /// words that make it clearly one ("Premium", "narx", "tarif", ⭐…), so "Aksiya 10-15 sentyabr" is never a price.
    public static func parsePlans(_ text: String) -> [Plan]? {
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\d)(\\d{1,3})\\s*[-\u{2013}\u{2014}]\\s*(\\d{1,6})(?!\\d)") else {
            return nil
        }
        let nsText = text as NSString
        var plans: [Int: Plan] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard let months = Int(nsText.substring(with: match.range(at: 1))), let stars = Int64(nsText.substring(with: match.range(at: 2))) else {
                return nil
            }
            if months < 1 || months > self.maxMonths || stars < 1 || stars > self.maxStars {
                return nil
            }
            plans[months] = Plan(months: months, stars: stars)
        }
        if plans.isEmpty {
            return nil
        }
        let rest = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: " ").lowercased()
        let letters = rest.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        let markers = ["premium", "narx", "tarif", "stars", "\u{2B50}", "нарх", "цены", "тариф"]
        if !letters.isEmpty && !markers.contains(where: { rest.contains($0) }) {
            return nil
        }
        return plans.values.sorted(by: { $0.months < $1.months })
    }

    /// Whole years count as years, so "12" is exactly one.
    public static func periodSeconds(months: Int) -> Int64 {
        if months % 12 == 0 {
            return Int64(months / 12) * 365 * self.daySeconds
        } else {
            return Int64(months) * 30 * self.daySeconds
        }
    }

    /// What `stars` buy at today's prices: the longest plan they cover.
    public static func secondsFor(stars: Int64, plans: [Plan]) -> Int64 {
        guard let plan = plans.filter({ $0.stars <= stars }).max(by: { $0.months < $1.months }) else {
            return 0
        }
        return self.periodSeconds(months: plan.months)
    }

    // MARK: Status

    private static func key(_ name: String, _ accountPeerId: EnginePeer.Id) -> String {
        return "chitgram_premium_\(name)_\(accountPeerId.toInt64())"
    }

    /// Premium end in unix seconds for this account, 0 when it never had Premium.
    public static func until(accountPeerId: EnginePeer.Id) -> Int32 {
        let confirmed = Int32(clamping: self.defaults.integer(forKey: self.key("until", accountPeerId)))
        let pending = Int32(clamping: self.defaults.integer(forKey: self.key("pending_until", accountPeerId)))
        let pendingAt = Int32(clamping: self.defaults.integer(forKey: self.key("pending_at", accountPeerId)))
        if pending > confirmed && self.now() - pendingAt < self.pendingTrustSeconds {
            return pending
        }
        return confirmed
    }

    public static func isActive(accountPeerId: EnginePeer.Id) -> Bool {
        return self.until(accountPeerId: accountPeerId) > self.now()
    }

    /// Android key `premium_credits_<account>`: the period each payment bought, locked when first seen.
    private static func locks(_ accountPeerId: EnginePeer.Id) -> [String: Int64] {
        guard let data = self.defaults.data(forKey: "premium_credits_\(accountPeerId.toInt64())"), let value = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            return [:]
        }
        return value
    }

    private static func storeLocks(_ locks: [String: Int64], _ accountPeerId: EnginePeer.Id) {
        if let data = try? JSONEncoder().encode(locks) {
            self.defaults.set(data, forKey: "premium_credits_\(accountPeerId.toInt64())")
        }
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": "chitgram_premium"])
    }

    /// Premium end from the outgoing Stars history: settled reactions to the channel, each buying the longest plan it
    /// paid for, periods stacked in date order.
    static func computeUntil(transactions: [StarsContext.State.Transaction], channelId: EnginePeer.Id, locks: inout [String: Int64]) -> Int32 {
        let plans = self.plans()
        let longest = self.periodSeconds(months: self.maxMonths)
        var until: Int64 = 0
        let payments = transactions.filter { transaction in
            if !transaction.flags.contains(.isReaction) || transaction.flags.contains(.isPending) || transaction.flags.contains(.isFailed) || transaction.flags.contains(.isRefund) {
                return false
            }
            if case let .peer(peer) = transaction.peer, peer.id == channelId {
                return true
            }
            return false
        }.sorted(by: { $0.date < $1.date })
        for payment in payments {
            let seconds: Int64
            if let locked = locks[payment.id] {
                seconds = max(0, min(longest, locked))
            } else {
                seconds = self.secondsFor(stars: abs(payment.count.amount.value), plans: plans)
                locks[payment.id] = seconds
            }
            if seconds > 0 {
                until = max(until, Int64(payment.date)) + seconds
            }
        }
        return Int32(clamping: until)
    }

    private static func resolveChannel(context: AccountContext) -> Signal<EnginePeer?, NoError> {
        return context.engine.peers.resolvePeerByName(name: self.channelUsername, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            switch result {
            case .progress:
                return .complete()
            case let .result(peer):
                return .single(peer)
            }
        }
        |> take(1)
    }

    /// The account's outgoing Stars history, every page (up to a limit, and no older than three years).
    private static func outgoingHistory(context: AccountContext) -> Signal<[StarsContext.State.Transaction], NoError> {
        return Signal { subscriber in
            let transactionsContext = context.engine.payments.peerStarsTransactionsContext(subject: .peer(peerId: context.account.peerId, ton: false), mode: .outgoing)
            var pages = 0
            let oldestUseful = Int32(Date().timeIntervalSince1970) - Int32(3 * 365 * 24 * 60 * 60)
            let disposable = transactionsContext.state.start(next: { state in
                if state.isLoading {
                    return
                }
                let oldest = state.transactions.map(\.date).min() ?? Int32.max
                if state.canLoadMore && pages < ChitgramPremium.maxHistoryPages && oldest > oldestUseful {
                    pages += 1
                    transactionsContext.loadMore()
                } else {
                    subscriber.putNext(state.transactions)
                    subscriber.putCompletion()
                }
            })
            return ActionDisposable {
                disposable.dispose()
                let _ = transactionsContext
            }
        }
    }

    /// Re-reads the Stars history and stores the result; gives the Premium end, or nil when the check failed.
    public static func refresh(context: AccountContext) -> Signal<Int32?, NoError> {
        let accountPeerId = context.account.peerId
        return self.resolveChannel(context: context)
        |> mapToSignal { channel -> Signal<Int32?, NoError> in
            guard let channel else {
                return .single(nil)
            }
            return self.outgoingHistory(context: context)
            |> take(1)
            |> map { transactions -> Int32? in
                var locks = self.locks(accountPeerId)
                // Never lower a confirmed end: a paid reaction cannot be refunded, so a smaller result only means the
                // history came back incomplete.
                let previous = Int32(clamping: self.defaults.integer(forKey: self.key("until", accountPeerId)))
                let until = max(self.computeUntil(transactions: transactions, channelId: channel.id, locks: &locks), previous)
                self.storeLocks(locks, accountPeerId)
                self.defaults.set(Int(until), forKey: self.key("until", accountPeerId))
                self.defaults.set(Date().timeIntervalSince1970, forKey: self.key("checked_at", accountPeerId))
                self.notifyChanged()
                return self.until(accountPeerId: accountPeerId)
            }
        }
    }

    /// Reads the price pin; among the pinned posts the newest one that is a price list wins.
    public static func refreshPlans(context: AccountContext) -> Signal<Bool, NoError> {
        return self.resolveChannel(context: context)
        |> mapToSignal { channel -> Signal<Bool, NoError> in
            guard let channel else {
                return .single(false)
            }
            return chitgramPinnedPosts(account: context.account, peerId: channel.id)
            |> map { posts -> Bool in
                guard let plans = posts.lazy.compactMap({ self.parsePlans($0.text) }).first else {
                    return false
                }
                let text = plans.map { "\($0.months)-\($0.stars)" }.joined(separator: " ")
                let changed = text != self.defaults.string(forKey: self.plansKey)
                self.defaults.set(text, forKey: self.plansKey)
                if changed {
                    self.notifyChanged()
                }
                return changed
            }
        }
    }

    /// Pays for `plan` with a paid ⭐ reaction to the channel's latest post.
    public static func buy(context: AccountContext, plan: Plan) -> Signal<BuyResult, NoError> {
        let accountPeerId = context.account.peerId
        return self.resolveChannel(context: context)
        |> mapToSignal { channel -> Signal<BuyResult, NoError> in
            guard let channel else {
                return .single(.failed("CHANNEL_NOT_FOUND"))
            }
            return chitgramRecentPosts(account: context.account, peerId: channel.id, limit: 5)
            |> mapToSignal { posts -> Signal<BuyResult, NoError> in
                guard let post = posts.first else {
                    return .single(.failed("NO_POST"))
                }
                return chitgramSendPaidReaction(account: context.account, peerId: channel.id, messageId: post.id, stars: Int32(plan.stars))
                |> map { error -> BuyResult in
                    if let error {
                        return error == "BALANCE_TOO_LOW" ? .notEnoughStars : .failed(error)
                    }
                    let pendingUntil = max(self.until(accountPeerId: accountPeerId), self.now()) + Int32(clamping: self.periodSeconds(months: plan.months))
                    self.defaults.set(Int(pendingUntil), forKey: self.key("pending_until", accountPeerId))
                    self.defaults.set(Int(self.now()), forKey: self.key("pending_at", accountPeerId))
                    self.notifyChanged()
                    return .activated(until: pendingUntil)
                }
            }
        }
    }
}
