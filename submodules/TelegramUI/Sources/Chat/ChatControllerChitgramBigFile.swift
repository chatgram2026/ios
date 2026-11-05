import Foundation
import UIKit
import QuickLook
import Display
import AccountContext
import SwiftSignalKit
import UndoUI
import TelegramCore
import OverlayStatusController
import ICloudResources
import ChitgramCore

/// Chitgram: no upload size limit (Android `BigFile`). Telegram takes at most 2 GB in one upload (4 GB with Telegram
/// Premium), and the server enforces it, so a bigger file goes out as numbered parts in one album, named the way 7-Zip
/// names volumes (video.mp4.001, video.mp4.002). In Chitgram, tapping any part fetches the rest and opens the whole
/// file; anywhere else 7-Zip joins them (so do `copy /b` and `cat`: the parts are plain byte ranges).
private let chitgramBigFileMaxParts = 10
private let chitgramBigFileUploadPart: Int64 = 512 * 1024
/// Kept free on top of what a split or a join needs, so it never fills the phone up completely.
private let chitgramBigFileReserve: Int64 = 64 * 1024 * 1024
private let chitgramBigFileCopyStep = 8 * 1024 * 1024

/// "video.mp4.002" → ("video.mp4", 2, file); nil for anything that isn't a numbered part.
private func chitgramSplitPart(_ message: EngineMessage) -> (base: String, number: Int, file: TelegramMediaFile)? {
    guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile, let name = file.fileName else {
        return nil
    }
    let nsName = name as NSString
    let suffix = nsName.pathExtension
    guard suffix.count == 3, suffix.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(suffix), number >= 1 else {
        return nil
    }
    let base = nsName.deletingPathExtension
    if base.isEmpty {
        return nil
    }
    return (base, number, file)
}

private func chitgramFreeSpace(at path: String) -> Int64 {
    let url = URL(fileURLWithPath: path)
    if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let capacity = values.volumeAvailableCapacityForImportantUsage {
        return capacity
    }
    return Int64.max
}

private func chitgramSizeString(_ size: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

/// Shows a joined file with the system viewer.
private final class ChitgramQuickLookSource: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return self.url as NSURL
    }
}

private var chitgramQuickLookSourceKey: UInt8 = 0

extension ChatControllerImpl {
    // MARK: Sending

