import Foundation
import Metal
import QuartzCore
import simd

/// GPU side of the effect: builds a small blur pyramid from the captured frame and
/// composites the chosen style (Duo, Shutter, Iris, Roll, Accordion) into the
/// overlay's drawable.
///
/// All textures and pipelines are created once and reused; a frame costs a handful
/// of tiny render passes and one composite.
public final class FoldRenderer {
    public struct Parameters: Equatable {
        public var style: EffectStyle
        /// Eased effect progress, 0 = at rest, 1 = closed.
        public var progress: Double
        /// Duo only: pane tilt in radians.
        public var tilt: Double
        public var viewDistance: Double
        public var viewerHeight: Double
        public var blurLevel: Double
        public var brightness: Double

        public init(
            style: EffectStyle = .duo,
            progress: Double,
            tilt: Double = 0,
            viewDistance: Double = 1.8,
            viewerHeight: Double = 0.45,
            blurLevel: Double = 0,
            brightness: Double = 1
        ) {
            self.style = style
            self.progress = progress
            self.tilt = tilt
            self.viewDistance = viewDistance
            self.viewerHeight = viewerHeight
            self.blurLevel = blurLevel
            self.brightness = brightness
        }
    }

    // Keep in sync with EffectUniforms in Shaders.metal.
    private struct EffectUniforms {
        var tilt: Float
        var viewDistance: Float
        var viewerHeight: Float
        var blurLevel: Float
        var brightness: Float
        var progress: Float
        var aspect: Float
        var pad0: Float = 0
    }

    public static let pyramidLevels = 4

    public let device: MTLDevice
    public let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let stylePipelines: [EffectStyle: MTLRenderPipelineState]
    private let fadePipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private var pyramid: BlurPyramid?

    /// Test seam: invoked with the command buffer and the drawable's texture after the
    /// frame is encoded and before it is committed, so tests can read pixels back.
    public var onFrameEncoded: ((MTLCommandBuffer, MTLTexture) -> Void)?

    public enum RendererError: LocalizedError {
        case noCommandQueue
        case missingFunction(String)
        public var errorDescription: String? {
            switch self {
            case .noCommandQueue: return "Could not create a Metal command queue"
            case .missingFunction(let name): return "Metal function missing: \(name)"
            }
        }
    }

