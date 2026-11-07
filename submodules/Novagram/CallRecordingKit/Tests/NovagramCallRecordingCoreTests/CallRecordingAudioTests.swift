// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AVFoundation
import CoreMedia
@testable import NovagramCallRecordingCore

@available(macOS 14, iOS 15, *)
final class CallRecordingAudioMixerTests: XCTestCase {
    private func mixPlayout(_ mixer: CallRecordingAudioMixer, _ samples: [Int16], channels: Int = 1, sampleRate: UInt32) -> [Int16] {
        var output: [Int16] = []
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            mixer.mixPlayout(base, frames: samples.count / channels, channels: channels, sampleRate: sampleRate, output: &output)
        }
        return output
    }

    private func pushMic(_ mixer: CallRecordingAudioMixer, _ samples: [Int16], channels: Int = 1, sampleRate: UInt32, isMuted: Bool = false) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            mixer.pushMic(base, frames: samples.count / channels, channels: channels, sampleRate: sampleRate, isMuted: isMuted)
        }
    }

    private func left(_ stereo: [Int16]) -> [Int16] {
        return stride(from: 0, to: stereo.count, by: 2).map { stereo[$0] }
    }

    func testMixesBothSidesAt48k() {
        let mixer = CallRecordingAudioMixer()
        self.pushMic(mixer, [Int16](repeating: 1000, count: 480), sampleRate: 48000)
        let output = self.mixPlayout(mixer, [Int16](repeating: 2000, count: 480), sampleRate: 48000)
        XCTAssertEqual(output.count, 960)
        XCTAssertTrue(output.allSatisfy { $0 == 3000 })
    }

    func testPassesThroughExactSamplesAt48k() {
        let mixer = CallRecordingAudioMixer()
        let mic: [Int16] = (0 ..< 480).map { Int16($0) }
        let playout: [Int16] = (0 ..< 480).map { Int16($0 * 2) }
        self.pushMic(mixer, mic, sampleRate: 48000)
        let output = self.mixPlayout(mixer, playout, sampleRate: 48000)
        XCTAssertEqual(self.left(output), (0 ..< 480).map { Int16($0 * 3) })
        // Both channels carry the same mono mix.
        XCTAssertEqual(stride(from: 1, to: output.count, by: 2).map { output[$0] }, self.left(output))
    }

    func testResamplesPlayoutFrom16k() {
        let mixer = CallRecordingAudioMixer()
        // A 16 kHz ramp of 30 per sample becomes a 48 kHz ramp of 10 per sample.
        let ramp: [Int16] = (0 ..< 160).map { Int16($0 * 30) }
        let output = self.left(self.mixPlayout(mixer, ramp, sampleRate: 16000))
        XCTAssertEqual(output.count, 3 * 160 - 2)
        XCTAssertEqual(output, (0 ..< output.count).map { Int16($0 * 10) })
        // The next chunk continues the ramp without a seam.
        let next: [Int16] = (160 ..< 320).map { Int16($0 * 30) }
        let continued = self.left(self.mixPlayout(mixer, next, sampleRate: 16000))
        XCTAssertEqual(continued.count, 480)
        XCTAssertEqual(continued, (output.count ..< output.count + 480).map { Int16($0 * 10) })
    }

    func testResamplesMicFrom16k() {
        let mixer = CallRecordingAudioMixer()
        self.pushMic(mixer, (0 ..< 160).map { Int16($0 * 30) }, sampleRate: 16000)
        XCTAssertEqual(mixer.bufferedMicFrames, 478)
        let output = self.left(self.mixPlayout(mixer, [Int16](repeating: 100, count: 478), sampleRate: 48000))
        XCTAssertEqual(output, (0 ..< 478).map { Int16($0 * 10 + 100) })
    }

    func testMutedMicContributesSilence() {
        let mixer = CallRecordingAudioMixer()
        self.pushMic(mixer, [Int16](repeating: 1000, count: 480), sampleRate: 48000, isMuted: true)
        XCTAssertEqual(mixer.bufferedMicFrames, 480)
        let output = self.mixPlayout(mixer, [Int16](repeating: 2000, count: 480), sampleRate: 48000)
        XCTAssertTrue(output.allSatisfy { $0 == 2000 })
    }

    func testMicUnderrunGivesZeros() {
        let mixer = CallRecordingAudioMixer()
        let silentMic = self.mixPlayout(mixer, [Int16](repeating: 2000, count: 480), sampleRate: 48000)
        XCTAssertTrue(silentMic.allSatisfy { $0 == 2000 })
        self.pushMic(mixer, [Int16](repeating: 1000, count: 100), sampleRate: 48000)
        let output = self.left(self.mixPlayout(mixer, [Int16](repeating: 0, count: 480), sampleRate: 48000))
        XCTAssertEqual(Array(output[0 ..< 100]), [Int16](repeating: 1000, count: 100))
        XCTAssertEqual(Array(output[100...]), [Int16](repeating: 0, count: 380))
        var silence: [Int16] = []
        mixer.mixSilence(frames: 10, output: &silence)
        XCTAssertEqual(self.left(silence), [Int16](repeating: 0, count: 10))
    }

    func testSumIsClipped() {
        let mixer = CallRecordingAudioMixer()
        self.pushMic(mixer, [30000, -30000], sampleRate: 48000)
        let output = self.left(self.mixPlayout(mixer, [30000, -30000], sampleRate: 48000))
        XCTAssertEqual(output, [Int16.max, Int16.min])
    }

    func testStereoInputIsDownmixed() {
        let mixer = CallRecordingAudioMixer()
        let output = self.left(self.mixPlayout(mixer, [1000, 3000, -1000, -3000], channels: 2, sampleRate: 48000))
        XCTAssertEqual(output, [2000, -2000])
    }

    func testRingSplitsLargeChunksAndKeepsOrder() throws {
        let ring = CallRecordingAudioRing(slotCount: 4, slotCapacity: 8)
        let samples: [Int16] = (0 ..< 20).map { Int16($0) }
        try samples.withUnsafeBufferPointer { buffer in
            ring.write(try XCTUnwrap(buffer.baseAddress), frames: 10, channels: 2, sampleRate: 48000, hostTime: 7)
        }
        var collected: [Int16] = []
        ring.consume { chunk in
            XCTAssertEqual(chunk.channels, 2)
            XCTAssertEqual(chunk.hostTime, 7)
            collected.append(contentsOf: UnsafeBufferPointer(start: chunk.samples, count: chunk.frames * chunk.channels))
        }
        XCTAssertEqual(collected, samples)
        // A full ring drops what does not fit instead of waiting.
        let many: [Int16] = [Int16](repeating: 1, count: 80)
        try many.withUnsafeBufferPointer { buffer in
            ring.write(try XCTUnwrap(buffer.baseAddress), frames: 80, channels: 1, sampleRate: 48000, hostTime: 0)
        }
        var frames = 0
        ring.consume { chunk in
            frames += chunk.frames
        }
        XCTAssertEqual(frames, 32)
        XCTAssertEqual(ring.droppedChunks, 1)
    }
}

