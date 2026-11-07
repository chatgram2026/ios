// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreGraphics

/// How recordings are encoded.
public struct CallRecordingConfiguration: Sendable, Equatable {
    /// The most video frames per second: the recorder's tick, which also drains the audio, runs at this rate.
    public static let maxFramesPerSecond = 30

    /// The size of the recorded video in pixels; rounded down to even numbers (H.264 needs them), at least 2x2.
    /// The default is 720x1280, portrait, like the phone's call screen.
    public let videoSize: CGSize
    /// Video frames per second, 1...30. The default is 30.
    public let framesPerSecond: Int
    /// The average H.264 bit rate in bits per second, at least 100 kbit/s. The default is 2.5 Mbit/s.
    public let videoBitRate: Int

    public init(videoSize: CGSize = CGSize(width: 720, height: 1280), framesPerSecond: Int = 30, videoBitRate: Int = 2_500_000) {
        let width = max(2, Int(videoSize.width) & ~1)
        let height = max(2, Int(videoSize.height) & ~1)
        self.videoSize = CGSize(width: width, height: height)
        self.framesPerSecond = min(CallRecordingConfiguration.maxFramesPerSecond, max(1, framesPerSecond))
        self.videoBitRate = max(100_000, videoBitRate)
    }

    /// The encoding for a video quality setting. Battery saver halves the frame rate and the bit rate, so the video
    /// costs about half the work and half the space; the picture size stays, so a shared screen stays readable.
    /// Audio only uses the standard encoding: the host pushes no video, so the file ends up audio-only (`.m4a`).
    public init(quality: CallRecordingVideoQuality) {
        switch quality {
        case .high, .audioOnly:
            self.init()
        case .batterySaver:
            self.init(framesPerSecond: 15, videoBitRate: 1_250_000)
        }
    }

    public static let standard = CallRecordingConfiguration()

    var canvas: CGRect {
        return CGRect(origin: .zero, size: self.videoSize)
    }
}

/// Why a recording failed.
public enum CallRecordingError: Error, Equatable, Sendable {
    /// AVAssetWriter failed; the text says at which stage and with which error.
    case writerFailed(String)
    /// The recording stopped before any audio arrived.
    case nothingRecorded
    /// ``CallRecordingCenter/stop(callId:completion:)`` for a call that is not being recorded.
    case cancelled
    /// ``CallRecordingCenter/start(callId:peerName:configuration:onDetach:)`` for a call that is already being recorded.
    case alreadyRecording
}
