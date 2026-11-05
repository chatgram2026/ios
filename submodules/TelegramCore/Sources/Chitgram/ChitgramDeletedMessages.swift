import Foundation
import Postbox
import SwiftSignalKit
import ChitgramCore

/// Chitgram: a message someone else deleted that "Save deleted messages" kept (Android `DeletedMsg`). The message
/// stays in the history with this mark instead of being removed; the bubble shows "🗑 Deleted" next to its time.
///
/// It survives because the server never sends a deleted message again, so nothing overwrites the stored copy.
public final class ChitgramDeletedMessageAttribute: MessageAttribute {
    public enum DeletedBy: Int32 {
        /// The other side (or anyone in a group) deleted it. Android: `By.You`, string 110.
        case them = 0
        /// A channel removed its post. Android: `By.Channel`, string 111.
        case channel = 1
    }

    public let deletedBy: DeletedBy
    /// When this device learned of the deletion.
    public let date: Int32

    public init(deletedBy: DeletedBy, date: Int32) {
        self.deletedBy = deletedBy
        self.date = date
    }

    required public init(decoder: PostboxDecoder) {
        self.deletedBy = DeletedBy(rawValue: decoder.decodeInt32ForKey("b", orElse: 0)) ?? .them
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.deletedBy.rawValue, forKey: "b")
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

public extension Message {
    var chitgramDeletedAttribute: ChitgramDeletedMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? ChitgramDeletedMessageAttribute {
                return attribute
            }
        }
        return nil
    }
}

/// Keeps `id` instead of deleting it when the switch is on, or when it was kept before. Returns whether it stays.
///
/// Only messages that arrived or were sent for real are kept: a send still in flight or failed is deleted as usual,
/// otherwise a cancelled upload would linger as "deleted" forever (Android checks `send_state = 0` for the same reason).
func chitgramKeepsDeletedMessage(transaction: Transaction, id: MessageId) -> Bool {
    guard let message = transaction.getMessage(id) else {
        return false
    }
    if message.chitgramDeletedAttribute != nil {
        return true
    }
    if ChitgramPreferences.shared.int(.deletedCheckType) == ChitgramPreferences.DeletedCheckType.off.rawValue {
        return false
    }
    if message.flags.contains(.Unsent) || message.flags.contains(.Failed) || id.namespace != Namespaces.Message.Cloud {
        return false
    }
    let deletedBy: ChitgramDeletedMessageAttribute.DeletedBy
    if let channel = message.peers[id.peerId] as? TelegramChannel, case .broadcast = channel.info {
        deletedBy = .channel
    } else {
        deletedBy = .them
    }
    let date = Int32(Date().timeIntervalSince1970)
    transaction.updateMessage(id, update: { currentMessage in
        var attributes = currentMessage.attributes
        attributes.append(ChitgramDeletedMessageAttribute(deletedBy: deletedBy, date: date))
        return .update(StoreMessage(
            id: currentMessage.id,
            customStableId: nil,
            globallyUniqueId: currentMessage.globallyUniqueId,
            groupingKey: currentMessage.groupingKey,
            threadId: currentMessage.threadId,
            timestamp: currentMessage.timestamp,
            flags: StoreMessageFlags(currentMessage.flags),
            tags: currentMessage.tags,
            globalTags: currentMessage.globalTags,
            localTags: currentMessage.localTags,
            forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init),
            authorId: currentMessage.author?.id,
            text: currentMessage.text,
            attributes: attributes,
            media: currentMessage.media
        ))
    })
    return true
}

/// The ids of a server deletion that are really removed; the rest stay, marked.
func chitgramMessageIdsToDelete(transaction: Transaction, ids: [MessageId]) -> [MessageId] {
    return ids.filter { !chitgramKeepsDeletedMessage(transaction: transaction, id: $0) }
}

/// The same for a deletion addressed by global ids (private chats and basic groups).
func chitgramGlobalIdsToDelete(transaction: Transaction, globalIds: [Int32]) -> [Int32] {
    return globalIds.filter { globalId in
        guard let id = transaction.messageIdsForGlobalIds([globalId]).first else {
            return true
        }
        return !chitgramKeepsDeletedMessage(transaction: transaction, id: id)
    }
}

// MARK: - The files of kept messages (Android `ChitgramArchive` media, "archive_media")

/// Kept messages stay in the history, but their pictures, videos and files live in Telegram's cache, which "Clear
/// cache", the automatic cleanup and a full storage do empty. With the switch on, the files of a message someone
/// else deleted are copied into the account's own `chitgram-archive` folder, which nothing of Telegram's touches, and
/// put back into the cache whenever the cache has lost them (at launch and on every return to the app). Only files
/// already downloaded are copied: after a deletion the server no longer serves them.
private let chitgramArchiveQueue = Queue(name: "org.chitgram.archive")

/// Single files larger than this stay in the cache only (Android: the same 64 MB).
private let chitgramArchiveMaxFileBytes: Int64 = 64 * 1024 * 1024

/// When the copies outgrow this, the oldest go first (Android: the same 2 GB).
private let chitgramArchiveBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024