@available(macOS 14, iOS 15, *)
final class CallRecordingAudioTapTests: XCTestCase {
    // A Float32 non-interleaved stereo buffer, as ScreenCaptureKit delivers its audio.
    private func makeFloatSampleBuffer(left: [Float], right: [Float]) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        pcm.frameLength = AVAudioFrameCount(left.count)
        let channels = try XCTUnwrap(pcm.floatChannelData)
        for index in 0 ..< left.count {
            channels[0][index] = left[index]
            channels[1][index] = right[index]
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: left.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        let buffer = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        return buffer
    }

    func testFloatSampleBufferBecomesInterleavedInt16() throws {
        let buffer = try self.makeFloatSampleBuffer(left: [0.5, -0.5, 1.0, 0], right: [0.25, 0, -1.0, 2.0])
        let pcm = try XCTUnwrap(CallRecordingSampleBufferPCM.interleavedInt16(from: buffer))
        XCTAssertEqual(pcm.frames, 4)
        XCTAssertEqual(pcm.channels, 2)
        XCTAssertEqual(pcm.sampleRate, 48000)
        XCTAssertEqual(pcm.samples, [16384, 8192, -16384, 0, 32767, -32767, 0, 32767])
    }

    func testSampleBufferGoesToTheSourcesRing() throws {
        let micRing = CallRecordingAudioRing()
        let playoutRing = CallRecordingAudioRing()
        let tap = CallRecordingAudioTap(micRing: micRing, playoutRing: playoutRing)
        tap.appendSampleBuffer(try self.makeFloatSampleBuffer(left: [0.5, 0.5], right: [0.5, 0.5]), source: .remote)
        var playoutFrames = 0
        playoutRing.consume { chunk in
            playoutFrames += chunk.frames
            XCTAssertEqual(chunk.channels, 2)
            XCTAssertEqual(chunk.sampleRate, 48000)
        }
        XCTAssertEqual(playoutFrames, 2)
        var micFrames = 0
        micRing.consume { chunk in
            micFrames += chunk.frames
        }
        XCTAssertEqual(micFrames, 0)
        tap.appendSampleBuffer(try self.makeFloatSampleBuffer(left: [0.1], right: [0.1]), source: .microphone)
        micRing.consume { chunk in
            micFrames += chunk.frames
        }
        XCTAssertEqual(micFrames, 1)
    }
}
