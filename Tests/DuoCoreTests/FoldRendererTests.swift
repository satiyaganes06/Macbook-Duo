import CoreVideo
import Metal
import QuartzCore
import XCTest
@testable import DuoCore

/// Exercises the real Metal pipeline headlessly: a synthetic desktop frame goes through
/// `FrameStore` (IOSurface-backed pixel buffer -> texture) and `FoldRenderer`, and the
/// drawable is read back so the shader math can be checked against `FoldGeometry`.
final class FoldRendererTests: XCTestCase {
    private let width = 256
    private let height = 160
    private var device: MTLDevice!
    private var layer: CAMetalLayer!
    private var renderer: FoldRenderer!
    private var frameStore: FrameStore!

    /// Every style that draws the captured desktop.
    private let desktopStyles: [EffectStyle] = EffectStyle.allCases.filter(\.usesDesktop)

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        self.device = device
        let library = try ShaderLibrary.load(device: device)
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: width, height: height)
        renderer = try FoldRenderer(device: device, layer: layer, library: library)
        frameStore = try XCTUnwrap(FrameStore(device: device))
    }

    // MARK: Helpers

    /// Builds a Metal-compatible BGRA pixel buffer filled by `fill(x, y) -> (r, g, b)`.
    private func makeFrame(_ fill: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> FrameStore.Frame {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let offset = y * stride + x * 4
                base[offset] = b
                base[offset + 1] = g
                base[offset + 2] = r
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(frameStore.store(pixelBuffer: buffer))
        return try XCTUnwrap(frameStore.latest)
    }

    private func readback(_ draw: () -> Void) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var captured: MTLCommandBuffer?
        renderer.onFrameEncoded = { commandBuffer, drawableTexture in
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(from: drawableTexture, to: target)
            blit.endEncoding()
            captured = commandBuffer
        }
        draw()
        let commandBuffer = try XCTUnwrap(captured, "renderer produced no frame (no drawable available?)")
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private func render(_ frame: FrameStore.Frame, _ parameters: FoldRenderer.Parameters) throws -> [UInt8] {
        try readback { renderer.render(frame: frame, parameters: parameters) }
    }

    /// (r, g, b, a) at a pixel; row 0 is the top of the screen.
    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let o = (y * width + x) * 4
        return (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]), Int(bytes[o + 3]))
    }

    private func gradient(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        (UInt8(x % 256), UInt8(y % 256), UInt8((x + y) % 256))
    }

    private func params(_ style: EffectStyle = .duo, progress: Double = 0, tilt: Double = 0, blur: Double = 0, brightness: Double = 1) -> FoldRenderer.Parameters {
        FoldRenderer.Parameters(style: style, progress: progress, tilt: tilt, viewDistance: 1.8, viewerHeight: 0.45, blurLevel: blur, brightness: brightness)
    }

    /// Mean absolute difference against the gradient source over a coarse grid.
    private func meanDifference(_ out: [UInt8]) -> Double {
        var total = 0.0
        var count = 0.0
        for y in stride(from: 2, to: height, by: 7) {
            for x in stride(from: 2, to: width, by: 7) {
                let p = pixel(out, x, y)
                let (r, g, b) = gradient(x, y)
                total += abs(Double(p.r) - Double(r)) + abs(Double(p.g) - Double(g)) + abs(Double(p.b) - Double(b))
                count += 3
            }
        }
        return total / count
    }

    // MARK: Duo geometry

    func testRestRendersTheDesktopPixelForPixel() throws {
        let frame = try makeFrame(gradient)
        let out = try render(frame, params())
        for (x, y) in [(0, 0), (255, 0), (0, 159), (255, 159), (100, 80), (37, 141), (200, 3)] {
            let p = pixel(out, x, y)
            let (r, g, b) = gradient(x, y)
            XCTAssertEqual(Double(p.r), Double(r), accuracy: 2, "red at \(x),\(y)")
            XCTAssertEqual(Double(p.g), Double(g), accuracy: 2, "green at \(x),\(y)")
            XCTAssertEqual(Double(p.b), Double(b), accuracy: 2, "blue at \(x),\(y)")
            XCTAssertEqual(p.a, 255)
        }
    }

    func testHingeRowStaysPutWhileTopRowMovesUnderTilt() throws {
        let frame = try makeFrame(gradient)
        let out = try render(frame, params(.duo, progress: 0.3, tilt: 30 * .pi / 180))

        // Bottom row = hinge: unchanged (within a texel of bilinear sampling).
        var hingeDiff = 0.0
        for x in stride(from: 4, to: width - 4, by: 8) {
            let p = pixel(out, x, height - 1)
            let (r, _, _) = gradient(x, height - 1)
            hingeDiff = max(hingeDiff, abs(Double(p.r) - Double(r)))
        }
        XCTAssertLessThanOrEqual(hingeDiff, 6, "hinge row drifted")

        // Top row: the pane expanded, so screen pixels now sample interior pane texels.
        // Predict with FoldGeometry: pane point that lands on the screen's top-left corner.
        let geometry = FoldGeometry(tilt: 30 * .pi / 180, viewDistance: 1.8, viewerHeight: 0.45)
        let aspect = Double(width) / Double(height)
        let target = (x: -aspect / 2, y: 1.0)
        var best = (x: 0.0, y: 0.0, err: Double.infinity)
        for py in stride(from: 0.0, through: 1.0, by: 0.002) {
            for px in stride(from: -aspect / 2, through: 0, by: 0.004) {
                let p = geometry.project(x: px, y: py)
                let err = abs(p.x - target.x) + abs(p.y - target.y)
                if err < best.err { best = (px, py, err) }
            }
        }
        XCTAssertLessThan(best.err, 0.02, "could not invert the projection")
        let expectedX = Int(((best.x / aspect) + 0.5) * Double(width))
        let expectedY = Int((1 - best.y) * Double(height))
        let p = pixel(out, 0, 0)
        XCTAssertEqual(Double(p.r), Double(expectedX % 256), accuracy: 6, "top-left should show pane texel x≈\(expectedX)")
        XCTAssertEqual(Double(p.g), Double(expectedY % 256), accuracy: 6, "top-left should show pane texel y≈\(expectedY)")
        XCTAssertGreaterThan(expectedX, 10, "a 30° tilt should pull the corner well into the pane")
    }

    // MARK: Every style

    func testEveryStyleIsIdentityAtRest() throws {
        let frame = try makeFrame(gradient)
        for style in desktopStyles {
            let out = try render(frame, params(style, progress: 0))
            XCTAssertLessThan(meanDifference(out), 1.0, "\(style) is not identity at rest")
            // Corners specifically: the iris and shutter edges live there.
            for (x, y) in [(0, 0), (255, 0), (0, 159), (255, 159)] {
                let p = pixel(out, x, y)
                let (r, g, b) = gradient(x, y)
                XCTAssertEqual(Double(p.r + p.g + p.b), Double(Int(r) + Int(g) + Int(b)), accuracy: 6, "\(style) corner \(x),\(y)")
            }
        }
    }

    func testEveryStyleVisiblyChangesTheImageMidway() throws {
        let frame = try makeFrame(gradient)
        for style in desktopStyles {
            let out = try render(frame, params(style, progress: 0.6, tilt: 45 * .pi / 180))
            XCTAssertGreaterThan(meanDifference(out), 10, "\(style) barely changes the desktop at 60%")
        }
    }

    func testEveryStyleEndsBlack() throws {
        let frame = try makeFrame(gradient)
        for style in desktopStyles {
            let out = try render(frame, params(style, progress: 1, tilt: 70 * .pi / 180, brightness: 0))
            for (x, y) in [(0, 0), (128, 80), (255, 159), (30, 150)] {
                let p = pixel(out, x, y)
                XCTAssertEqual(p.r + p.g + p.b, 0, "\(style) not black at \(x),\(y)")
                XCTAssertEqual(p.a, 255)
            }
        }
    }

    func testShutterKeepsTheHingePanelAndStacksTheRest() throws {
        let frame = try makeFrame(gradient)
        let out = try render(frame, params(.shutter, progress: 0.5))
        // The bottom panel (lowest sixth) never moves: its rows are untouched.
        for x in [10, 128, 240] {
            let p = pixel(out, x, height - 2)
            let (r, g, _) = gradient(x, height - 2)
            XCTAssertEqual(Double(p.r), Double(r), accuracy: 3)
            XCTAssertEqual(Double(p.g), Double(g), accuracy: 3)
        }
        // Above the compressed stack is the wall: black.
        let top = pixel(out, 128, 2)
        XCTAssertEqual(top.r + top.g + top.b, 0, "top of screen should be behind the stack")
    }

    func testIrisLeavesTheCentreOpenUntilLate() throws {
        let frame = try makeFrame(gradient)
        let mid = try render(frame, params(.iris, progress: 0.5))
        let centre = pixel(mid, 128, 80)
        let (r, g, _) = gradient(128, 80)
        XCTAssertGreaterThan(centre.r + centre.g, (Int(r) + Int(g)) / 2, "centre should still show the desktop at 50%")
        let corner = pixel(mid, 2, 2)
        XCTAssertLessThan(corner.r + corner.g + corner.b, 120, "corner should be covered by a dark blade at 50%")
        let late = try render(frame, params(.iris, progress: 0.98))
        let centreLate = pixel(late, 128, 80)
        XCTAssertLessThan(centreLate.r + centreLate.g + centreLate.b, 120, "aperture should be nearly shut at 98%")
    }

    // MARK: Blur and fade

    func testBlurSmoothsHighFrequencyContent() throws {
        let frame = try makeFrame { x, _ in
            let v: UInt8 = (x / 4) % 2 == 0 ? 0 : 255
            return (v, v, v)
        }
        func contrast(_ bytes: [UInt8]) -> Int {
            var lo = 255, hi = 0
            for x in 64..<192 { let p = pixel(bytes, x, 80); lo = min(lo, p.g); hi = max(hi, p.g) }
            return hi - lo
        }
        let sharp = try render(frame, params(blur: 0))
        XCTAssertEqual(contrast(sharp), 255)
        let soft = try render(frame, params(blur: 2))
        XCTAssertLessThan(contrast(soft), 60, "blur level 2 should nearly flatten a 4px stripe pattern")
        let softer = try render(frame, params(blur: 4))
        // Both are essentially flat here; allow a couple of levels of quantization noise.
        XCTAssertLessThanOrEqual(contrast(softer), contrast(soft) + 3)
        var sum = 0
        for x in 64..<192 { sum += pixel(soft, x, 80).g }
        XCTAssertEqual(Double(sum) / 128, 127.5, accuracy: 12)
    }

    func testFadeWritesTranslucentBlack() throws {
        let out = try readback { renderer.renderFade(opacity: 0.5) }
        let p = pixel(out, 128, 80)
        XCTAssertEqual(p.r + p.g + p.b, 0)
        XCTAssertEqual(Double(p.a), 127.5, accuracy: 1.5)
        let clear = try readback { renderer.renderClear() }
        XCTAssertEqual(pixel(clear, 10, 10).a, 0)
    }
}
