import AppKit
import CoreGraphics

/// The MacBook's own panel. The effect is limited to this display; external
/// monitors are left alone.
public struct BuiltInDisplay {
    public let screen: NSScreen
    public let displayID: CGDirectDisplayID
    /// True framebuffer size in pixels (not points, not the "looks like" size).
    public let pixelSize: CGSize

    /// Must be called on the main thread (uses `NSScreen`).
    public static func current() -> BuiltInDisplay? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(id) != 0 else { continue }
            let pixelSize: CGSize
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixelSize = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            } else {
                let scale = screen.backingScaleFactor
                pixelSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            }
            return BuiltInDisplay(screen: screen, displayID: id, pixelSize: pixelSize)
        }
        return nil
    }
}
