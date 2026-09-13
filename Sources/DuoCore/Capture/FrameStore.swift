import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Holds exactly one desktop frame: the latest one. Frames are wrapped as Metal
/// textures straight from their IOSurface, never copied, never written anywhere.
public final class FrameStore {
    public struct Frame {
        public let texture: MTLTexture
        public let sequence: UInt64
        public let time: TimeInterval
        // Keeps the IOSurface-backed buffer alive for as long as the texture is used.
        fileprivate let pixelBuffer: CVPixelBuffer
        fileprivate let cvTexture: CVMetalTexture
    }

    private let lock = NSLock()
    private var latestFrame: Frame?
    private var sequence: UInt64 = 0
    private var textureCache: CVMetalTextureCache?

    public init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            return nil
        }
        textureCache = cache
    }

    public var latest: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    /// Wraps the pixel buffer as a texture and makes it the current frame.
    @discardableResult
    public func store(pixelBuffer: CVPixelBuffer, time: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard let textureCache else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return false
        }
        lock.lock()
        sequence += 1
        latestFrame = Frame(texture: texture, sequence: sequence, time: time, pixelBuffer: pixelBuffer, cvTexture: cvTexture)
        lock.unlock()
        return true
    }

    /// Drops the frame so its memory can be released as soon as capture stops.
    public func clear() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }
}
