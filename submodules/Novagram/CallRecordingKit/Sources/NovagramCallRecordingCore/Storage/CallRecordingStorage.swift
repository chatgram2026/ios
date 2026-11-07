// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AVFoundation

/// One finished recording in the folder.
public struct CallRecording: Equatable, Hashable, Identifiable, Sendable {
    public let url: URL
    public let date: Date
    /// Seconds; 0 when it could not be measured.
    public let duration: Double
    /// `.mp4` (video) or `.m4a` (voice only).
    public let isVideo: Bool
    /// Bytes.
    public let size: Int64

    public init(url: URL, date: Date, duration: Double, isVideo: Bool, size: Int64) {
        self.url = url
        self.date = date
        self.duration = duration
        self.isVideo = isVideo
        self.size = size
    }

    public var id: URL {
        return self.url
    }

    /// The other person's name, read back from the file name.
    public var peerName: String {
        return CallRecordingName.peerName(fromFileName: self.url.deletingPathExtension().lastPathComponent)
    }
}

/// The recordings folder. The default is `<container>/Library/Application Support/CallRecordings`; each app may
/// inject its own folder.
///
/// A recording is written into `.partial/<uuid>/<final name>` and moved into the folder once it is finished, so a
/// recording cut short by the app being killed (its movie fragments keep it playable) is moved in on the next launch.
public struct CallRecordingStorage: Sendable, Equatable {
    public static let folderName = "CallRecordings"
    static let partialFolderName = ".partial"
    static let videoExtension = "mp4"
    static let audioExtension = "m4a"
    static let fallbackName = "Chitgram call"
    static let dateFormat = "yyyy-MM-dd HH.mm"
    static let durationAttributeName = "uz.novagram.callrecording.duration"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/CallRecordings` of this process's container.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(CallRecordingStorage.folderName, isDirectory: true)
    }

    public static var `default`: CallRecordingStorage {
        return CallRecordingStorage(directory: CallRecordingStorage.defaultDirectory)
    }

    var partialDirectory: URL {
        return self.directory.appendingPathComponent(CallRecordingStorage.partialFolderName, isDirectory: true)
    }

    /// "<peer> yyyy-MM-dd HH.mm.mp4", with " 2", " 3", ... when that name is taken. Slashes and colons become dashes;
    /// an empty name becomes "Chitgram call".
    public func fileName(peerName: String, date: Date, isVideo: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = CallRecordingStorage.dateFormat
        let cleaned = peerName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? CallRecordingStorage.fallbackName : cleaned
        let base = "\(name) \(formatter.string(from: date))"
        let fileExtension = isVideo ? CallRecordingStorage.videoExtension : CallRecordingStorage.audioExtension
        return CallRecordingStorage.uniqueURL(in: self.directory, fileName: "\(base).\(fileExtension)").lastPathComponent
    }

    // "<name>.mp4", then "<name> 2.mp4", "<name> 3.mp4", ...
    static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(index).\(fileExtension)")
            index += 1
        }
        return candidate
    }

    /// Every recording, newest first. The first call in a process also moves in what a killed app left unfinished.
    /// Files without a stored duration are measured once, so call it off the main thread.
    public func list() -> [CallRecording] {
        self.recoverInterruptedOnce()
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [CallRecording] = []
        for url in urls {
            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == CallRecordingStorage.videoExtension || fileExtension == CallRecordingStorage.audioExtension else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let date = values.creationDate ?? values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            result.append(CallRecording(url: url, date: date, duration: CallRecordingStorage.duration(of: url), isVideo: fileExtension == CallRecordingStorage.videoExtension, size: Int64(values.fileSize ?? 0)))
        }
        result.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        return result
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes what it can and returns the files that are gone. A file that could not be deleted is left out.
    @discardableResult
    public func delete(_ urls: [URL]) -> [URL] {
        return urls.filter { url in
            (try? FileManager.default.removeItem(at: url)) != nil
        }
    }

    // Moves a finished file into the folder under a free name and removes its partial folder.
    func moveIntoPlace(_ tempURL: URL, duration: Double?) throws -> URL {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let destination = CallRecordingStorage.uniqueURL(in: self.directory, fileName: tempURL.lastPathComponent)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        if let duration {
            CallRecordingStorage.storeDuration(duration, of: destination)
        }
        return destination
    }

    /// Moves every recording left in `.partial` by a killed app into the folder. Never call it while recording into
    /// this folder; ``list()`` and ``CallRecordingCenter`` call it once per process for you.
    public func recoverInterrupted() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: self.partialDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            let files = (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 {
                    _ = try? self.moveIntoPlace(file, duration: nil)
                }
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // Recovers each folder once per process, before any recording of this process starts in it.
    func recoverInterruptedOnce() {
        if CallRecordingRecoveredFolders.shared.markRecovered(self.directory) {
            self.recoverInterrupted()
        }
    }

    // The recorder stores the duration in an extended attribute; files without it are measured once by reading
    // their audio track.
    static func duration(of url: URL) -> Double {
        if let stored = CallRecordingStorage.storedDuration(of: url) {
            return stored
        }
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return 0
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        CallRecordingStorage.storeDuration(duration, of: url)
        return duration
    }

    static func storeDuration(_ duration: Double, of url: URL) {
        var bits = duration.bitPattern.littleEndian
        _ = withUnsafeBytes(of: &bits) { raw in
            setxattr(url.path, CallRecordingStorage.durationAttributeName, raw.baseAddress, raw.count, 0, 0)
        }
    }

    static func storedDuration(of url: URL) -> Double? {
        var bits: UInt64 = 0
        let size = withUnsafeMutableBytes(of: &bits) { raw in
            getxattr(url.path, CallRecordingStorage.durationAttributeName, raw.baseAddress, raw.count, 0, 0)
        }
        guard size == MemoryLayout<UInt64>.size else {
            return nil
        }
        let value = Double(bitPattern: UInt64(littleEndian: bits))
        return value.isFinite && value >= 0 ? value : nil
    }
}

// The folders already recovered in this process.
final class CallRecordingRecoveredFolders: @unchecked Sendable {
    static let shared = CallRecordingRecoveredFolders()

    private let lock = NSLock()
    private var paths = Set<String>()

    // True the first time a folder is seen.
    func markRecovered(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.paths.insert(path).inserted
    }
}
