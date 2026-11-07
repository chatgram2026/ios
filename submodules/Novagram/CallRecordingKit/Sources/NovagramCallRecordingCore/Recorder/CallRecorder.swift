// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AVFoundation
import CoreMedia
import CoreImage

// Records one call into an AVAssetWriter: one AAC track (both sides mixed) and one H.264 track. Every recording
// is written as an .mp4, so video turned on in the middle of a voice call is recorded too: while neither side has
// video the track gets a black frame every half second (almost nothing once compressed), at the first real frame
// it switches to the configured frame rate (up to 30 fps). A recording that never had a real frame is exported to an audio-only .m4a at the
// end (the .mp4 is kept if that export fails). Timeline: the session starts at the first audio chunk (time zero);
// audio times come from the sample count, video times from the host clock relative to the same start.
// All writer state lives on `queue`; the audio tap only writes into the two rings, and frames, mute and layout are
// handed to the queue. Sendable for that reason: every mutable field below is touched on `queue` only.
@available(macOS 14, iOS 15, *)
final class CallRecorder: @unchecked Sendable {
    static let sampleRate = CallRecordingAudioMixer.outputSampleRate
    static let tickInterval: Double = 1.0 / Double(CallRecordingConfiguration.maxFramesPerSecond)
    static let audioBitRate = 128_000
    // While neither side has video: one black frame per this many seconds.
    static let idleVideoFrameInterval: Double = 0.5
    // Seconds between key frames, whatever the frame rate.
    static let keyFrameIntervalSeconds = 2
    static let fragmentInterval: Double = 2.0
    // A playout chunk this much later than the timeline expects means chunks were lost or playout stalled; the
    // hole is filled with the microphone alone so audio stays in sync with the host clock.
    static let gapThreshold: Double = 0.12
    // Without playout chunks for this long, the timeline keeps moving with the microphone alone, `staleLag` behind.
    static let staleThreshold: Double = 0.3
    static let staleLag: Double = 0.15
    // Microphone chunks alone start the session after this long without any playout chunk.
    static let micOnlyStartDelay: Double = 0.4
    static let commitFrames = CallRecorder.sampleRate / 10
    static let maxSilenceFillFrames = CallRecorder.sampleRate
    static let maxPendingAudioFrames = CallRecorder.sampleRate * 3
    // A video side without a new frame for this long counts as having no video (camera turned off).
    static let videoSideTimeout: Double = 4.0
    static let finishRetryCount = 50
    static let finishRetryMicroseconds: UInt32 = 10_000

    let tempURL: URL
    let storage: CallRecordingStorage
    let audioTap: CallRecordingAudioTap
    let queue = DispatchQueue(label: "uz.novagram.call-recorder", qos: .userInitiated)
    // Told once, on the recorder queue, when the writer fails on its own.
    private let onFailure: @Sendable (CallRecorder, CallRecordingError) -> Void

    private let micRing = CallRecordingAudioRing()
    private let playoutRing = CallRecordingAudioRing()
    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private let canvas: CGRect
    // Seconds per video frame at the configured rate.
    private let frameInterval: Double

    // Recorder queue.
    private let mixer = CallRecordingAudioMixer()
    private var timer: DispatchSourceTimer?
    private var isMuted = false
    private var startSeconds: Double?
    private var firstMicSeconds: Double?
    private var lastPlayoutSeconds: Double?
    private var framesWritten: Int64 = 0
    private var mixBuffer: [Int16] = []
    private var pendingAudio: [(buffer: CMSampleBuffer, frames: Int)] = []
    private var pendingAudioFrames = 0
    private var compositor: CallRecordingVideoCompositor?
    private var remote = VideoSide()
    private var local = VideoSide()
    private var lastVideoTime: CMTime = .invalid
    private var layout: CallRecordingVideoLayout = .standard
    // Set by the first frame with a real picture on either side; without it the file ends up audio-only.
    private var hasRealVideo = false
    // The black frame written while neither side has video (one buffer, reused).
    private var blackBuffer: CVPixelBuffer?
    private var failure: CallRecordingError?
    private var isFinishing = false

