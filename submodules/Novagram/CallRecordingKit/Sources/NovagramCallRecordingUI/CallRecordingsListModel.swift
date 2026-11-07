// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Combine
import NovagramCallRecordingCore

/// The toolbar menu's filter.
@available(macOS 14, iOS 15, *)
public enum CallRecordingFilter: String, CaseIterable, Sendable {
    case all
    case video
    case voice

    public func includes(_ recording: CallRecording) -> Bool {
        switch self {
        case .all:
            return true
        case .video:
            return recording.isVideo
        case .voice:
            return !recording.isVideo
        }
    }

    public func title(_ strings: CallRecordingStrings) -> String {
        switch self {
        case .all:
            return strings.filterAll
        case .video:
            return strings.filterVideo
        case .voice:
            return strings.filterVoice
        }
    }
}

/// The recordings of one calendar day, newest first.
@available(macOS 14, iOS 15, *)
public struct CallRecordingDaySection: Identifiable, Equatable, Sendable {
    public let day: Date
    public var recordings: [CallRecording]

    public var id: Date {
        return self.day
    }
}

/// The list's pure rules: day sections, filtering, the summary line and the row subtitle.
@available(macOS 14, iOS 15, *)
public enum CallRecordingsListModel {
    /// The recordings `filter` shows, grouped by calendar day, newest day and newest recording first.
    public static func sections(for recordings: [CallRecording], filter: CallRecordingFilter, calendar: Calendar = .current) -> [CallRecordingDaySection] {
        let visible = recordings.filter(filter.includes).sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        var result: [CallRecordingDaySection] = []
        for recording in visible {
            let day = calendar.startOfDay(for: recording.date)
            if let last = result.last, last.day == day {
                result[result.count - 1].recordings.append(recording)
            } else {
                result.append(CallRecordingDaySection(day: day, recordings: [recording]))
            }
        }
        return result
    }

    /// "5 recordings · 2,6 MB", or the filter's empty text when it hides everything.
    public static func summary(for visible: [CallRecording], filter: CallRecordingFilter, strings: CallRecordingStrings, sizeString: (Int64) -> String) -> String {
        guard !visible.isEmpty else {
            return strings.filterEmpty(filter == .video)
        }
        let totalSize = visible.reduce(Int64(0)) { $0 + $1.size }
        return strings.summary(visible.count, sizeString(totalSize))
    }

    /// "Video call · 0:40 · 742,3 KB".
    public static func subtitle(for recording: CallRecording, strings: CallRecordingStrings, durationString: (Double) -> String, sizeString: (Int64) -> String) -> String {
        let kind = recording.isVideo ? strings.videoCall : strings.voiceCall
        return "\(kind) · \(durationString(recording.duration)) · \(sizeString(recording.size))"
    }

    /// The Clear All question: every recording, or only those the filter shows.
    public static func clearConfirmation(for visible: [CallRecording], filter: CallRecordingFilter, strings: CallRecordingStrings, sizeString: (Int64) -> String) -> String {
        let size = sizeString(visible.reduce(Int64(0)) { $0 + $1.size })
        switch filter {
        case .all:
            return strings.clearAllConfirm(visible.count, size)
        case .video, .voice:
            return strings.clearFilteredConfirm(visible.count, size, filter == .video)
        }
    }
}

/// The list's state: the recordings in the folder and the filter. Loads off the main thread.
@available(macOS 14, iOS 15, *)
@MainActor
public final class CallRecordingsListViewModel: ObservableObject {
    public let storage: CallRecordingStorage
    @Published public private(set) var recordings: [CallRecording] = []
    @Published public private(set) var isLoaded = false
    /// Kept for the screen's lifetime only. Rows the filter hides are not selected any more.
    @Published public var filter: CallRecordingFilter = .all {
        didSet {
            self.selection.formIntersection(self.visibleRecordings.map(\.url))
        }
    }
    /// Select mode (iOS). The list's own toolbar drives it; a host that draws its own navigation bar
    /// (``CallRecordingUIEnvironment/showsToolbar`` off) drives it with ``setSelecting(_:)`` and ``toggleSelectAll()``.
    @Published public private(set) var isSelecting = false
    /// The selected files while ``isSelecting``.
    @Published public var selection = Set<URL>()

    // requestClearAll(): the list asks for confirmation, then deletes.
    let clearAllRequests = PassthroughSubject<Void, Never>()
    // requestDeleteSelected(): the same, for the selection.
    let deleteSelectedRequests = PassthroughSubject<Void, Never>()

    public init(storage: CallRecordingStorage) {
        self.storage = storage
    }

    /// Turns select mode on or off; either way nothing is selected.
    public func setSelecting(_ isSelecting: Bool) {
        self.isSelecting = isSelecting
        self.selection.removeAll()
    }

    /// The selection in list order, so a share sheet shows the files as the list does.
    public var selectedURLs: [URL] {
        return self.visibleRecordings.map(\.url).filter { self.selection.contains($0) }
    }

    /// Every visible recording is selected.
    public var allVisibleSelected: Bool {
        let visible = self.visibleRecordings
        return !visible.isEmpty && visible.allSatisfy { self.selection.contains($0.url) }
    }

    /// Select All, or Deselect All when everything visible is selected.
    public func toggleSelectAll() {
        if self.allVisibleSelected {
            self.selection.removeAll()
        } else {
            self.selection = Set(self.visibleRecordings.map(\.url))
        }
    }

    /// The menu's Clear All from a host-drawn navigation bar: the list shows the same confirmation as its own menu.
    public func requestClearAll() {
        self.clearAllRequests.send(())
    }

    /// Delete from a host-drawn selection bar (``CallRecordingUIEnvironment/showsSelectionBar`` off): the list asks
    /// for confirmation, deletes the selected files and leaves select mode when nothing is left.
    public func requestDeleteSelected() {
        self.deleteSelectedRequests.send(())
    }

    public var visibleRecordings: [CallRecording] {
        return self.recordings.filter(self.filter.includes)
    }

    public func sections(calendar: Calendar = .current) -> [CallRecordingDaySection] {
        return CallRecordingsListModel.sections(for: self.recordings, filter: self.filter, calendar: calendar)
    }

    /// Reads the folder again (call it after a recording is saved).
    public func reload() async {
        let storage = self.storage
        let list = await Task.detached(priority: .userInitiated) {
            storage.list()
        }.value
        self.recordings = list
        self.isLoaded = true
    }

    /// Deletes the files and returns the ones that are gone; a file that could not be deleted stays in the list.
    @discardableResult
    public func delete(_ urls: [URL]) -> [URL] {
        let deleted = self.storage.delete(urls)
        let gone = Set(deleted.map(CallRecordingsListViewModel.fileKey))
        self.recordings.removeAll { gone.contains(CallRecordingsListViewModel.fileKey($0.url)) }
        return deleted
    }

    // The same file can be spelled /var/... or /private/var/...; compare the resolved folder plus the name.
    private static func fileKey(_ url: URL) -> String {
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }
}
