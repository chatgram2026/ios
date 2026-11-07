// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AVFoundation
import Combine
import CoreVideo
import Metal
@testable import NovagramCallRecordingCore

// Stands in for the host's audio device: holds the session the test installs and onDetach removes.
@available(macOS 14, iOS 15, *)
private final class SessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CallRecordingSession?
    private(set) var detachCount = 0

    func set(_ session: CallRecordingSession?) {
        self.lock.lock()
        self.session = session
        if session == nil {
            self.detachCount += 1
        }
        self.lock.unlock()
    }

    var current: CallRecordingSession? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.session
    }
}

// Which video frames a test recording gets.
private enum VideoFeed {
    case none
    case wholeCall
    // Only from the middle of the call on, like a camera turned on in a voice call.
    case secondHalf
}

@available(macOS 14, iOS 15, *)
final class CallRecordingEndToEndTests: XCTestCase {
    private static let seconds = 3.0
    private static let chunkSeconds = 0.01

    private var folder: URL!
    private var storage: CallRecordingStorage!

    override func setUp() {
        super.setUp()
        self.folder = FileManager.default.temporaryDirectory.appendingPathComponent("call-recording-e2e-\(UUID().uuidString)", isDirectory: true)
        self.storage = CallRecordingStorage(directory: self.folder)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.folder)
        super.tearDown()
    }

    private static func makeNV12Frame() -> CallRecordingVideoFrame {
        let width = 640
        let height = 360
        let y = Data(repeating: 150, count: width * height)
        let uv = Data(repeating: 100, count: width * height / 2)
        return .nv12(y: y, strideY: width, uv: uv, strideUV: width, width: width, height: height, rotationQuarterTurns: 1)
    }

    private static func makeNativeFrame() -> CallRecordingVideoFrame? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 360, 640, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(buffer) * 640)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return .pixelBuffer(buffer, mirrorHorizontally: true)
    }

    // Feeds 10 ms chunks in real time from a background thread, like the audio device: 48 kHz playout and 16 kHz
    // microphone, plus a video frame on every third chunk (from `firstVideoChunk` on, when `withVideo`).
    private static func feed(_ holder: SessionHolder, withVideo: Bool, firstVideoChunk: Int = 0) async {
        let nv12 = CallRecordingEndToEndTests.makeNV12Frame()
        let native = CallRecordingEndToEndTests.makeNativeFrame()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                let chunkCount = Int(CallRecordingEndToEndTests.seconds / CallRecordingEndToEndTests.chunkSeconds)
                var playout = [Int16](repeating: 0, count: 480)
                var mic = [Int16](repeating: 0, count: 160)
                let start = Date()
                for chunk in 0 ..< chunkCount {
                    let deadline = start.addingTimeInterval(Double(chunk) * CallRecordingEndToEndTests.chunkSeconds)
                    let wait = deadline.timeIntervalSinceNow
                    if wait > 0 {
                        usleep(UInt32(wait * 1_000_000))
                    }
                    for index in 0 ..< playout.count {
                        let time = Double(chunk * 480 + index) / 48000
                        playout[index] = Int16(8000 * sin(2 * Double.pi * 440 * time))
                    }
                    for index in 0 ..< mic.count {
                        let time = Double(chunk * 160 + index) / 16000
                        mic[index] = Int16(6000 * sin(2 * Double.pi * 300 * time))
                    }
                    guard let session = holder.current else {
                        continue
                    }
                    playout.withUnsafeBufferPointer { buffer in
                        if let base = buffer.baseAddress {
                            session.audioTap.appendPCM(base, frames: 480, channels: 1, sampleRate: 48000, isPlayout: true)
                        }
                    }
                    mic.withUnsafeBufferPointer { buffer in
                        if let base = buffer.baseAddress {
                            session.audioTap.appendPCM(base, frames: 160, channels: 1, sampleRate: 16000, isPlayout: false)
                        }
                    }
                    if withVideo, chunk % 3 == 0, chunk >= firstVideoChunk {
                        session.appendVideoFrame(nv12, side: .remote)
                        if let native {
                            session.appendVideoFrame(native, side: .local)
                        }
                    }
                }
                continuation.resume()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    @MainActor
    private func record(video: VideoFeed, configuration: CallRecordingConfiguration? = nil) async throws -> URL {
        let center = CallRecordingCenter(storage: self.storage)
        let holder = SessionHolder()
        let callId = UUID()
        var isRecordingHistory: [Bool] = []
        let observation = center.$recordingStartDates.sink { dates in
            isRecordingHistory.append(dates[callId] != nil)
        }
        defer {
            observation.cancel()
        }

        let session = try center.start(callId: callId, peerName: "Test: Peer", configuration: configuration, onDetach: {
            holder.set(nil)
        })
        holder.set(session)
        XCTAssertTrue(center.isRecording(callId: callId))
        XCTAssertTrue(center.session(callId: callId) === session)
        XCTAssertThrowsError(try center.start(callId: callId, peerName: "Test: Peer"), "a second start for the same call is refused") { error in
            XCTAssertEqual(error as? CallRecordingError, .alreadyRecording)
        }

        let chunkCount = Int(CallRecordingEndToEndTests.seconds / CallRecordingEndToEndTests.chunkSeconds)
        switch video {
        case .none:
            await CallRecordingEndToEndTests.feed(holder, withVideo: false)
        case .wholeCall:
            await CallRecordingEndToEndTests.feed(holder, withVideo: true)
        case .secondHalf:
            await CallRecordingEndToEndTests.feed(holder, withVideo: true, firstVideoChunk: chunkCount / 2)
        }

        let result = await center.stop(callId: callId)
        XCTAssertNil(holder.current, "stop detaches the host")
        XCTAssertEqual(holder.detachCount, 1)
        XCTAssertFalse(center.isRecording(callId: callId))
        XCTAssertEqual(center.state(callId: callId), .idle)
        XCTAssertEqual(isRecordingHistory.first, false)
        XCTAssertTrue(isRecordingHistory.contains(true))
        XCTAssertEqual(isRecordingHistory.last, false)
        let url = try result.get()
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, self.folder.standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Test- Peer "))
        XCTAssertEqual(url.pathExtension, video == .none ? "m4a" : "mp4")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: self.storage.partialDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the partial folder is removed: \(leftovers)")
        return url
    }

    private static func checkAudioTrack(_ asset: AVURLAsset) async throws {
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        XCTAssertEqual(description.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(description.mSampleRate, 48000)
        XCTAssertEqual(description.mChannelsPerFrame, 2)
        let trackDuration = try await track.load(.timeRange).duration.seconds
        XCTAssertEqual(trackDuration, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
    }

    // RGB of one pixel, y counted from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        var pixels = [UInt8](repeating: 0, count: 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                return false
            }
            // Shift the image so the wanted pixel lands on the 1x1 bitmap.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? (pixels[0], pixels[1], pixels[2]) : nil
    }

    @MainActor
    func testVoiceRecordingWritesAacFile() async throws {
        let url = try await self.record(video: .none)
        let asset = AVURLAsset(url: url)
        try await CallRecordingEndToEndTests.checkAudioTrack(asset)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 0)

        let listed = self.storage.list().first { $0.url.standardizedFileURL == url.standardizedFileURL }
        XCTAssertNotNil(listed)
        XCTAssertEqual(listed?.isVideo, false)
        XCTAssertEqual(listed?.duration ?? 0, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
        XCTAssertGreaterThan(listed?.size ?? 0, 0)
        XCTAssertEqual(listed?.peerName, "Test- Peer")
    }

    @MainActor
    func testVideoRecordingWritesH264AndAacFile() async throws {
        let url = try await self.record(video: .wholeCall)
        let asset = AVURLAsset(url: url)
        try await CallRecordingEndToEndTests.checkAudioTrack(asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        let videoDuration = try await track.load(.timeRange).duration.seconds
        XCTAssertEqual(videoDuration, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertGreaterThan(frameRate, 20)
        XCTAssertLessThanOrEqual(frameRate, 31)

        let listed = self.storage.list().first { $0.url.standardizedFileURL == url.standardizedFileURL }
        XCTAssertEqual(listed?.isVideo, true)

        // Core Image renders nothing without a Metal device (some simulators and CI runners have none).
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }
        // The other side (green-grey NV12, 640x360 turned a quarter, so exactly the canvas's 9:16) fills the whole
        // frame, and our own video (neutral grey) sits in the top-right corner. These pixel checks only run where
        // Metal exists; the iOS test runner never reached them, so its old "black letterbox" corner was never true.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 1280)
        let center = try XCTUnwrap(self.pixel(image, x: 360, y: 640))
        XCTAssertGreaterThan(Int(center.1), Int(center.0) + 30, "the other side is green-grey: centre \(center)")
        let corner = try XCTUnwrap(self.pixel(image, x: 4, y: 4))
        XCTAssertGreaterThan(Int(corner.1), Int(corner.0) + 30, "the other side fills the frame: corner \(corner)")
        let pip = try XCTUnwrap(self.pixel(image, x: 720 - 24 - 100, y: 24 + 100))
        XCTAssertGreaterThan(Int(pip.0) + Int(pip.1) + Int(pip.2), 120, "picture-in-picture \(pip)")
        XCTAssertLessThan(abs(Int(pip.1) - Int(pip.0)), 20, "our own video is neutral grey: picture-in-picture \(pip)")
    }

    // Battery saver: frames still come at about 33 fps, the file has half as many.
    @MainActor
    func testBatterySaverWritesFifteenFramesPerSecond() async throws {
        let url = try await self.record(video: .wholeCall, configuration: CallRecordingConfiguration(quality: .batterySaver))
        let asset = AVURLAsset(url: url)
        try await CallRecordingEndToEndTests.checkAudioTrack(asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertGreaterThan(frameRate, 12)
        XCTAssertLessThanOrEqual(frameRate, 16)
        let videoDuration = try await track.load(.timeRange).duration.seconds
        XCTAssertEqual(videoDuration, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
    }

    // A voice recording that gets video halfway (camera turned on): one .mp4 for the whole call, its video track
    // from zero (black until the first frame) to the end.
    @MainActor
    func testVideoTurnedOnHalfwayKeepsWholeCallInMp4() async throws {
        let url = try await self.record(video: .secondHalf)
        let asset = AVURLAsset(url: url)
        try await CallRecordingEndToEndTests.checkAudioTrack(asset)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let timeRange = try await track.load(.timeRange)
        XCTAssertEqual(timeRange.start.seconds, 0, accuracy: 0.05)
        XCTAssertEqual(timeRange.duration.seconds, CallRecordingEndToEndTests.seconds, accuracy: 0.6)
        let listed = self.storage.list().first { $0.url.standardizedFileURL == url.standardizedFileURL }
        XCTAssertEqual(listed?.isVideo, true)
        XCTAssertEqual(listed?.duration ?? 0, CallRecordingEndToEndTests.seconds, accuracy: 0.3)
    }

    @MainActor
    func testStopWithoutRecordingIsCancelled() async {
        let center = CallRecordingCenter(storage: self.storage)
        let result = await center.stop(callId: UUID())
        XCTAssertEqual(result, .failure(.cancelled))
    }

    @MainActor
    func testStopBeforeAnyAudioReportsNothingRecorded() async throws {
        let center = CallRecordingCenter(storage: self.storage)
        let holder = SessionHolder()
        let callId = UUID()
        holder.set(try center.start(callId: callId, peerName: "Empty", onDetach: {
            holder.set(nil)
        }))
        let result = await center.stop(callId: callId)
        XCTAssertEqual(holder.detachCount, 1)
        XCTAssertEqual(result, .failure(.nothingRecorded))
        XCTAssertEqual(self.storage.list(), [])
    }

    @MainActor
    func testStateUpdatesFollowStartAndStop() async throws {
        let center = CallRecordingCenter(storage: self.storage)
        let callId = UUID()
        var iterator = center.stateUpdates(callId: callId).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .idle)
        let session = try center.start(callId: callId, peerName: "State")
        center.setMuted(callId: callId, isMuted: true)
        center.setLayout(callId: callId, pipCorner: .bottomLeft, isSwapped: true)
        session.setMuted(false)
        let second = await iterator.next()
        if case .recording = second {
        } else {
            XCTFail("expected recording, got \(String(describing: second))")
        }
        _ = await center.stop(callId: callId)
        let third = await iterator.next()
        XCTAssertEqual(third, .idle)
    }

    @MainActor
    func testStopAllFinishesEveryRecording() async throws {
        let center = CallRecordingCenter(storage: self.storage)
        let holder = SessionHolder()
        holder.set(try center.start(callId: UUID(), peerName: "One", onDetach: {
            holder.set(nil)
        }))
        _ = try center.start(callId: UUID(), peerName: "Two")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.stopAll(timeout: 5) {
                continuation.resume()
            }
        }
        XCTAssertEqual(holder.detachCount, 1)
        XCTAssertTrue(center.recordingStartDates.isEmpty)
    }
}
