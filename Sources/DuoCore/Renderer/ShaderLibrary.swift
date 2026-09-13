import Foundation
import Metal

/// Locates the compiled shaders. Order of preference:
/// 1. `default.metallib` in the app bundle (built by `scripts/build-app.sh`).
/// 2. `Shaders.metal` source in the app bundle, compiled at launch.
/// 3. The source file next to this one, for `swift run` during development.
public enum ShaderLibrary {
    public enum LoadError: LocalizedError {
        case notFound
        public var errorDescription: String? { "Metal shaders not found (default.metallib or Shaders.metal)" }
    }

    public static func load(device: MTLDevice) throws -> MTLLibrary {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "default", withExtension: "metallib"),
           let library = try? device.makeLibrary(URL: url) {
            return library
        }
        var candidates: [URL] = []
        if let url = bundle.url(forResource: "Shaders", withExtension: "metal") {
            candidates.append(url)
        }
        let devSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shaders/Shaders.metal")
        candidates.append(devSource)
        for url in candidates {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            return try device.makeLibrary(source: source, options: options)
        }
        throw LoadError.notFound
    }
}
