// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import CoreImage
import CoreVideo
@testable import NovagramCallRecordingCore

@available(macOS 14, iOS 15, *)
final class CallRecordingVideoTests: XCTestCase {
    // Maps the centre of a pixel through the orientation transform; (x, y) are counted from the top, as on screen.
    private func orientedPixel(_ x: Int, _ y: Int, width: Int, height: Int, turns: Int, mirrorH: Bool, mirrorV: Bool) -> (Int, Int, CGSize) {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = CallRecordingVideoFrameConverter.orientation(extent: extent, quarterTurns: turns, mirrorHorizontally: mirrorH, mirrorVertically: mirrorV)
        let size = extent.applying(transform)
        // Core Image's y axis points up.
        let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(height - 1 - y) + 0.5).applying(transform)
        return (Int(point.x.rounded(.down)), Int(size.height) - 1 - Int(point.y.rounded(.down)), CGSize(width: size.width, height: size.height))
    }

    // The call screen draws the frame mirrored, then rotates the layer clockwise by the frame's orientation.
    func testOrientationMatchesCallScreen() {
        let cases: [(turns: Int, mirrorH: Bool, mirrorV: Bool, size: CGSize, topLeftGoesTo: (Int, Int))] = [
            (0, false, false, CGSize(width: 4, height: 2), (0, 0)),
            (1, false, false, CGSize(width: 2, height: 4), (1, 0)),
            (2, false, false, CGSize(width: 4, height: 2), (3, 1)),
            (3, false, false, CGSize(width: 2, height: 4), (0, 3)),
            (0, true, false, CGSize(width: 4, height: 2), (3, 0)),
            (0, false, true, CGSize(width: 4, height: 2), (0, 1)),
            (1, true, false, CGSize(width: 2, height: 4), (1, 3)),
            (3, true, false, CGSize(width: 2, height: 4), (0, 0))
        ]
        for item in cases {
            let label = "turns \(item.turns) mirror \(item.mirrorH)/\(item.mirrorV)"
            let result = self.orientedPixel(0, 0, width: 4, height: 2, turns: item.turns, mirrorH: item.mirrorH, mirrorV: item.mirrorV)
            XCTAssertEqual(result.2, item.size, label)
            XCTAssertEqual(result.0, item.topLeftGoesTo.0, label)
            XCTAssertEqual(result.1, item.topLeftGoesTo.1, label)
            // The CIImage path uses the same transform and lands at the origin.
            let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 10, y: 20, width: 4, height: 2))
            let oriented = CallRecordingVideoFrameConverter.orient(image, quarterTurns: item.turns, mirrorHorizontally: item.mirrorH, mirrorVertically: item.mirrorV)
            XCTAssertEqual(oriented.extent, CGRect(origin: .zero, size: item.size), label)
        }
    }

    func testFrameKeepsRotationInRange() {
        let y = Data(repeating: 0, count: 4)
        let uv = Data(repeating: 0, count: 2)
        XCTAssertEqual(CallRecordingVideoFrame.nv12(y: y, strideY: 2, uv: uv, strideUV: 2, width: 2, height: 2, rotationQuarterTurns: 5).rotationQuarterTurns, 1)
        XCTAssertEqual(CallRecordingVideoFrame.nv12(y: y, strideY: 2, uv: uv, strideUV: 2, width: 2, height: 2, rotationQuarterTurns: -1).rotationQuarterTurns, 3)
    }

    func testRotatedRemoteFillsPortraitFrame() {
        let canvas = CallRecordingVideoCompositor.defaultCanvas
        // A 640x360 frame turned a quarter is 360x640, the canvas's own aspect.
        let portrait = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 360, height: 640))
        XCTAssertEqual(CallRecordingVideoCompositor.place(portrait, in: canvas, fill: false).extent, canvas)
        // An upright landscape frame is letterboxed: full width, centred vertically.
        let landscape = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let placed = CallRecordingVideoCompositor.place(landscape, in: canvas, fill: false).extent
        // Core Image rounds a fractional extent outwards, so allow one point.
        XCTAssertEqual(placed.width, 720, accuracy: 1)
        XCTAssertEqual(placed.height, 405, accuracy: 1)
        XCTAssertEqual(placed.midY, canvas.midY, accuracy: 1)
        let composed = CallRecordingVideoCompositor.compose(remote: landscape, local: portrait, background: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas))
        XCTAssertEqual(composed.extent, canvas)
    }

    func testI420IsInterleavedIntoNV12() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        let y = Data((0 ..< 16).map { UInt8($0) })
        let u = Data([10, 11, 12, 13])
        let v = Data([20, 21, 22, 23])
        XCTAssertTrue(CallRecordingVideoFrameConverter.copyI420(width: 4, height: 4, y: y, strideY: 4, u: u, strideU: 2, v: v, strideV: 2, into: pixelBuffer))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        XCTAssertEqual(yBase[yStride + 1], 5)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)).assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: uvBase, count: 4)), [10, 20, 11, 21])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: uvBase + uvStride, count: 4)), [12, 22, 13, 23])
    }

    func testShortPlanesAreRejected() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertFalse(CallRecordingVideoFrameConverter.copyNV12(width: 4, height: 4, y: Data(repeating: 0, count: 10), strideY: 4, uv: Data(repeating: 0, count: 8), strideUV: 4, into: pixelBuffer))
    }

    func testPictureInPictureSitsTopRight() {
        let rect = CallRecordingVideoCompositor.pipRect(for: CGSize(width: 480, height: 640))
        XCTAssertEqual(rect.maxX, CGFloat(CallRecordingVideoCompositor.defaultWidth) - CallRecordingVideoCompositor.pipMargin)
        XCTAssertEqual(rect.maxY, CGFloat(CallRecordingVideoCompositor.defaultHeight) - CallRecordingVideoCompositor.pipMargin)
        XCTAssertEqual(rect.width, (720 * 0.28).rounded())
        XCTAssertEqual(rect.height, (rect.width * 640 / 480).rounded())
    }

    func testPictureInPictureFollowsTheFourCorners() {
        let size = CGSize(width: 480, height: 640)
        let width = CGFloat(CallRecordingVideoCompositor.defaultWidth)
        let height = CGFloat(CallRecordingVideoCompositor.defaultHeight)
        let margin = CallRecordingVideoCompositor.pipMargin
        // Core Image is y up: the top of the picture is the high y.
        let topLeft = CallRecordingVideoCompositor.pipRect(for: size, corner: .topLeft)
        XCTAssertEqual(topLeft.minX, margin)
        XCTAssertEqual(topLeft.maxY, height - margin)
        let topRight = CallRecordingVideoCompositor.pipRect(for: size, corner: .topRight)
        XCTAssertEqual(topRight.maxX, width - margin)
        XCTAssertEqual(topRight.maxY, height - margin)
        XCTAssertEqual(topRight, CallRecordingVideoCompositor.pipRect(for: size), "top-right stays the default")
        let bottomLeft = CallRecordingVideoCompositor.pipRect(for: size, corner: .bottomLeft)
        XCTAssertEqual(bottomLeft.minX, margin)
        XCTAssertEqual(bottomLeft.minY, margin)
        let bottomRight = CallRecordingVideoCompositor.pipRect(for: size, corner: .bottomRight)
        XCTAssertEqual(bottomRight.maxX, width - margin)
        XCTAssertEqual(bottomRight.minY, margin)
        for rect in [topLeft, bottomLeft, bottomRight] {
            XCTAssertEqual(rect.size, topRight.size, "only the position changes")
        }
    }

    func testPictureInPictureFollowsALandscapeCanvas() {
        let canvas = CallRecordingConfiguration(videoSize: CGSize(width: 1280, height: 720)).canvas
        let rect = CallRecordingVideoCompositor.pipRect(for: CGSize(width: 640, height: 360), corner: .bottomRight, canvas: canvas)
        XCTAssertEqual(rect.maxX, 1280 - CallRecordingVideoCompositor.pipMargin)
        XCTAssertEqual(rect.minY, CallRecordingVideoCompositor.pipMargin)
        XCTAssertEqual(rect.width, (1280 * 0.28).rounded())
    }

    func testConfigurationKeepsEvenSizes() {
        XCTAssertEqual(CallRecordingConfiguration.standard.videoSize, CGSize(width: 720, height: 1280))
        XCTAssertEqual(CallRecordingConfiguration(videoSize: CGSize(width: 1281, height: 721)).videoSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(CallRecordingConfiguration(videoSize: .zero).videoSize, CGSize(width: 2, height: 2))
    }

    func testSwapPutsOurVideoBig() {
        let normal = CallRecordingVideoCompositor.arrange(remote: "remote", local: "local", isSwapped: false)
        XCTAssertEqual(normal.main, "remote")
        XCTAssertEqual(normal.pip, "local")
        let swapped = CallRecordingVideoCompositor.arrange(remote: "remote", local: "local", isSwapped: true)
        XCTAssertEqual(swapped.main, "local")
        XCTAssertEqual(swapped.pip, "remote")
        // A lone side always fills the frame, swapped or not.
        for isSwapped in [false, true] {
            let remoteOnly = CallRecordingVideoCompositor.arrange(remote: "remote", local: nil, isSwapped: isSwapped)
            XCTAssertEqual(remoteOnly.main, "remote")
            XCTAssertNil(remoteOnly.pip)
            let localOnly = CallRecordingVideoCompositor.arrange(remote: nil, local: "local", isSwapped: isSwapped)
            XCTAssertEqual(localOnly.main, "local")
            XCTAssertNil(localOnly.pip)
        }
    }

    // Swapped with the pip bottom-left: our picture fills the frame and the other side's sits in that corner.
    func testComposeUsesLayout() {
        let canvas = CallRecordingVideoCompositor.defaultCanvas
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        let remote = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let local = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 720, height: 1280))
        let layout = CallRecordingVideoLayout(pipCorner: .bottomLeft, isSwapped: true)
        let composed = CallRecordingVideoCompositor.compose(remote: remote, local: local, layout: layout, background: background)
        XCTAssertEqual(composed.extent, canvas)
        let pip = CallRecordingVideoCompositor.pipRect(for: remote.extent.size, corner: .bottomLeft)
        XCTAssertEqual(pip.minX, CallRecordingVideoCompositor.pipMargin)
        XCTAssertEqual(pip.minY, CallRecordingVideoCompositor.pipMargin)
        XCTAssertLessThan(pip.height, pip.width, "the pip keeps the landscape remote's aspect")
    }
}
