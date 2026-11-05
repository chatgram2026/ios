import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChitgramCore

/// Four chat folders that sort the user's groups and channels by the rights they hold there (Android
/// `folders/AdminFolders`): groups they own, groups they administer, channels they own, channels they administer.
///
/// Telegram folders live on the server: creating them writes to the account and they show up in official Telegram on
/// every device, so nothing here runs without the user confirming it, and turning the feature off removes exactly
/// these folders. Telegram has no "I am an admin" filter flag, so membership is an explicit list: a snapshot, kept
/// current by `sync` (a delta that preserves chats the user added or removed by hand) and rebuilt by `rebuild`.
///
/// iOS writes the whole folder list in one local transaction that Telegram then syncs, so a create, refresh or
/// remove is a single step here rather than Android's chain of requests.
public enum ChitgramAdminFolders {
    public enum Kind: Int, CaseIterable {
        case groupOwner
        case groupAdmin
        case channelOwner
        case channelAdmin

        var titleId: Int {
            switch self {
            case .groupOwner:
                return 393
            case .groupAdmin:
                return 394
            case .channelOwner:
                return 395
            case .channelAdmin:
                return 396
            }
        }

        /// Telegram's folder title limit is 12 characters; the marker makes the folder recognisably ours.
        var title: String {
            return String((ChitgramAdminFolders.marker + ChitgramStrings.get(self.titleId)).prefix(ChitgramAdminFolders.maxFolderName))
        }

        /// Every title a folder of this kind could carry, in each of the app's languages.
        var knownTitles: Set<String> {
            var result = Set<String>()
            for language in [ChitgramStrings.Language.en, .uz, .ru] {
                let text = ChitgramStrings.get(self.titleId, language: language)
                if !text.isEmpty {
                    result.insert(String((ChitgramAdminFolders.marker + text).prefix(ChitgramAdminFolders.maxFolderName)))
                }
            }
            return result
        }
    }

    public struct Result {
        /// Set when nothing could be done; already in words.
        public let blockedReason: String?
        /// Folders cut to Telegram's per-folder limit: title and how many chats it kept.
        public let truncated: [(String, Int)]
    }

    static let marker = "\u{2605}"
    static let maxFolderName = 12

    private static var defaults: UserDefaults {
        return ChitgramPreferences.shared.userDefaults
    }

    private static func idsKey(_ accountPeerId: EnginePeer.Id) -> String {
        return "admin_folder_ids_\(accountPeerId.toInt64())"
    }

    private static func snapshotKey(_ accountPeerId: EnginePeer.Id) -> String {
        return "admin_folder_snap_\(accountPeerId.toInt64())"
    }

    /// kind → folder id, for the folders this feature made.
    static func kindToFilter(_ accountPeerId: EnginePeer.Id) -> [Kind: Int32] {
        var result: [Kind: Int32] = [:]
        for part in (self.defaults.string(forKey: self.idsKey(accountPeerId)) ?? "").split(separator: ",") {
            let bits = part.split(separator: ":")
            if bits.count == 2, let rawKind = Int(bits[0]), let kind = Kind(rawValue: rawKind), let id = Int32(bits[1]) {
                result[kind] = id
            }
        }
        return result
    }

    private static func saveKindToFilter(_ map: [Kind: Int32], _ accountPeerId: EnginePeer.Id) {
        if map.isEmpty {
            self.defaults.removeObject(forKey: self.idsKey(accountPeerId))
        } else {
            let text = Kind.allCases.compactMap { kind in map[kind].flatMap { "\(kind.rawValue):\($0)" } }.joined(separator: ",")
            self.defaults.set(text, forKey: self.idsKey(accountPeerId))
        }
        NotificationCenter.default.post(name: ChitgramPreferences.didChangeNotification, object: ChitgramPreferences.shared, userInfo: ["key": "admin_folder_ids"])
    }

    /// The chats filed per kind at the last sync.
    private static func snapshot(_ accountPeerId: EnginePeer.Id) -> [Kind: Set<Int64>] {
        var result: [Kind: Set<Int64>] = [:]
        let chunks = (self.defaults.string(forKey: self.snapshotKey(accountPeerId)) ?? "").split(separator: ";", omittingEmptySubsequences: false)
        for kind in Kind.allCases {
            var set = Set<Int64>()
            if kind.rawValue < chunks.count {
                for value in chunks[kind.rawValue].split(separator: ",") {
                    if let id = Int64(value) {
                        set.insert(id)
                    }
                }
            }
            result[kind] = set
        }
        return result
    }