    private struct VideoSide {
        let converter = CallRecordingVideoFrameConverter()
        var frame: CallRecordingVideoFrame?
        var frameSeconds: Double = 0
        var isDirty = false
        var image: CIImage?
    }

    init(tempURL: URL, storage: CallRecordingStorage, configuration: CallRecordingConfiguration, onFailure: @escaping @Sendable (CallRecorder, CallRecordingError) -> Void) throws {
        self.tempURL = tempURL
        self.storage = storage
        self.onFailure = onFailure
        self.canvas = configuration.canvas
        self.frameInterval = 1.0 / Double(configuration.framesPerSecond)
        self.audioTap = CallRecordingAudioTap(micRing: self.micRing, playoutRing: self.playoutRing)

        guard let audioFormat = CallRecorder.makeAudioFormat() else {
            throw CallRecordingError.writerFailed("audio format")
        }
        self.audioFormat = audioFormat
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        } catch {
            throw CallRecordingError.writerFailed(error.localizedDescription)
        }
        // Movie fragments keep the file playable up to the last fragment if the app is killed.
        writer.movieFragmentInterval = CMTime(seconds: CallRecorder.fragmentInterval, preferredTimescale: 600)

        let width = Int(configuration.videoSize.width)
        let height = Int(configuration.videoSize.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: CallRecorder.videoSettings(width: width, height: height, framesPerSecond: configuration.framesPerSecond, bitRate: configuration.videoBitRate))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CallRecordingError.writerFailed("video input")
        }
        writer.add(input)
        self.videoInput = input
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: CallRecorder.sampleRate,
            AVNumberOfChannelsKey: CallRecordingAudioMixer.outputChannels,
            AVEncoderBitRateKey: CallRecorder.audioBitRate
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw CallRecordingError.writerFailed("audio input")
        }
        writer.add(audioInput)
        self.audioInput = audioInput

        guard writer.startWriting() else {
            throw CallRecordingError.writerFailed(CallRecorder.describe(writer.error, stage: "startWriting"))
        }
        self.writer = writer
    }

    deinit {
        self.timer?.cancel()
    }

    private static func videoSettings(width: Int, height: Int, framesPerSecond: Int, bitRate: Int) -> [String: Any] {
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * CallRecorder.keyFrameIntervalSeconds,
                // No B-frames: frames arrive with real-time timestamps and are cut into movie fragments; with
                // reordering, finishWriting failed about one time in four (-11800, underlying -16341).
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }

    private static func makeAudioFormat() -> CMAudioFormatDescription? {
        let channels = UInt32(CallRecordingAudioMixer.outputChannels)
        let bytesPerFrame = UInt32(MemoryLayout<Int16>.size) * channels
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(CallRecorder.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr else {
            return nil
        }
        return format
    }

    // MARK: - Any thread

    // Starts the 30 Hz tick that drains the audio rings and writes video frames.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + CallRecorder.tickInterval, repeating: CallRecorder.tickInterval, leeway: .milliseconds(5))
        timer.setEventHandler(handler: { [weak self] in
            self?.tick()
        })
        self.queue.async {
            self.timer = timer
            timer.resume()
        }
    }

    func setMuted(_ isMuted: Bool) {
        self.queue.async {
            self.isMuted = isMuted
        }
    }

    // What the call screen shows; the next composed frame uses it.
    func setLayout(_ layout: CallRecordingVideoLayout) {
        self.queue.async {
            self.layout = layout
        }
    }

    func receive(_ frame: CallRecordingVideoFrame, side: CallRecordingVideoSide) {
        let seconds = CallRecordingHostClock.seconds(CallRecordingHostClock.now())
        self.queue.async {
            switch side {
            case .remote:
                self.remote.frame = frame
                self.remote.frameSeconds = seconds
                self.remote.isDirty = true
            case .local:
                self.local.frame = frame
                self.local.frameSeconds = seconds
                self.local.isDirty = true
            }
        }
    }

    // MARK: - Recorder queue

    private func tick() {
        guard !self.isFinishing, self.failure == nil else {
            return
        }
        self.drainAudio(final: false)
        if self.startSeconds != nil {
            self.writeVideoFrame()
        }
        self.checkWriter()
    }

    private func startSession(at seconds: Double) {
        guard self.writer.status == .writing else {
            return
        }
        self.startSeconds = seconds
        self.writer.startSession(atSourceTime: .zero)
        // Microphone audio captured before the start would play late; drop it.
        if let firstMic = self.firstMicSeconds, firstMic < seconds {
            self.mixer.discardMic(frames: Int((seconds - firstMic) * Double(CallRecorder.sampleRate)))
        }
    }

    private var producedFrames: Int64 {
        return self.framesWritten + Int64(self.mixBuffer.count / CallRecordingAudioMixer.outputChannels)
    }

    private func drainAudio(final: Bool) {
        let isMuted = self.isMuted
        self.micRing.consume { chunk in
            if self.firstMicSeconds == nil {
                self.firstMicSeconds = CallRecordingHostClock.seconds(chunk.hostTime)
            }
            self.mixer.pushMic(chunk.samples, frames: chunk.frames, channels: chunk.channels, sampleRate: chunk.sampleRate, isMuted: isMuted)
        }
        self.playoutRing.consume { chunk in
            let chunkSeconds = CallRecordingHostClock.seconds(chunk.hostTime)
            if self.startSeconds == nil {
                self.startSession(at: chunkSeconds)
            }
            guard let start = self.startSeconds else {
                return
            }
            let expected = start + Double(self.producedFrames) / Double(CallRecorder.sampleRate)
            let gap = chunkSeconds - expected
            if gap > CallRecorder.gapThreshold {
                self.fillWithMicrophone(frames: Int(gap * Double(CallRecorder.sampleRate)))
            }
            self.mixer.mixPlayout(chunk.samples, frames: chunk.frames, channels: chunk.channels, sampleRate: chunk.sampleRate, output: &self.mixBuffer)
            self.lastPlayoutSeconds = chunkSeconds
            if self.mixBuffer.count >= CallRecorder.commitFrames * CallRecordingAudioMixer.outputChannels {
                self.commitMix()
            }
        }
        if !final {
            let now = CallRecordingHostClock.seconds(CallRecordingHostClock.now())
            if self.startSeconds == nil, let firstMic = self.firstMicSeconds, now - firstMic > CallRecorder.micOnlyStartDelay {
                self.startSession(at: firstMic)
            }
            if let start = self.startSeconds, now - (self.lastPlayoutSeconds ?? start) > CallRecorder.staleThreshold {
                let target = Int64((now - CallRecorder.staleLag - start) * Double(CallRecorder.sampleRate))
                let missing = target - self.producedFrames
                if missing > 0 {
                    self.fillWithMicrophone(frames: Int(missing))
                }
            }
        }
        self.commitMix()
    }

    // Moves the timeline forward with the microphone alone, one second at a time so memory stays bounded.
    private func fillWithMicrophone(frames: Int) {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, CallRecorder.maxSilenceFillFrames)
            self.mixer.mixSilence(frames: count, output: &self.mixBuffer)
            self.commitMix()
            remaining -= count
        }
    }

    private func commitMix() {
        let frames = self.mixBuffer.count / CallRecordingAudioMixer.outputChannels
        guard frames > 0, self.startSeconds != nil else {
            return
        }
        let buffer = self.makeAudioSampleBuffer(self.mixBuffer, frames: frames, position: self.framesWritten)
        self.framesWritten += Int64(frames)
        self.mixBuffer.removeAll(keepingCapacity: true)
        guard let buffer else {
            return
        }
        self.pendingAudio.append((buffer, frames))
        self.pendingAudioFrames += frames
        while self.pendingAudioFrames > CallRecorder.maxPendingAudioFrames, !self.pendingAudio.isEmpty {
            self.pendingAudioFrames -= self.pendingAudio.removeFirst().frames
        }
        self.flushPendingAudio()
    }

    private func flushPendingAudio() {
        while !self.pendingAudio.isEmpty, self.writer.status == .writing, self.audioInput.isReadyForMoreMediaData {
            let item = self.pendingAudio.removeFirst()
            self.pendingAudioFrames -= item.frames
            if !self.audioInput.append(item.buffer) {
                break
            }
        }
    }

    private func makeAudioSampleBuffer(_ samples: [Int16], frames: Int, position: Int64) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else {
            return nil
        }
        var sampleBuffer: CMSampleBuffer?
        let time = CMTime(value: position, timescale: CMTimeScale(CallRecorder.sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: self.audioFormat, sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sampleBuffer) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private func currentImage(_ side: inout VideoSide, now: Double) -> CIImage? {
        guard side.frame != nil, now - side.frameSeconds < CallRecorder.videoSideTimeout else {
            side.frame = nil
            side.image = nil
            side.isDirty = false
            return nil
        }
        if side.isDirty, let frame = side.frame {
            side.isDirty = false
            // A frame that cannot be converted keeps the previous picture.
            if let image = side.converter.image(for: frame) {
                side.image = image
            }
        }
        return side.image
    }

    private func writeVideoFrame() {
        guard let start = self.startSeconds, self.writer.status == .writing, self.videoInput.isReadyForMoreMediaData else {
            return
        }
        let now = CallRecordingHostClock.seconds(CallRecordingHostClock.now())
        // The first picture is at zero so the video track has no empty edit at its start.
        let time = self.lastVideoTime.isValid ? CMTime(seconds: max(0, now - start), preferredTimescale: 90000) : .zero
        if self.lastVideoTime.isValid, time <= self.lastVideoTime {
            return
        }
        // At most the configured frame rate: the tick also drains the audio, so below 30 fps the video skips ticks.
        // Half a tick of slack, so a late tick does not drop the frame that is due.
        if self.lastVideoTime.isValid, (time - self.lastVideoTime).seconds < self.frameInterval - CallRecorder.tickInterval / 2 {
            return
        }
        let remoteImage = self.currentImage(&self.remote, now: now)
        let localImage = self.currentImage(&self.local, now: now)
        let pixelBuffer: CVPixelBuffer
        if remoteImage == nil && localImage == nil {
            // No video on either side: a black frame at the low rate.
            if self.lastVideoTime.isValid, (time - self.lastVideoTime).seconds < CallRecorder.idleVideoFrameInterval {
                return
            }
            if let blackBuffer = self.blackBuffer {
                pixelBuffer = blackBuffer
            } else {
                guard let buffer = self.makePixelBuffer() else {
                    return
                }
                self.currentCompositor().render(remote: nil, local: nil, into: buffer)
                self.blackBuffer = buffer
                pixelBuffer = buffer
            }
        } else {
            guard let buffer = self.makePixelBuffer() else {
                return
            }
            self.hasRealVideo = true
            self.currentCompositor().render(remote: remoteImage, local: localImage, layout: self.layout, into: buffer)
            pixelBuffer = buffer
        }
        if self.adaptor.append(pixelBuffer, withPresentationTime: time) {
            self.lastVideoTime = time
        }
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        guard let pool = self.adaptor.pixelBufferPool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    private func currentCompositor() -> CallRecordingVideoCompositor {
        if let compositor = self.compositor {
            return compositor
        }
        let compositor = CallRecordingVideoCompositor(canvas: self.canvas)
        self.compositor = compositor
        return compositor
    }

    private func checkWriter() {
        guard self.writer.status == .failed else {
            return
        }
        self.fail(.writerFailed(CallRecorder.describe(self.writer.error, stage: "recording")))
    }

    // The writer failed on its own: stop, keep what the movie fragments saved, and tell the center.
    private func fail(_ error: CallRecordingError) {
        guard self.failure == nil, !self.isFinishing else {
            return
        }
        self.failure = error
        self.timer?.cancel()
        self.timer = nil
        self.salvage()
        self.onFailure(self, error)
    }

    private func salvage() {
        let size = (try? self.tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 {
            _ = try? self.storage.moveIntoPlace(self.tempURL, duration: nil)
        } else {
            try? FileManager.default.removeItem(at: self.tempURL.deletingLastPathComponent())
        }
    }

    // Finishes the file and moves it into the folder. `completion` runs on the recorder queue, exactly once.
    func finish(completion: @escaping @Sendable (Result<URL, CallRecordingError>) -> Void) {
        self.queue.async {
            guard !self.isFinishing else {
                completion(.failure(.cancelled))
                return
            }
            if let failure = self.failure {
                self.isFinishing = true
                completion(.failure(failure))
                return
            }
            self.isFinishing = true
            self.timer?.cancel()
            self.timer = nil
            self.drainAudio(final: true)
            guard self.startSeconds != nil, self.framesWritten > 0, self.writer.status == .writing else {
                if self.writer.status == .writing {
                    self.writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: self.tempURL.deletingLastPathComponent())
                completion(.failure(self.writer.status == .failed ? .writerFailed(CallRecorder.describe(self.writer.error, stage: "stopping")) : .nothingRecorded))
                return
            }
            var retries = 0
            while !self.pendingAudio.isEmpty, retries < CallRecorder.finishRetryCount, self.writer.status == .writing {
                self.flushPendingAudio()
                if !self.pendingAudio.isEmpty {
                    usleep(CallRecorder.finishRetryMicroseconds)
                }
                retries += 1
            }
            self.audioInput.markAsFinished()
            self.videoInput.markAsFinished()
            let audioDuration = Double(self.framesWritten) / Double(CallRecorder.sampleRate)
            let videoDuration = self.lastVideoTime.isValid ? self.lastVideoTime.seconds + self.frameInterval : 0
            let duration = max(audioDuration, videoDuration)
            self.writer.finishWriting {
                self.queue.async {
                    self.completeFinishing(duration: duration, completion: completion)
                }
            }
        }
    }

    // "<stage>: <domain> <code> <description> (underlying <domain> <code>)", so a failure report says what broke.
    static func describe(_ error: Error?, stage: String) -> String {
        guard let error = error as NSError? else {
            return "\(stage): unknown error"
        }
        var text = "\(stage): \(error.domain) \(error.code) \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return text
    }

    private func completeFinishing(duration: Double, completion: @escaping @Sendable (Result<URL, CallRecordingError>) -> Void) {
        guard self.writer.status == .completed else {
            self.salvage()
            completion(.failure(.writerFailed(CallRecorder.describe(self.writer.error, stage: "finishing"))))
            return
        }
        guard !self.hasRealVideo else {
            self.moveIntoPlace(self.tempURL, duration: duration, completion: completion)
            return
        }
        // No side ever had video: keep the audio alone as an .m4a; the .mp4 if that fails.
        let audioURL = self.tempURL.deletingPathExtension().appendingPathExtension(CallRecordingStorage.audioExtension)
        CallRecorder.exportAudio(from: self.tempURL, to: audioURL) { isExported in
            self.queue.async {
                if isExported {
                    try? FileManager.default.removeItem(at: self.tempURL)
                    self.moveIntoPlace(audioURL, duration: duration, completion: completion)
                } else {
                    try? FileManager.default.removeItem(at: audioURL)
                    self.moveIntoPlace(self.tempURL, duration: duration, completion: completion)
                }
            }
        }
    }

    private func moveIntoPlace(_ url: URL, duration: Double, completion: (Result<URL, CallRecordingError>) -> Void) {
        do {
            let url = try self.storage.moveIntoPlace(url, duration: duration)
            completion(.success(url))
        } catch {
            completion(.failure(.writerFailed(error.localizedDescription)))
        }
    }

    // Copies the audio track of `source` into an .m4a without re-encoding. `completion` runs on any queue.
    static func exportAudio(from source: URL, to destination: URL, completion: @escaping @Sendable (Bool) -> Void) {
        Task {
            completion(await CallRecorder.exportAudio(from: source, to: destination))
        }
    }

    static func exportAudio(from source: URL, to destination: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let timeRange = try? await audioTrack.load(.timeRange) else {
            return false
        }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? compositionTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)) != nil,
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        try? FileManager.default.removeItem(at: destination)
        session.outputURL = destination
        session.outputFileType = .m4a
        // The handler does not capture the session (it is not Sendable); its status is read once it has finished.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        return session.status == .completed
    }
}
