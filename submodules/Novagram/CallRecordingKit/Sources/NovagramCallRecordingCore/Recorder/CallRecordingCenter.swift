// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Combine

/// Whether a call is being recorded.
public enum CallRecordingState: Equatable, Sendable {
    case idle
    /// Since `startDate`, for the REC mm:ss timer.
    case recording(startDate: Date)
}

/// One running recording: where the host pushes the call's audio and video.
///
/// Every method may be called from any thread. ``audioTap`` is safe on a real-time audio thread.
@available(macOS 14, iOS 15, *)
public final class CallRecordingSession: Sendable {
    public let callId: UUID
    /// Push the call's audio here (PCM from the audio device, or capture sample buffers).
    public let audioTap: CallRecordingAudioTap
    private let recorder: CallRecorder

    init(callId: UUID, recorder: CallRecorder) {
        self.callId = callId
        self.recorder = recorder
        self.audioTap = recorder.audioTap
    }

    /// A new picture for one side. Push frames as they come; the recorder composes at up to the configured frame rate (30 fps at most) and treats a side
    /// with no new frame for 4 seconds as having no video. Both sides are followed for the whole recording, also in
    /// a voice call: the file has video if either side ever had some and is audio-only (`.m4a`) otherwise.
    public func appendVideoFrame(_ frame: CallRecordingVideoFrame, side: CallRecordingVideoSide) {
        self.recorder.receive(frame, side: side)
    }

    /// Our microphone is muted: it is recorded as silence, so the timeline stays in step.
    public func setMuted(_ isMuted: Bool) {
        self.recorder.setMuted(isMuted)
    }

    /// Where the call screen's small picture is and whether its big and small videos are swapped. The next
    /// recorded frame follows it.
    public func setLayout(pipCorner: CallRecordingPipCorner, isSwapped: Bool) {
        self.recorder.setLayout(CallRecordingVideoLayout(pipCorner: pipCorner, isSwapped: isSwapped))
    }
}

/// The registry of call recordings, keyed by the call's id. One instance per app (one per recordings folder).
///
/// Main-actor API. The audio tap runs on the audio thread and each writer on its recorder's own queue.
/// Observe state with `@Published` ``recordingStartDates`` (SwiftUI, Combine) or ``stateUpdates(callId:)``.
@available(macOS 14, iOS 15, *)
@MainActor
public final class CallRecordingCenter: ObservableObject {
    public let storage: CallRecordingStorage
    public let configuration: CallRecordingConfiguration

    /// When each running recording started, by call id.
    @Published public private(set) var recordingStartDates: [UUID: Date] = [:]

    private var sessions: [UUID: CallRecordingSession] = [:]
    private var recorders: [UUID: CallRecorder] = [:]
    private var detachHandlers: [UUID: @MainActor () -> Void] = [:]
    // A recording whose writer failed on its own; its error is what the next stop() for that call returns.
    private var failures: [UUID: CallRecordingError] = [:]
    private var stateContinuations: [UUID: [UUID: AsyncStream<CallRecordingState>.Continuation]] = [:]

    /// Moves recordings a killed app left unfinished in `storage` into the folder (once per process and folder).
    public init(storage: CallRecordingStorage = .default, configuration: CallRecordingConfiguration = .standard) {
        self.storage = storage
        self.configuration = configuration
        storage.recoverInterruptedOnce()
    }

    /// Starts recording a call.
    /// - Parameters:
    ///   - peerName: the other person's name; the file is named after it.
    ///   - configuration: the encoding of this recording (``CallRecordingConfiguration/init(quality:)`` for the
    ///     user's video quality); nil uses the center's ``configuration``.
    ///   - onDetach: called once when this recording stops (``stop(callId:completion:)``, ``stopAll(timeout:completion:)``
    ///     or the writer failing on its own). Remove your audio tap and video subscriptions there.
    /// - Returns: the session to push audio, video, mute and layout into.
    /// - Throws: ``CallRecordingError/alreadyRecording`` or ``CallRecordingError/writerFailed(_:)``.
    public func start(callId: UUID, peerName: String, configuration: CallRecordingConfiguration? = nil, onDetach: (@MainActor () -> Void)? = nil) throws -> CallRecordingSession {
        guard self.recorders[callId] == nil else {
            throw CallRecordingError.alreadyRecording
        }
        let storage = self.storage
        // Written as .mp4; it becomes .m4a at the end if no video ever arrived.
        let fileName = storage.fileName(peerName: peerName, date: Date(), isVideo: true)
        let partialFolder = storage.partialDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder: CallRecorder
        do {
            try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
            recorder = try CallRecorder(tempURL: partialFolder.appendingPathComponent(fileName), storage: storage, configuration: configuration ?? self.configuration, onFailure: { [weak self] recorder, error in
                Task { @MainActor in
                    self?.recorderDidFail(callId: callId, recorder: recorder, error: error)
                }
            })
        } catch {
            try? FileManager.default.removeItem(at: partialFolder)
            throw (error as? CallRecordingError) ?? CallRecordingError.writerFailed(error.localizedDescription)
        }
        let session = CallRecordingSession(callId: callId, recorder: recorder)
        self.failures[callId] = nil
        self.recorders[callId] = recorder
        self.sessions[callId] = session
        self.detachHandlers[callId] = onDetach
        recorder.start()
        self.setState(.recording(startDate: Date()), callId: callId)
        return session
    }

