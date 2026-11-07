// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreMedia
import CoreVideo

/// Which side of the call a video frame shows.
public enum CallRecordingVideoSide: Sendable, Equatable {
    /// The other person's video.
    case remote
    /// Our own camera or shared screen.
    case local
}

/// One call video frame, reduced to what the recorder needs: the picture and how the call screen shows it.
///
/// Each app adapts its own frames: the iOS app maps Telegram's `VideoFrameData` (native, NV12 or I420 buffers plus
/// orientation and mirroring), the Mac passes ScreenCaptureKit pixel buffers. Sendable because the planes are
/// immutable `Data` and a pixel buffer is only read after it is handed over.
@available(macOS 14, iOS 15, *)
public struct CallRecordingVideoFrame: @unchecked Sendable {
    /// The picture.
    public enum Buffer {
        /// Any Core Video pixel buffer Core Image can read (BGRA, NV12 and so on).
        case pixelBuffer(CVPixelBuffer)
        /// Bi-planar 4:2:0: a luma plane and an interleaved CbCr plane.
        case nv12(y: Data, strideY: Int, uv: Data, strideUV: Int, width: Int, height: Int)
        /// Planar 4:2:0: luma, Cb and Cr planes.
        case i420(y: Data, strideY: Int, u: Data, strideU: Int, v: Data, strideV: Int, width: Int, height: Int)
    }

    public let buffer: Buffer
    /// Clockwise quarter turns, applied after the mirroring, as the call screen applies them. Kept in 0...3.
    public let rotationQuarterTurns: Int
    public let mirrorHorizontally: Bool
    public let mirrorVertically: Bool

    public init(buffer: Buffer, rotationQuarterTurns: Int = 0, mirrorHorizontally: Bool = false, mirrorVertically: Bool = false) {
        self.buffer = buffer
        self.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        self.mirrorHorizontally = mirrorHorizontally
        self.mirrorVertically = mirrorVertically
    }

    /// A Core Video pixel buffer.
    public static func pixelBuffer(_ pixelBuffer: CVPixelBuffer, rotationQuarterTurns: Int = 0, mirrorHorizontally: Bool = false, mirrorVertically: Bool = false) -> CallRecordingVideoFrame {
        return CallRecordingVideoFrame(buffer: .pixelBuffer(pixelBuffer), rotationQuarterTurns: rotationQuarterTurns, mirrorHorizontally: mirrorHorizontally, mirrorVertically: mirrorVertically)
    }

    /// NV12 planes. The planes are copied into a pixel buffer on the recorder queue.
    public static func nv12(y: Data, strideY: Int, uv: Data, strideUV: Int, width: Int, height: Int, rotationQuarterTurns: Int = 0, mirrorHorizontally: Bool = false, mirrorVertically: Bool = false) -> CallRecordingVideoFrame {
        return CallRecordingVideoFrame(buffer: .nv12(y: y, strideY: strideY, uv: uv, strideUV: strideUV, width: width, height: height), rotationQuarterTurns: rotationQuarterTurns, mirrorHorizontally: mirrorHorizontally, mirrorVertically: mirrorVertically)
    }

    /// I420 planes. The planes are copied into an NV12 pixel buffer on the recorder queue.
    public static func i420(y: Data, strideY: Int, u: Data, strideU: Int, v: Data, strideV: Int, width: Int, height: Int, rotationQuarterTurns: Int = 0, mirrorHorizontally: Bool = false, mirrorVertically: Bool = false) -> CallRecordingVideoFrame {
        return CallRecordingVideoFrame(buffer: .i420(y: y, strideY: strideY, u: u, strideU: strideU, v: v, strideV: strideV, width: width, height: height), rotationQuarterTurns: rotationQuarterTurns, mirrorHorizontally: mirrorHorizontally, mirrorVertically: mirrorVertically)
    }

    /// The image buffer of a video sample buffer (ScreenCaptureKit, AVCaptureVideoDataOutput), upright.
    /// Nil for a buffer without an image (ScreenCaptureKit's idle and blank frames).
    public init?(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        self.init(buffer: .pixelBuffer(imageBuffer))
    }
}
