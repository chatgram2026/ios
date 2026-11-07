// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import NovagramCallRecordingCore

@available(macOS 14, iOS 15, *)
final class CallRecordingStorageTests: XCTestCase {
    private var folder: URL!
    private var storage: CallRecordingStorage!

    override func setUp() {
        super.setUp()
        self.folder = FileManager.default.temporaryDirectory.appendingPathComponent("call-recording-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        self.storage = CallRecordingStorage(directory: self.folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.folder)
        super.tearDown()
    }

    private func date() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 30
        components.hour = 14
        components.minute = 5
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    func testFileNameSanitizesSlashesAndColons() {
        XCTAssertEqual(self.storage.fileName(peerName: " A/B: C ", date: self.date(), isVideo: true), "A-B- C 2026-10-30 14.05.mp4")
        XCTAssertEqual(self.storage.fileName(peerName: "Ali", date: self.date(), isVideo: false), "Ali 2026-10-30 14.05.m4a")
        XCTAssertEqual(self.storage.fileName(peerName: "   ", date: self.date(), isVideo: false), "Novagram call 2026-10-30 14.05.m4a")
    }

    func testFileNameAppendsNumberWhenTaken() throws {
        let first = self.storage.fileName(peerName: "Ali", date: self.date(), isVideo: true)
        XCTAssertEqual(first, "Ali 2026-10-30 14.05.mp4")
        try Data([1]).write(to: self.folder.appendingPathComponent(first))
        let second = self.storage.fileName(peerName: "Ali", date: self.date(), isVideo: true)
        XCTAssertEqual(second, "Ali 2026-10-30 14.05 2.mp4")
        try Data([1]).write(to: self.folder.appendingPathComponent(second))
        XCTAssertEqual(self.storage.fileName(peerName: "Ali", date: self.date(), isVideo: true), "Ali 2026-10-30 14.05 3.mp4")
        // The voice name is separate from the video one.
        XCTAssertEqual(self.storage.fileName(peerName: "Ali", date: self.date(), isVideo: false), "Ali 2026-10-30 14.05.m4a")
    }

    func testListIsNewestFirstAndSkipsOtherFiles() throws {
        let older = self.folder.appendingPathComponent("old.m4a")
        let newer = self.folder.appendingPathComponent("new.mp4")
        try Data([1, 2, 3]).write(to: older)
        try Data([1, 2, 3, 4]).write(to: newer)
        try Data([1]).write(to: self.folder.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: newer.path)
        CallRecordingStorage.storeDuration(12.5, of: newer)

        let list = self.storage.list()
        XCTAssertEqual(list.map { $0.url.lastPathComponent }, ["new.mp4", "old.m4a"])
        XCTAssertEqual(list.first?.isVideo, true)
        XCTAssertEqual(list.first?.duration, 12.5)
        XCTAssertEqual(list.first?.size, 4)
        XCTAssertEqual(list.last?.isVideo, false)
    }

    func testListOfMissingFolderIsEmpty() {
        let missing = CallRecordingStorage(directory: self.folder.appendingPathComponent("missing", isDirectory: true))
        XCTAssertEqual(missing.list(), [])
    }

    func testInterruptedRecordingIsMovedIntoFolder() throws {
        let partial = self.folder.appendingPathComponent(".partial/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: partial.appendingPathComponent("Ali 2026-10-30 14.05.mp4"))
        // An empty file (the app was killed before the first fragment) is dropped.
        let empty = self.folder.appendingPathComponent(".partial/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("Vali 2026-10-30 14.05.mp4"))
        self.storage.recoverInterrupted()
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("Ali 2026-10-30 14.05.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("Vali 2026-10-30 14.05.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testListRecoversOncePerFolder() throws {
        let partial = self.folder.appendingPathComponent(".partial/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: partial.appendingPathComponent("Ali 2026-10-30 14.05.mp4"))
        XCTAssertEqual(self.storage.list().map { $0.url.lastPathComponent }, ["Ali 2026-10-30 14.05.mp4"])
        // A second partial file appearing later (a recording in progress) is left alone.
        let later = self.folder.appendingPathComponent(".partial/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data([1]).write(to: later.appendingPathComponent("Vali 2026-10-30 14.06.mp4"))
        XCTAssertEqual(self.storage.list().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: later.path))
    }

    func testDeleteReturnsWhatIsGone() throws {
        let file = self.folder.appendingPathComponent("a.mp4")
        try Data([1]).write(to: file)
        let missing = self.folder.appendingPathComponent("missing.mp4")
        XCTAssertEqual(self.storage.delete([file, missing]), [file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRecordingNameIsParsedFromTheFileName() {
        XCTAssertEqual(CallRecordingName.peerName(fromFileName: "Jasur Karimov 2026-10-30 14.25"), "Jasur Karimov")
        XCTAssertEqual(CallRecordingName.peerName(fromFileName: "Jasur Karimov 2026-10-30 14.25 2"), "Jasur Karimov")
        XCTAssertEqual(CallRecordingName.peerName(fromFileName: "A-B- C 2026-10-30 14.05"), "A-B- C")
        XCTAssertEqual(CallRecordingName.peerName(fromFileName: "holiday clip"), "holiday clip")
        XCTAssertEqual(CallRecordingName.peerName(fromFileName: " 2026-10-30 14.25"), " 2026-10-30 14.25", "a stamp alone keeps the whole name")
        let recording = CallRecording(url: URL(fileURLWithPath: "/tmp/Malika Tosheva 2026-10-30 08.42.mp4"), date: Date(), duration: 40, isVideo: true, size: 1)
        XCTAssertEqual(recording.peerName, "Malika Tosheva")
    }

    func testInitialsAndStableColor() {
        XCTAssertEqual(CallRecordingName.initials(of: "Jasur Karimov Group"), "JK")
        XCTAssertEqual(CallRecordingName.initials(of: "ali"), "A")
        XCTAssertEqual(CallRecordingName.initials(of: "  "), "")
        let index = CallRecordingName.colorIndex(of: "Jasur Karimov", count: 7)
        XCTAssertEqual(index, CallRecordingName.colorIndex(of: "Jasur Karimov", count: 7))
        XCTAssertTrue((0 ..< 7).contains(index))
        XCTAssertEqual(CallRecordingName.colorIndex(of: "Jasur Karimov", count: 0), 0)
    }
}