    /// The running session of a call.
    public func session(callId: UUID) -> CallRecordingSession? {
        return self.sessions[callId]
    }

    /// Detaches the host (``start(callId:peerName:configuration:onDetach:)``'s `onDetach`), finishes the file and moves it into
    /// the folder. `completion` runs on the main actor with the file, or ``CallRecordingError/cancelled`` for a call
    /// that is not being recorded (the writer's error if it had failed on its own).
    public func stop(callId: UUID, completion: @escaping @MainActor @Sendable (Result<URL, CallRecordingError>) -> Void) {
        guard let recorder = self.recorders.removeValue(forKey: callId) else {
            let error = self.failures.removeValue(forKey: callId) ?? .cancelled
            Task { @MainActor in
                completion(.failure(error))
            }
            return
        }
        self.sessions[callId] = nil
        self.detach(callId: callId)
        self.setState(.idle, callId: callId)
        recorder.finish { result in
            Task { @MainActor in
                completion(result)
            }
        }
    }

    /// ``stop(callId:completion:)`` for async code.
    public func stop(callId: UUID) async -> Result<URL, CallRecordingError> {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, CallRecordingError>, Never>) in
            self.stop(callId: callId) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// ``CallRecordingSession/setLayout(pipCorner:isSwapped:)`` by call id. Ignored for a call not being recorded.
    public func setLayout(callId: UUID, pipCorner: CallRecordingPipCorner, isSwapped: Bool) {
        self.sessions[callId]?.setLayout(pipCorner: pipCorner, isSwapped: isSwapped)
    }

    /// ``CallRecordingSession/setMuted(_:)`` by call id. Ignored for a call not being recorded.
    public func setMuted(callId: UUID, isMuted: Bool) {
        self.sessions[callId]?.setMuted(isMuted)
    }

    public func isRecording(callId: UUID) -> Bool {
        return self.recorders[callId] != nil
    }

    public func state(callId: UUID) -> CallRecordingState {
        guard let date = self.recordingStartDates[callId] else {
            return .idle
        }
        return .recording(startDate: date)
    }

    /// The call's state now, then every change. The stream ends when the caller stops iterating.
    public func stateUpdates(callId: UUID) -> AsyncStream<CallRecordingState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CallRecordingState.self)
        let token = UUID()
        continuation.yield(self.state(callId: callId))
        self.stateContinuations[callId, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeStateContinuation(callId: callId, token: token)
            }
        }
        return stream
    }

    /// App termination path: stops every recording and finishes the files. `completion` runs once, when all files
    /// are finished or after `timeout` seconds, on a background queue (never main), so a caller in
    /// `applicationWillTerminate` may block the main thread waiting for it. A file not finished in time stays in
    /// `.partial` and is moved into the folder on the next launch.
    public func stopAll(timeout: Double, completion: @escaping @Sendable () -> Void) {
        let recorders = Array(self.recorders.values)
        let callIds = Array(self.recorders.keys)
        self.recorders.removeAll()
        self.sessions.removeAll()
        for callId in callIds {
            self.detach(callId: callId)
            self.setState(.idle, callId: callId)
        }
        CallRecordingCenter.finish(recorders, timeout: timeout, completion: completion)
    }

    // Nonisolated on purpose: closures made here are not main-actor closures, so Swift 6 does not trap when the
    // dispatch group and the timeout run them on a background queue.
    nonisolated private static func finish(_ recorders: [CallRecorder], timeout: Double, completion: @escaping @Sendable () -> Void) {
        let callback = CallRecordingOnceCallback(completion)
        let group = DispatchGroup()
        for recorder in recorders {
            group.enter()
            recorder.finish { _ in
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            callback.call()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(timeout, 0)) {
            callback.call()
        }
    }

    private func recorderDidFail(callId: UUID, recorder: CallRecorder, error: CallRecordingError) {
        guard let current = self.recorders[callId], current === recorder else {
            return
        }
        self.recorders[callId] = nil
        self.sessions[callId] = nil
        self.failures[callId] = error
        self.detach(callId: callId)
        self.setState(.idle, callId: callId)
    }

    private func detach(callId: UUID) {
        if let handler = self.detachHandlers.removeValue(forKey: callId) {
            handler()
        }
    }

    private func setState(_ state: CallRecordingState, callId: UUID) {
        switch state {
        case .idle:
            self.recordingStartDates[callId] = nil
        case let .recording(startDate):
            self.recordingStartDates[callId] = startDate
        }
        for continuation in (self.stateContinuations[callId] ?? [:]).values {
            continuation.yield(state)
        }
    }

    private func removeStateContinuation(callId: UUID, token: UUID) {
        self.stateContinuations[callId]?[token] = nil
        if self.stateContinuations[callId]?.isEmpty == true {
            self.stateContinuations[callId] = nil
        }
    }
}

// Calls the wrapped closure at most once, from whichever thread gets there first.
@available(macOS 14, iOS 15, *)
private final class CallRecordingOnceCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func call() {
        self.lock.lock()
        let callback = self.callback
        self.callback = nil
        self.lock.unlock()
        callback?()
    }
}