    public init(device: MTLDevice, layer: CAMetalLayer, library: MTLLibrary) throws {
        self.device = device
        self.layer = layer
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        commandQueue = queue

        func pipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw RendererError.missingFunction(vertex + "/" + fragment)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = v
            descriptor.fragmentFunction = f
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        var pipelines: [EffectStyle: MTLRenderPipelineState] = [:]
        pipelines[.duo] = try pipeline(vertex: "foldVertex", fragment: "foldFragment")
        pipelines[.shutter] = try pipeline(vertex: "fullscreenVertex", fragment: "shutterFragment")
        pipelines[.iris] = try pipeline(vertex: "fullscreenVertex", fragment: "irisFragment")
        pipelines[.roll] = try pipeline(vertex: "fullscreenVertex", fragment: "rollFragment")
        pipelines[.accordion] = try pipeline(vertex: "fullscreenVertex", fragment: "accordionFragment")
        stylePipelines = pipelines
        fadePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "fadeFragment")
        downsamplePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "downsampleFragment")
        blurPipeline = try pipeline(vertex: "fullscreenVertex", fragment: "blurFragment")
    }

    /// Draws the captured frame with the style in `parameters`.
    public func render(frame: FrameStore.Frame, parameters: Parameters) {
        guard let pipeline = stylePipelines[parameters.style] else {
            renderFade(opacity: 1 - parameters.brightness)
            return
        }
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let neededLevels = min(Self.pyramidLevels, Int(ceil(max(0, parameters.blurLevel))))
        var levelTextures: [MTLTexture] = Array(repeating: frame.texture, count: Self.pyramidLevels + 1)
        if neededLevels > 0 {
            let pyramid = pyramidFor(source: frame.texture)
            pyramid.build(
                from: frame.texture,
                sequence: frame.sequence,
                levels: neededLevels,
                commandBuffer: commandBuffer,
                downsample: downsamplePipeline,
                blur: blurPipeline
            )
            for i in 1...neededLevels {
                levelTextures[i] = pyramid.texture(level: i)
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Composite \(parameters.style.rawValue)"
        encoder.setRenderPipelineState(pipeline)
        let size = layer.drawableSize
        var uniforms = EffectUniforms(
            tilt: Float(parameters.tilt),
            viewDistance: Float(parameters.viewDistance),
            viewerHeight: Float(parameters.viewerHeight),
            blurLevel: Float(min(parameters.blurLevel, Double(Self.pyramidLevels))),
            brightness: Float(min(1, max(0, parameters.brightness))),
            progress: Float(min(1, max(0, parameters.progress))),
            aspect: Float(size.height > 0 ? size.width / size.height : 1.6)
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        for (index, texture) in levelTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        if parameters.style == .duo {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()

        onFrameEncoded?(commandBuffer, drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Draws a plain black veil at the given opacity (Reduce Motion / Fade style).
    public func renderFade(opacity: Double) {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Fade"
        encoder.setRenderPipelineState(fadePipeline)
        var alpha = Float(min(1, max(0, opacity)))
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        onFrameEncoded?(commandBuffer, drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Clears the layer to fully transparent (used right before the overlay hides).
    public func renderClear() {
        renderFade(opacity: 0)
    }

    private func pyramidFor(source: MTLTexture) -> BlurPyramid {
        if let pyramid, pyramid.sourceWidth == source.width, pyramid.sourceHeight == source.height {
            return pyramid
        }
        let created = BlurPyramid(device: device, sourceWidth: source.width, sourceHeight: source.height, levels: Self.pyramidLevels)
        pyramid = created
        return created
    }
}

/// Progressively smaller, Gaussian-smoothed copies of the frame. Level `i` is
/// `1 / 2^i` of the source size and roughly `3 * 2^i` px of blur when magnified.
/// Textures are allocated once per source size and rebuilt only when the frame changes.
final class BlurPyramid {
    let sourceWidth: Int
    let sourceHeight: Int
    private let levels: [MTLTexture]
    private let scratch: [MTLTexture]
    private var builtSequence: UInt64 = 0
    private var builtLevels = 0

    init(device: MTLDevice, sourceWidth: Int, sourceHeight: Int, levels count: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        var levels: [MTLTexture] = []
        var scratch: [MTLTexture] = []
        for i in 1...count {
            let width = max(1, sourceWidth >> i)
            let height = max(1, sourceHeight >> i)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            let level = device.makeTexture(descriptor: descriptor)!
            level.label = "Blur level \(i)"
            let tmp = device.makeTexture(descriptor: descriptor)!
            tmp.label = "Blur scratch \(i)"
            levels.append(level)
            scratch.append(tmp)
        }
        self.levels = levels
        self.scratch = scratch
    }

    func texture(level: Int) -> MTLTexture {
        levels[level - 1]
    }

    func build(
        from source: MTLTexture,
        sequence: UInt64,
        levels wanted: Int,
        commandBuffer: MTLCommandBuffer,
        downsample: MTLRenderPipelineState,
        blur: MTLRenderPipelineState
    ) {
        let wanted = min(max(wanted, 1), levels.count)
        if sequence == builtSequence && builtLevels >= wanted { return }
        let startLevel = sequence == builtSequence ? builtLevels + 1 : 1

        for i in startLevel...wanted {
            let input = i == 1 ? source : levels[i - 2]
            let target = levels[i - 1]
            let tmp = scratch[i - 1]
            fullscreenPass(commandBuffer, pipeline: downsample, input: input, output: target, direction: nil)
            fullscreenPass(commandBuffer, pipeline: blur, input: target, output: tmp, direction: SIMD2<Float>(1, 0))
            fullscreenPass(commandBuffer, pipeline: blur, input: tmp, output: target, direction: SIMD2<Float>(0, 1))
        }
        builtSequence = sequence
        builtLevels = wanted
    }

    private func fullscreenPass(
        _ commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        input: MTLTexture,
        output: MTLTexture,
        direction: SIMD2<Float>?
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        if var direction {
            encoder.setFragmentBytes(&direction, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