    private static func saveSnapshot(_ snapshot: [Kind: Set<Int64>], _ accountPeerId: EnginePeer.Id) {
        let text = Kind.allCases.map { kind in (snapshot[kind] ?? []).map { "\($0)" }.joined(separator: ",") }.joined(separator: ";")
        self.defaults.set(text, forKey: self.snapshotKey(accountPeerId))
    }

    public static func isEnabled(accountPeerId: EnginePeer.Id) -> Bool {
        return !self.kindToFilter(accountPeerId).isEmpty
    }

    private static var busy = Set<EnginePeer.Id>()

    public static func isBusy(accountPeerId: EnginePeer.Id) -> Bool {
        return self.busy.contains(accountPeerId)
    }

    // MARK: Classify

    /// Every chat the user holds rights in, by kind. Owners stay out of the admin kinds, or "My groups" and
    /// "Admin group" would be near duplicates. Nil while the chat list is not on disk yet: an empty list there
    /// would read as "you lost your rights everywhere".
    private static func classify(context: AccountContext) -> Signal<[Kind: [EnginePeer.Id]]?, NoError> {
        return combineLatest(
            context.engine.messages.chatList(group: .root, count: 5000) |> take(1),
            context.engine.messages.chatList(group: .archive, count: 2000) |> take(1)
        )
        |> map { root, archive -> [Kind: [EnginePeer.Id]]? in
            if root.items.isEmpty {
                return nil
            }
            var result: [Kind: [EnginePeer.Id]] = [:]
            for kind in Kind.allCases {
                result[kind] = []
            }
            var seen = Set<EnginePeer.Id>()
            for item in root.items + archive.items {
                guard let peer = item.renderedPeer.peer, seen.insert(peer.id).inserted else {
                    continue
                }
                let kind: Kind
                switch peer {
                case let .channel(channel):
                    if channel.participationStatus != .member {
                        continue
                    }
                    let owner = channel.flags.contains(.isCreator)
                    if !owner && channel.adminRights == nil {
                        continue
                    }
                    var broadcast = false
                    if case .broadcast = channel.info {
                        broadcast = true
                    }
                    if broadcast {
                        kind = owner ? .channelOwner : .channelAdmin
                    } else {
                        kind = owner ? .groupOwner : .groupAdmin
                    }
                case let .legacyGroup(group):
                    if group.membership != .Member {
                        continue
                    }
                    switch group.role {
                    case .creator:
                        kind = .groupOwner
                    case .admin:
                        kind = .groupAdmin
                    case .member:
                        continue
                    }
                default:
                    continue
                }
                result[kind, default: []].append(peer.id)
            }
            return result
        }
    }

