// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import AVFoundation
import CoreMedia

/// Which side of the call an audio buffer belongs to.
public enum CallRecordingAudioSource: Sendable, Equatable {
    /// Our own microphone.
    case microphone
    /// What the speaker plays: the other side plus the call tones. Its clock drives the recording's timeline.
    case remote
}

/// Where the host pushes the call's audio while a recording runs.
///
/// Both methods only copy the samples into a preallocated ring and return; the recorder's own queue mixes and
/// encodes them. Push each source from one thread at a time (one producer per source). Remove your tap when the
/// recording stops: later pushes are dropped and cost nothing.
@available(macOS 14, iOS 15, *)
public final class CallRecordingAudioTap: Sendable {
    let micRing: CallRecordingAudioRing
    let playoutRing: CallRecordingAudioRing

    init(micRing: CallRecordingAudioRing, playoutRing: CallRecordingAudioRing) {
        self.micRing = micRing
        self.playoutRing = playoutRing
    }

    /// Interleaved signed 16-bit PCM, any sample rate, up to 8 channels.
    ///
    /// Safe on a real-time audio thread: no allocation, no locks that wait, no Objective-C messaging. A chunk that
    /// does not fit (the ring is full or being read) is dropped.
    /// - Parameter isPlayout: `true` for what the speaker plays (the other side), `false` for the microphone.
    public func appendPCM(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int, sampleRate: UInt32, isPlayout: Bool) {
        let hostTime = CallRecordingHostClock.now()
        let ring = isPlayout ? self.playoutRing : self.micRing
        ring.write(samples, frames: frames, channels: channels, sampleRate: sampleRate, hostTime: hostTime)
    }

    /// A linear PCM sample buffer (Float32, Int16 or Int32; interleaved or not), as ScreenCaptureKit and
    /// `AVCaptureAudioDataOutput` deliver them.
    ///
    /// Converts to 16-bit PCM and calls ``appendPCM(_:frames:channels:sampleRate:isPlayout:)``. It allocates, so
    /// call it from the capture queue, never from a real-time audio thread. The arrival time is the chunk's time, as
    /// for the PCM path; the buffer's own timestamps are not used.
    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, source: CallRecordingAudioSource) {
        guard let pcm = CallRecordingSampleBufferPCM.interleavedInt16(from: sampleBuffer) else {
            return
        }
        pcm.samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            self.appendPCM(base, frames: pcm.frames, channels: pcm.channels, sampleRate: pcm.sampleRate, isPlayout: source == .remote)
        }
    }
}

// Reads a linear PCM CMSampleBuffer into interleaved Int16 samples.
@available(macOS 14, iOS 15, *)
enum CallRecordingSampleBufferPCM {
    struct PCM {
        let samples: [Int16]
        let frames: Int
        let channels: Int
        let sampleRate: UInt32
    }

    static func interleavedInt16(from sampleBuffer: CMSampleBuffer) -> PCM? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, basic.mSampleRate > 0, basic.mChannelsPerFrame > 0, basic.mChannelsPerFrame <= UInt32(CallRecordingAudioRing.maxChannels) else {
            return nil
        }
        var streamDescription = basic
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            return nil
        }
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        let isInterleaved = format.isInterleaved
        var samples = [Int16](repeating: 0, count: frames * channels)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                let plane = isInterleaved ? data[0] + channel : data[channel]
                for frame in 0 ..< frames {
                    samples[frame * channels + channel] = CallRecordingAudioMixer.clip(plane[frame * stride] * Float(Int16.max))
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                let plane = isInterleaved ? data[0] + channel : data[channel]
                for frame in 0 ..< frames {
                    samples[frame * channels + channel] = plane[frame * stride]
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                let plane = isInterleaved ? data[0] + channel : data[channel]
                for frame in 0 ..< frames {
                    samples[frame * channels + channel] = Int16(truncatingIfNeeded: plane[frame * stride] >> 16)
                }
            }
        default:
            return nil
        }
        return PCM(samples: samples, frames: frames, channels: channels, sampleRate: UInt32(basic.mSampleRate.rounded()))
    }
}
