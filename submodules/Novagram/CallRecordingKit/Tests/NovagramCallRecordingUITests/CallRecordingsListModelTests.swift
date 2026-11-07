// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import NovagramCallRecordingCore
@testable import NovagramCallRecordingUI

@available(macOS 14, iOS 15, *)
final class CallRecordingsListModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return self.calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func recording(_ name: String, _ date: Date, isVideo: Bool, size: Int64 = 1000, duration: Double = 40) -> CallRecording {
        return CallRecording(url: URL(fileURLWithPath: "/tmp/\(name).\(isVideo ? "mp4" : "m4a")"), date: date, duration: duration, isVideo: isVideo, size: size)
    }

    private var sample: [CallRecording] {
        return [
            self.recording("Dilshod Rahimov 2026-10-29 19.05", self.date(2026, 10, 29, 19, 5), isVideo: false),
            self.recording("Jasur Karimov 2026-10-30 10.15", self.date(2026, 10, 30, 10, 15), isVideo: false),
            self.recording("Aziza Nurmatova 2026-10-26 09.30", self.date(2026, 10, 26, 9, 30), isVideo: true),
            self.recording("Malika Tosheva 2026-10-30 08.42", self.date(2026, 10, 30, 8, 42), isVideo: true)
        ]
    }

    func testSectionsAreDaysNewestFirst() {
        let sections = CallRecordingsListModel.sections(for: self.sample, filter: .all, calendar: self.calendar)
        XCTAssertEqual(sections.map(\.day), [self.date(2026, 10, 30, 0, 0), self.date(2026, 10, 29, 0, 0), self.date(2026, 10, 26, 0, 0)])
        XCTAssertEqual(sections.map { $0.recordings.map(\.peerName) }, [["Jasur Karimov", "Malika Tosheva"], ["Dilshod Rahimov"], ["Aziza Nurmatova"]])
    }

    func testFilterKeepsOnlyItsKind() {
        let video = CallRecordingsListModel.sections(for: self.sample, filter: .video, calendar: self.calendar)
        XCTAssertEqual(video.flatMap(\.recordings).map(\.peerName), ["Malika Tosheva", "Aziza Nurmatova"])
        let voice = CallRecordingsListModel.sections(for: self.sample, filter: .voice, calendar: self.calendar)
        XCTAssertEqual(voice.flatMap(\.recordings).map(\.peerName), ["Jasur Karimov", "Dilshod Rahimov"])
        XCTAssertEqual(voice.count, 2, "a day with no voice call disappears")
        XCTAssertEqual(CallRecordingsListModel.sections(for: [], filter: .all, calendar: self.calendar), [])
    }

    func testSummaryPlurals() {
        let size: (Int64) -> String = { "\($0) B" }
        let one = [self.sample[0]]
        let two = Array(self.sample.prefix(2))
        let english = CallRecordingStrings(languageCode: "en")
        XCTAssertEqual(CallRecordingsListModel.summary(for: one, filter: .all, strings: english, sizeString: size), "1 recording · 1000 B")
        XCTAssertEqual(CallRecordingsListModel.summary(for: two, filter: .all, strings: english, sizeString: size), "2 recordings · 2000 B")
        let russian = CallRecordingStrings(languageCode: "ru")
        XCTAssertEqual(russian.summary(1, "1 KB"), "1 запись · 1 KB")
        XCTAssertEqual(russian.summary(3, "1 KB"), "3 записи · 1 KB")
        XCTAssertEqual(russian.summary(5, "1 KB"), "5 записей · 1 KB")
        XCTAssertEqual(russian.summary(11, "1 KB"), "11 записей · 1 KB")
        XCTAssertEqual(russian.summary(21, "1 KB"), "21 запись · 1 KB")
        XCTAssertEqual(russian.summary(112, "1 KB"), "112 записей · 1 KB")
        XCTAssertEqual(CallRecordingStrings(languageCode: "uz").summary(4, "24,6 MB"), "4 ta yozuv · 24,6 MB")
        XCTAssertEqual(CallRecordingStrings(languageCode: "zh-hans").summary(4, "24.6 MB"), "4 条录音 · 24.6 MB")
    }

    func testSummaryWhenTheFilterHidesEverything() {
        let strings = CallRecordingStrings(languageCode: "en")
        XCTAssertEqual(CallRecordingsListModel.summary(for: [], filter: .video, strings: strings, sizeString: { "\($0)" }), "No video call recordings")
        XCTAssertEqual(CallRecordingsListModel.summary(for: [], filter: .voice, strings: strings, sizeString: { "\($0)" }), "No voice call recordings")
    }

    func testSubtitleAndHostOverride() {
        var strings = CallRecordingStrings(languageCode: "en")
        let recording = self.recording("Malika Tosheva 2026-10-30 08.42", self.date(2026, 10, 30, 8, 42), isVideo: true, size: 760_115, duration: 40)
        let size: (Int64) -> String = { CallRecordingFormatters.size($0, decimalSeparator: ",") }
        XCTAssertEqual(CallRecordingsListModel.subtitle(for: recording, strings: strings, durationString: CallRecordingFormatters.duration, sizeString: size), "Video call · 0:40 · 742,3 KB")
        strings.videoCall = "Videozvonok"
        XCTAssertEqual(CallRecordingsListModel.subtitle(for: recording, strings: strings, durationString: CallRecordingFormatters.duration, sizeString: size), "Videozvonok · 0:40 · 742,3 KB")
    }

    func testClearConfirmationFollowsTheFilter() {
        let strings = CallRecordingStrings(languageCode: "en")
        let visible = Array(self.sample.prefix(2))
        XCTAssertEqual(CallRecordingsListModel.clearConfirmation(for: visible, filter: .all, strings: strings, sizeString: { "\($0) B" }), "Delete all 2 recordings (2000 B)? This cannot be undone.")
        XCTAssertEqual(CallRecordingsListModel.clearConfirmation(for: [visible[0]], filter: .all, strings: strings, sizeString: { "\($0) B" }), "Delete 1 recording (1000 B)? This cannot be undone.")
        XCTAssertEqual(CallRecordingsListModel.clearConfirmation(for: visible, filter: .voice, strings: strings, sizeString: { "\($0) B" }), "Delete 2 voice call recordings (2000 B)? Recordings hidden by the filter are kept.")
        XCTAssertEqual(strings.deleteSelectedConfirm(3), "Delete 3 recordings?")
        XCTAssertEqual(strings.deleteSelectedButton(3), "Delete (3)")
    }

    func testFormatters() {
        XCTAssertEqual(CallRecordingFormatters.duration(40), "0:40")
        XCTAssertEqual(CallRecordingFormatters.duration(74.4), "1:14")
        XCTAssertEqual(CallRecordingFormatters.duration(3725), "1:02:05")
        XCTAssertEqual(CallRecordingFormatters.duration(-3), "0:00")
        XCTAssertEqual(CallRecordingFormatters.size(512, decimalSeparator: ","), "512 B")
        XCTAssertEqual(CallRecordingFormatters.size(2_726_297, decimalSeparator: ","), "2,6 MB")
        XCTAssertEqual(CallRecordingFormatters.size(1_288_490_189, decimalSeparator: "."), "1.2 GB")
    }

    func testDayHeaders() {
        let strings = CallRecordingStrings(languageCode: "en")
        let now = self.date(2026, 10, 30, 12, 0)
        XCTAssertEqual(CallRecordingFormatters.dayHeader(self.date(2026, 10, 30, 0, 0), strings: strings, calendar: self.calendar, now: now), "Today")
        XCTAssertEqual(CallRecordingFormatters.dayHeader(self.date(2026, 10, 29, 0, 0), strings: strings, calendar: self.calendar, now: now), "Yesterday")
        XCTAssertEqual(CallRecordingFormatters.dayHeader(self.date(2026, 10, 27, 0, 0), strings: strings, calendar: self.calendar, now: now), "October 27")
        XCTAssertEqual(CallRecordingFormatters.dayHeader(self.date(2025, 10, 27, 0, 0), strings: strings, calendar: self.calendar, now: now), "October 27, 2025")
        XCTAssertEqual(CallRecordingFormatters.dayHeader(self.date(2026, 10, 29, 0, 0), strings: CallRecordingStrings(languageCode: "uz"), calendar: self.calendar, now: now), "Kecha")
    }

    func testBuiltInLanguages() {
        XCTAssertEqual(CallRecordingStrings(languageCode: "ru").title, "Записи звонков")
        XCTAssertEqual(CallRecordingStrings(languageCode: "uz").clearAll, "Hammasini o'chirish")
        XCTAssertEqual(CallRecordingStrings(languageCode: "zh-hant").filterVideo, "视频通话")
        XCTAssertEqual(CallRecordingStrings(languageCode: "de").title, "Call recordings")
        XCTAssertEqual(CallRecordingStrings(languageCode: "uz").noticeFailed, "Suhbatdoshga xabar berib bo'lmadi, shuning uchun qo'ng'iroq yozilmayapti.")
        XCTAssertEqual(CallRecordingStrings(languageCode: "en").noticeMessage, "🔴 I'm recording this call (Novagram)")
        let environment = CallRecordingUIEnvironment(languageCode: "ru", onPlay: { _ in }, onShare: { _, _ in })
        XCTAssertEqual(environment.strings.language, .russian)
        XCTAssertEqual(environment.durationString(40), "0:40")
        XCTAssertEqual(CallRecordingFilter.video.title(environment.strings), "Видеозвонки")
    }

    @MainActor
    func testViewModelLoadsFiltersAndDeletes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("call-recording-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let video = folder.appendingPathComponent("Ali 2026-10-30 14.05.mp4")
        let voice = folder.appendingPathComponent("Vali 2026-10-30 14.06.m4a")
        try Data([1, 2]).write(to: video)
        try Data([1]).write(to: voice)
        let model = CallRecordingsListViewModel(storage: CallRecordingStorage(directory: folder))
        XCTAssertFalse(model.isLoaded)
        await model.reload()
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(Set(model.recordings.map(\.peerName)), ["Ali", "Vali"])
        model.filter = .voice
        XCTAssertEqual(model.visibleRecordings.map(\.peerName), ["Vali"])
        XCTAssertEqual(model.delete([voice]).map(\.lastPathComponent), [voice.lastPathComponent])
        XCTAssertTrue(model.visibleRecordings.isEmpty)
        XCTAssertEqual(model.recordings.map(\.peerName), ["Ali"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: voice.path))
    }

    @MainActor
    func testViewModelSelectModeForAHostDrawnToolbar() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("call-recording-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let video = folder.appendingPathComponent("Ali 2026-10-30 14.05.mp4")
        let voice = folder.appendingPathComponent("Vali 2026-10-30 14.06.m4a")
        try Data([1, 2]).write(to: video)
        try Data([1]).write(to: voice)
        let model = CallRecordingsListViewModel(storage: CallRecordingStorage(directory: folder))
        await model.reload()
        XCTAssertFalse(model.isSelecting)
        model.setSelecting(true)
        XCTAssertTrue(model.isSelecting)
        XCTAssertFalse(model.allVisibleSelected)
        model.toggleSelectAll()
        XCTAssertTrue(model.allVisibleSelected)
        XCTAssertEqual(Set(model.selectedURLs.map(\.lastPathComponent)), [video.lastPathComponent, voice.lastPathComponent])
        // A filter drops the rows it hides from the selection.
        model.filter = .video
        XCTAssertEqual(model.selectedURLs.map(\.lastPathComponent), [video.lastPathComponent])
        XCTAssertTrue(model.allVisibleSelected)
        model.toggleSelectAll()
        XCTAssertTrue(model.selection.isEmpty)
        var clearAllRequests = 0
        let cancellable = model.clearAllRequests.sink { clearAllRequests += 1 }
        model.requestClearAll()
        XCTAssertEqual(clearAllRequests, 1)
        cancellable.cancel()
        var deleteSelectedRequests = 0
        let deleteCancellable = model.deleteSelectedRequests.sink { deleteSelectedRequests += 1 }
        model.requestDeleteSelected()
        XCTAssertEqual(deleteSelectedRequests, 1)
        deleteCancellable.cancel()
        model.setSelecting(false)
        XCTAssertFalse(model.isSelecting)
        XCTAssertTrue(model.selection.isEmpty)
    }

    @MainActor
    func testEnvironmentDefaultsKeepTheListsOwnBarAndAlert() {
        var environment = CallRecordingUIEnvironment(onPlay: { _ in }, onShare: { _, _ in })
        XCTAssertTrue(environment.showsToolbar)
        XCTAssertTrue(environment.showsSelectionBar)
        XCTAssertNil(environment.confirmDeletion)
        XCTAssertEqual(environment.theme.listSideInset, 16)
        var asked: [String] = []
        environment.confirmDeletion = { text, confirm in
            asked.append(text)
            confirm()
        }
        environment.confirmDeletion?("Delete?") {
            asked.append("deleted")
        }
        XCTAssertEqual(asked, ["Delete?", "deleted"])
        XCTAssertEqual(CallRecordingTheme(listSideInset: 20).listSideInset, 20)
    }

    // One text on every platform: no device or platform names (App Review) and no "tap" / "click".
    func testTextsNameNoDeviceOrPlatform() {
        let strings = CallRecordingStrings(languageCode: "en")
        XCTAssertEqual(strings.emptyTextEnabled, "Recordings made with the Record button during a call appear here.")
        XCTAssertEqual(strings.emptyText, "Turn on Call recording, then use the Record button during a call.")
        XCTAssertEqual(strings.storageFooter, "Recordings are stored only on this device and are never uploaded.")
        let forbidden = try! NSRegularExpression(pattern: "\\b(iPhone|iPad|iPod|Mac|macOS|iOS|iPadOS|Apple|Android|tap|click)\\b", options: [.caseInsensitive])
        for code in ["en", "uz", "ru", "zh"] {
            let strings = CallRecordingStrings(languageCode: code)
            let texts = [strings.title, strings.emptyTitle, strings.emptyText, strings.emptyTextEnabled, strings.storageFooter, strings.deleteConfirm, strings.noticeMessage, strings.noticeFailed, strings.summary(2, "1 MB"), strings.filterEmpty(true), strings.filterEmpty(false), strings.clearAllConfirm(2, "1 MB"), strings.clearFilteredConfirm(2, "1 MB", true)]
            for text in texts {
                XCTAssertNil(forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(code): \(text)")
            }
        }
    }
}
