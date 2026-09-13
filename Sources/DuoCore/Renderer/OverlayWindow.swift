import AppKit
import Metal
import QuartzCore

/// Borderless, click-through, capture-excluded window that covers the built-in display.
///
/// The window itself is transparent: the fold renderer draws opaque content, so nothing
/// is visible until the first frame lands (no black flash), and the Fade style can draw
/// a translucent veil into the same layer.
public final class OverlayWindow: NSWindow {
    public let metalLayer: CAMetalLayer
    public let pixelSize: CGSize

    public init(display: BuiltInDisplay, device: MTLDevice) {
        let layer = CAMetalLayer()
        metalLayer = layer
        pixelSize = display.pixelSize
        super.init(
            contentRect: display.screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Belt and braces with the ScreenCaptureKit app exclusion: never capture ourselves.
        sharingType = .none

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = display.screen.backingScaleFactor
        layer.drawableSize = display.pixelSize
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.displaySyncEnabled = true
        layer.backgroundColor = NSColor.clear.cgColor

        let view = NSView(frame: NSRect(origin: .zero, size: display.screen.frame.size))
        view.layer = layer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        contentView = view
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