    /// Folders allowed on the account, and chats allowed in one folder.
    private static func limits(context: AccountContext) -> Signal<(Int, Int), NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> mapToSignal { peer -> Signal<(Int, Int), NoError> in
            return context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.UserLimits(isPremium: peer?.isPremium ?? false))
            |> map { limits -> (Int, Int) in
                return (Int(limits.maxFoldersCount), Int(limits.maxFolderChatsCount))
            }
        }
    }

    private static func folderTitleText(_ filter: ChatListFilter) -> String? {
        if case let .filter(_, title, _, _) = filter {
            return title.text
        }
        return nil
    }

    private static func filterId(_ filter: ChatListFilter) -> Int32? {
        if case let .filter(id, _, _, _) = filter {
            return id
        }
        return nil
    }

    /// A folder of `kind` holding exactly `peers`; an existing folder keeps its exclusions (minus the members) and
    /// its pinned chats that are still members.
    private static func folder(id: Int32, kind: Kind, peers: [EnginePeer.Id], existing: ChatListFilterData?) -> ChatListFilter {
        var data = existing ?? ChatListFilterData(isShared: false, hasSharedLinks: false, categories: [], excludeMuted: false, excludeRead: false, excludeArchived: false, includePeers: ChatListFilterIncludePeers(), excludePeers: [], color: PeerNameColor(rawValue: Int32(kind.rawValue)))
        // No auto-include: membership is exactly the list.
        data.categories = []
        data.excludeMuted = false
        data.excludeRead = false
        data.excludeArchived = false
        data.includePeers.setPeers(peers)
        data.excludePeers.removeAll(where: { peers.contains($0) })
        return .filter(id: id, title: ChatFolderTitle(text: kind.title, entities: [], enableAnimations: true), emoticon: nil, data: data)
    }

    // MARK: Create and refresh

    /// Puts the folders back to exactly what the user's rights say: a folder of ours is rewritten in place (it keeps
    /// its position, exclusions and pins), one whose kind is now empty is removed, a missing one is adopted by its
    /// title or created while there is room. The first build (the switch turned on) is the same operation.
    public static func rebuild(context: AccountContext) -> Signal<Result, NoError> {
        let accountPeerId = context.account.peerId
        if self.busy.contains(accountPeerId) {
            return .complete()
        }
        self.busy.insert(accountPeerId)
        let engine = context.engine

        return combineLatest(self.classify(context: context), self.limits(context: context))
        |> mapToSignal { buckets, limits -> Signal<Result, NoError> in
            let (folderLimit, perFolder) = limits
            guard let buckets else {
                return .single(Result(blockedReason: ChitgramStrings.get(399), truncated: []))
            }
            if buckets.values.allSatisfy({ $0.isEmpty }) && self.kindToFilter(accountPeerId).isEmpty {
                return .single(Result(blockedReason: ChitgramStrings.get(399), truncated: []))
            }
            final class Outcome {
                var map: [Kind: Int32] = [:]
                var truncated: [(String, Int)] = []
                var blocked: String?
            }
            let outcome = Outcome()
            let tracked = self.kindToFilter(accountPeerId)

            return engine.peers.updateChatListFiltersInteractively { filters in
                var filters = filters
                var map = tracked
                var taken = Set<Int32>()
                var skipped = 0
                for kind in Kind.allCases {
                    var peers = buckets[kind] ?? []
                    if peers.count > perFolder {
                        peers = Array(peers.prefix(perFolder))
                        outcome.truncated.append((kind.title, perFolder))
                    }
                    let trackedIds = Set(map.values)
                    var index: Int?
                    if let id = map[kind] {
                        index = filters.firstIndex(where: { self.filterId($0) == id })
                    }
                    if index == nil {
                        // Adopt a folder of ours that the bookkeeping lost (a reinstall), instead of a second one.
                        let known = kind.knownTitles
                        index = filters.firstIndex(where: { filter in
                            guard let id = self.filterId(filter), let text = self.folderTitleText(filter) else {
                                return false
                            }
                            return known.contains(text) && !trackedIds.contains(id) && !taken.contains(id)
                        })
                    }
                    if let index, let id = self.filterId(filters[index]) {
                        if peers.isEmpty {
                            // Telegram refuses a folder with no members, and create would not have made one.
                            filters.remove(at: index)
                            map[kind] = nil
                        } else {
                            var existing: ChatListFilterData?
                            if case let .filter(_, _, _, data) = filters[index] {
                                existing = data
                            }
                            filters[index] = self.folder(id: id, kind: kind, peers: peers, existing: existing)
                            map[kind] = id
                            taken.insert(id)
                        }
                    } else if !peers.isEmpty {
                        let count = filters.filter { self.filterId($0) != nil }.count
                        if count >= folderLimit {
                            skipped += 1
                            map[kind] = nil
                            continue
                        }
                        let id = engine.peers.generateNewChatListFilterId(filters: filters)
                        filters.append(self.folder(id: id, kind: kind, peers: peers, existing: nil))
                        map[kind] = id
                        taken.insert(id)
                    } else {
                        map[kind] = nil
                    }
                }
                if skipped > 0 {
                    let count = filters.filter { self.filterId($0) != nil }.count
                    outcome.blocked = ChitgramStrings.format(400, folderLimit, count)
                }
                outcome.map = map
                return filters
            }
            |> map { _ -> Result in
                self.saveKindToFilter(outcome.map, accountPeerId)
                var snapshot: [Kind: Set<Int64>] = [:]
                for kind in Kind.allCases {
                    snapshot[kind] = Set((buckets[kind] ?? []).map { $0.toInt64() })
                }
                self.saveSnapshot(snapshot, accountPeerId)
                return Result(blockedReason: outcome.blocked, truncated: outcome.truncated)
            }
        }
        |> deliverOnMainQueue
        |> afterDisposed {
            Queue.mainQueue().async {
                self.busy.remove(accountPeerId)
            }
        }
    }

    // MARK: Sync

    private static var lastSync: [EnginePeer.Id: Double] = [:]

    /// Keeps the folders current without the user pressing Refresh. It applies a delta, never a rewrite: only chats
    /// whose rights changed since the last sync are added or removed, so a chat the user added or dropped by hand
    /// stays as they left it. A folder deleted by hand is forgotten, not brought back.
    public static func sync(context: AccountContext) {
        let accountPeerId = context.account.peerId
        let now = Date().timeIntervalSince1970
        if now - (self.lastSync[accountPeerId] ?? 0.0) < 10.0 || self.busy.contains(accountPeerId) || !self.isEnabled(accountPeerId: accountPeerId) {
            return
        }
        self.lastSync[accountPeerId] = now
        self.busy.insert(accountPeerId)
        let engine = context.engine

        // Folders are changed only once the account's own list has arrived from the server.
        let _ = (engine.peers.chatListFiltersAreSynced()
        |> filter { $0 }
        |> take(1)
        |> mapToSignal { _ -> Signal<Bool, NoError> in
            return combineLatest(self.classify(context: context), self.limits(context: context))
            |> mapToSignal { buckets, limits -> Signal<Bool, NoError> in
                guard let buckets else {
                    return .single(false)
                }
                let (folderLimit, perFolder) = limits
                let tracked = self.kindToFilter(accountPeerId)
                let snapshot = self.snapshot(accountPeerId)
                var changed = false
                for kind in Kind.allCases {
                    let current = Set((buckets[kind] ?? []).map { $0.toInt64() })
                    if tracked[kind] != nil {
                        if current != (snapshot[kind] ?? []) {
                            changed = true
                        }
                    } else if !current.isEmpty {
                        changed = true
                    }
                }
                if !changed {
                    return .single(false)
                }

                final class Outcome {
                    var map: [Kind: Int32] = [:]
                }
                let outcome = Outcome()
                return engine.peers.updateChatListFiltersInteractively { filters in
                    var filters = filters
                    var map = tracked
                    for kind in Kind.allCases {
                        let current = buckets[kind] ?? []
                        if let id = map[kind] {
                            guard let index = filters.firstIndex(where: { self.filterId($0) == id }), case let .filter(_, _, _, data) = filters[index] else {
                                // Deleted by hand or on another device: forget it rather than recreate it.
                                map[kind] = nil
                                continue
                            }
                            let was = snapshot[kind] ?? []
                            let currentSet = Set(current.map { $0.toInt64() })
                            var peers = data.includePeers.peers.filter { !(was.contains($0.toInt64()) && !currentSet.contains($0.toInt64())) }
                            for peerId in current where !was.contains(peerId.toInt64()) && !peers.contains(peerId) && peers.count < perFolder {
                                peers.append(peerId)
                            }
                            if peers.isEmpty {
                                // An empty folder is refused by Telegram; leave it as it is.
                                continue
                            }
                            filters[index] = self.folder(id: id, kind: kind, peers: peers, existing: data)
                        } else if !current.isEmpty {
                            // The first group or channel of a kind: its folder should not wait for a Refresh.
                            let count = filters.filter { self.filterId($0) != nil }.count
                            if count >= folderLimit {
                                continue
                            }
                            let id = engine.peers.generateNewChatListFilterId(filters: filters)
                            filters.append(self.folder(id: id, kind: kind, peers: Array(current.prefix(perFolder)), existing: nil))
                            map[kind] = id
                        }
                    }
                    outcome.map = map
                    return filters
                }
                |> map { _ -> Bool in
                    self.saveKindToFilter(outcome.map, accountPeerId)
                    var updatedSnapshot: [Kind: Set<Int64>] = [:]
                    for kind in Kind.allCases {
                        updatedSnapshot[kind] = Set((buckets[kind] ?? []).map { $0.toInt64() })
                    }
                    self.saveSnapshot(updatedSnapshot, accountPeerId)
                    return true
                }
            }
        }
        |> deliverOnMainQueue).startStandalone(completed: {
            self.busy.remove(accountPeerId)
        })
    }

    // MARK: Remove

    /// Deletes the folders this feature made: the tracked ones, and any untracked folder carrying one of our
    /// titles (the marker keeps a folder the user named themselves out of it).
    public static func remove(context: AccountContext) -> Signal<Void, NoError> {
        let accountPeerId = context.account.peerId
        if self.busy.contains(accountPeerId) {
            return .complete()
        }
        self.busy.insert(accountPeerId)
        let ids = Set(self.kindToFilter(accountPeerId).values)
        var known = Set<String>()
        for kind in Kind.allCases {
            known.formUnion(kind.knownTitles)
        }
        return context.engine.peers.updateChatListFiltersInteractively { filters in
            return filters.filter { filter in
                guard let id = self.filterId(filter) else {
                    return true
                }
                if ids.contains(id) {
                    return false
                }
                if let text = self.folderTitleText(filter), known.contains(text) {
                    return false
                }
                return true
            }
        }
        |> map { _ -> Void in
            self.saveKindToFilter([:], accountPeerId)
            self.defaults.removeObject(forKey: self.snapshotKey(accountPeerId))
            return Void()
        }
        |> deliverOnMainQueue
        |> afterDisposed {
            Queue.mainQueue().async {
                self.busy.remove(accountPeerId)
            }
        }
    }
}