    /// A picked file over this account's upload limit: sent in parts when it fits in one album. False leaves it to
    /// Telegram's own "file too large" screen.
    func chitgramSendSplitFile(item: ICloudFileDescription, maxUploadParts: Int32) -> Bool {
        let partSize = Int64(maxUploadParts) * chitgramBigFileUploadPart - 4 * chitgramBigFileUploadPart
        let size = Int64(item.fileSize)
        guard partSize > 0 else {
            return false
        }
        let count = Int((size + partSize - 1) / partSize)
        guard count >= 2, count <= chitgramBigFileMaxParts, let bookmark = Data(base64Encoded: item.urlData) else {
            return false
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
            return false
        }
        let temporaryDirectory = NSTemporaryDirectory()
        let free = chitgramFreeSpace(at: temporaryDirectory)
        if free < size + chitgramBigFileReserve {
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.format(586, chitgramSizeString(size + chitgramBigFileReserve - free)), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            return true
        }

        let status = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: nil))
        self.present(status, in: .window(.root))
        let fileName = item.fileName
        let threadId = self.chatLocation.threadId
        let replyToMessageId = self.presentationInterfaceState.interfaceState.replyMessageSubject?.subjectModel

        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = url.startAccessingSecurityScopedResource()
            var paths: [(path: String, size: Int64)] = []
            var failed = false
            do {
                let input = try FileHandle(forReadingFrom: url)
                for index in 0 ..< count {
                    let offset = Int64(index) * partSize
                    let length = min(partSize, size - offset)
                    let path = temporaryDirectory + "chitgram-split-\(Int64.random(in: 1 ... Int64.max))"
                    FileManager.default.createFile(atPath: path, contents: nil)
                    paths.append((path, length))
                    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    try input.seek(toOffset: UInt64(offset))
                    var remaining = length
                    while remaining > 0 {
                        let step = Int(min(remaining, Int64(chitgramBigFileCopyStep)))
                        let read: Int = try autoreleasepool {
                            guard let data = try input.read(upToCount: step), !data.isEmpty else {
                                return 0
                            }
                            try output.write(contentsOf: data)
                            return data.count
                        }
                        if read == 0 {
                            break
                        }
                        remaining -= Int64(read)
                    }
                    try output.close()
                    if remaining != 0 {
                        failed = true
                        break
                    }
                }
                try input.close()
            } catch {
                failed = true
            }
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
            if failed {
                for part in paths {
                    let _ = try? FileManager.default.removeItem(atPath: part.path)
                }
            }
            let didFail = failed
            let parts = paths

            DispatchQueue.main.async { [weak self] in
                status.dismiss()
                guard let self else {
                    return
                }
                if didFail {
                    self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(587), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                    return
                }
                let groupingKey = Int64.random(in: Int64.min ... Int64.max)
                let caption = ChitgramStrings.format(583, fileName, chitgramSizeString(size), count)
                var messages: [EnqueueMessage] = []
                for (index, part) in parts.enumerated() {
                    let name = fileName + "." + String(format: "%03d", index + 1)
                    let resource = LocalFileReferenceMediaResource(localFilePath: part.path, randomId: Int64.random(in: Int64.min ... Int64.max), isUniquelyReferencedTemporaryFile: true, size: part.size)
                    let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/octet-stream", size: part.size, attributes: [.FileName(fileName: name)], alternativeRepresentations: [])
                    messages.append(.message(text: index == 0 ? caption : "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: threadId, replyToMessageId: index == 0 ? replyToMessageId : nil, replyToStoryId: nil, localGroupingKey: groupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                }
                self.sendMessages(messages)
                self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.format(588, count), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            }
        }
        return true
    }

    // MARK: Opening

    /// A tap on a file in the chat. When it is one part of a split file this opens the whole file, fetching and joining
    /// the parts first if needed, and returns true. Anything else returns false and opens the usual way.
    func chitgramOpenSplitFile(message: EngineMessage) -> Bool {
        guard let (base, _, _) = chitgramSplitPart(message) else {
            return false
        }
        // The parts of one album, or, for parts that came without one, the messages around it by the same sender.
        var byNumber: [Int: (message: EngineMessage, file: TelegramMediaFile)] = [:]
        for delta in -chitgramBigFileMaxParts * 2 ... chitgramBigFileMaxParts * 2 {
            let id = EngineMessage.Id(peerId: message.id.peerId, namespace: message.id.namespace, id: message.id.id + Int32(delta))
            let found: EngineMessage?
            if delta == 0 {
                found = message
            } else {
                found = self.chatDisplayNode.historyNode.messageInCurrentHistoryView(id)
            }
            guard let candidate = found else {
                continue
            }
            if let groupingKey = message.groupingKey, candidate.groupingKey != groupingKey {
                continue
            }
            if candidate.author?.id != message.author?.id {
                continue
            }
            if let part = chitgramSplitPart(candidate), part.base == base {
                byNumber[part.number] = (candidate, part.file)
            }
        }
        guard byNumber.count >= 2, byNumber.keys.min() == 1, byNumber.keys.max() == byNumber.count else {
            return false
        }
        let parts = (1 ... byNumber.count).compactMap { byNumber[$0] }

        let key = message.groupingKey.flatMap { String($0) } ?? String(parts[0].file.fileId.id)
        let directory = NSTemporaryDirectory() + "chitgram-joined/\(key)"
        let safeName = base.replacingOccurrences(of: "/", with: "_")
        let target = directory + "/" + (safeName.isEmpty ? "file" : safeName)
        let total = parts.reduce(Int64(0), { $0 + ($1.file.size ?? 0) })
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target), (attributes[.size] as? NSNumber)?.int64Value == total {
            self.chitgramShowJoinedFile(path: target)
            return true
        }

        let resources = self.context.engine.resources
        let paths = parts.map { part in
            resources.completedResourcePath(id: EngineMediaResource.Id(part.file.resource.id))
        }
        let missing = parts.enumerated().filter { paths[$0.offset] == nil }.map { $0.element }
        if !missing.isEmpty {
            for part in missing {
                let _ = messageMediaFileInteractiveFetched(context: self.context, message: part.message._asMessage(), file: part.file, userInitiated: true).startStandalone()
            }
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.format(584, parts.count - missing.count, parts.count), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            return true
        }

        let free = chitgramFreeSpace(at: NSTemporaryDirectory())
        if free < total + chitgramBigFileReserve {
            self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.format(586, chitgramSizeString(total + chitgramBigFileReserve - free)), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
            return true
        }

        let status = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: nil))
        self.present(status, in: .window(.root))
        let sources = paths.compactMap { $0 }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
                let partial = target + ".part"
                let _ = try? FileManager.default.removeItem(atPath: partial)
                FileManager.default.createFile(atPath: partial, contents: nil)
                let output = try FileHandle(forWritingTo: URL(fileURLWithPath: partial))
                for source in sources {
                    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
                    while true {
                        let read: Int = try autoreleasepool {
                            guard let data = try input.read(upToCount: chitgramBigFileCopyStep), !data.isEmpty else {
                                return 0
                            }
                            try output.write(contentsOf: data)
                            return data.count
                        }
                        if read == 0 {
                            break
                        }
                    }
                    try input.close()
                }
                try output.close()
                let _ = try? FileManager.default.removeItem(atPath: target)
                try FileManager.default.moveItem(atPath: partial, toPath: target)
            } catch {
                ok = false
            }
            let joined = ok
            DispatchQueue.main.async { [weak self] in
                status.dismiss()
                guard let self else {
                    return
                }
                if joined {
                    self.chitgramShowJoinedFile(path: target)
                } else {
                    self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: ChitgramStrings.get(587), timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                }
            }
        }
        return true
    }

    private func chitgramShowJoinedFile(path: String) {
        let url = URL(fileURLWithPath: path)
        let source = ChitgramQuickLookSource(url: url)
        let controller = QLPreviewController()
        controller.dataSource = source
        // The data source is weak: it lives as long as the preview.
        objc_setAssociatedObject(controller, &chitgramQuickLookSourceKey, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        self.context.sharedContext.applicationBindings.presentNativeController(controller)
    }
}