/// `<account>/chitgram-archive`, beside the account's `postbox` folder (the media box lives in `postbox/media`).
private func chitgramArchiveDirectory(mediaBox: MediaBox) -> String {
    let postboxPath = (mediaBox.basePath as NSString).deletingLastPathComponent
    let accountPath = (postboxPath as NSString).deletingLastPathComponent
    return accountPath + "/chitgram-archive"
}

/// A copy is named by its resource id in hex, so it maps back to the resource without an index file.
private func chitgramArchiveFileName(_ id: MediaResourceId) -> String? {
    let name = id.stringRepresentation.utf8.map { String(format: "%02x", $0) }.joined()
    return name.isEmpty || name.count > 240 ? nil : name
}

private func chitgramArchiveResourceId(fileName: String) -> MediaResourceId? {
    let characters = Array(fileName.utf8)
    if characters.isEmpty || characters.count % 2 != 0 {
        return nil
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(characters.count / 2)
    var index = 0
    while index < characters.count {
        guard let byte = UInt8(String(decoding: characters[index ..< index + 2], as: UTF8.self), radix: 16) else {
            return nil
        }
        bytes.append(byte)
        index += 2
    }
    guard let string = String(bytes: bytes, encoding: .utf8) else {
        return nil
    }
    return MediaResourceId(string)
}

private func chitgramArchiveFileSize(_ path: String) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
        return 0
    }
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

/// Copies the downloaded files of the messages that were just kept. Runs inside the deletion's transaction, so it
/// only looks the files up there; the copying happens on the archive queue.
func chitgramArchiveKeptMedia(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId]) {
    if ids.isEmpty || !ChitgramPreferences.shared.bool(.archiveMedia) {
        return
    }
    var resourceIds: [MediaResourceId] = []
    for id in ids {
        if let message = transaction.getMessage(id) {
            addMessageMediaResourceIdsToRemove(message: message, resourceIds: &resourceIds)
        }
    }
    var sources: [(name: String, path: String)] = []
    for resourceId in Set(resourceIds) {
        if let name = chitgramArchiveFileName(resourceId), let path = mediaBox.completedResourcePath(id: resourceId) {
            sources.append((name, path))
        }
    }
    if sources.isEmpty {
        return
    }
    let directory = chitgramArchiveDirectory(mediaBox: mediaBox)
    chitgramArchiveQueue.async {
        let fileManager = FileManager.default
        let _ = try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        var copied = false
        for source in sources {
            let size = chitgramArchiveFileSize(source.path)
            if size <= 0 || size > chitgramArchiveMaxFileBytes {
                continue
            }
            let target = directory + "/" + source.name
            if fileManager.fileExists(atPath: target) {
                continue
            }
            if let _ = try? fileManager.copyItem(atPath: source.path, toPath: target) {
                // A clone keeps the source's dates; the trim goes by when the copy was made.
                let _ = try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target)
                copied = true
            }
        }
        if copied {
            chitgramTrimArchive(directory: directory)
        }
    }
}

/// The ids of a deletion that were kept rather than deleted.
func chitgramKeptMessageIds(allIds: [MessageId], deletedIds: [MessageId]) -> [MessageId] {
    let deleted = Set(deletedIds)
    return allIds.filter { !deleted.contains($0) }
}

/// The same for a deletion addressed by global ids.
func chitgramKeptMessageIds(transaction: Transaction, allGlobalIds: [Int32], deletedGlobalIds: [Int32]) -> [MessageId] {
    let deleted = Set(deletedGlobalIds)
    return transaction.messageIdsForGlobalIds(allGlobalIds.filter { !deleted.contains($0) })
}

private func chitgramTrimArchive(directory: String) {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
        return
    }
    var files: [(path: String, size: Int64, date: Date)] = []
    var total: Int64 = 0
    for name in names {
        let path = directory + "/" + name
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            continue
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        files.append((path, size, (attributes[.modificationDate] as? Date) ?? Date.distantPast))
        total += size
    }
    if total <= chitgramArchiveBudgetBytes {
        return
    }
    files.sort(by: { $0.date < $1.date })
    for file in files {
        if total <= chitgramArchiveBudgetBytes {
            break
        }
        if let _ = try? fileManager.removeItem(atPath: file.path) {
            total -= file.size
        }
    }
}

/// Puts every copied file the cache no longer has back into it, so kept messages show their media again.
public func chitgramRestoreArchivedMedia(account: Account) {
    let mediaBox = account.postbox.mediaBox
    let directory = chitgramArchiveDirectory(mediaBox: mediaBox)
    chitgramArchiveQueue.async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        for name in names {
            guard let id = chitgramArchiveResourceId(fileName: name) else {
                continue
            }
            if mediaBox.completedResourcePath(id: id) == nil {
                mediaBox.copyResourceData(id, fromTempPath: directory + "/" + name)
            }
        }
    }
}

/// How many bytes the copies take (the settings row shows it, as on Android).
public func chitgramArchivedMediaSize(account: Account) -> Signal<Int64, NoError> {
    let directory = chitgramArchiveDirectory(mediaBox: account.postbox.mediaBox)
    return Signal { subscriber in
        chitgramArchiveQueue.async {
            var total: Int64 = 0
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                for name in names {
                    total += chitgramArchiveFileSize(directory + "/" + name)
                }
            }
            subscriber.putNext(total)
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
}
