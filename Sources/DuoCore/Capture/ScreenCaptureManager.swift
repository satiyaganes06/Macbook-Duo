import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit
import os

/// Streams the built-in display into a `FrameStore` with ScreenCaptureKit.
///
/// The app's own process is excluded from the filter (and the overlay window has
/// `sharingType = .none`) so the effect never captures itself. Frames stay in
/// memory only; nothing is written to disk or sent anywhere.
public final class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    public enum CaptureError: LocalizedError {
        case permissionDenied
        case displayNotShareable
        case alreadyRunning

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission is required"
            case .displayNotShareable: return "The built-in display is not available for capture"
            case .alreadyRunning: return "Capture is already running"
            }
        }
    }

    public let frameStore: FrameStore
    /// Called on the capture queue when the first complete frame of a session arrives.
    public var onFirstFrame: (() -> Void)?
    /// Called on the capture queue when the stream stops on its own (error or system).
    public var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private var receivedFrame = false
    private let outputQueue = DispatchQueue(label: "duo.capture", qos: .userInteractive)
    private let log = Logger(subsystem: "com.satiyaganes.MacbookDuo", category: "capture")

    public init(frameStore: FrameStore) {
        self.frameStore = frameStore
    }

    public var isRunning: Bool { stream != nil }

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func start(displayID: CGDirectDisplayID, pixelSize: CGSize, frameRate: Int) async throws {
        guard stream == nil else { throw CaptureError.alreadyRunning }
        guard Self.hasPermission() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotShareable
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }

        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.scalesToFit = false
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        receivedFrame = false
        try await stream.startCapture()
        self.stream = stream
        log.notice("Capture started \(Int(pixelSize.width))x\(Int(pixelSize.height)) @ \(frameRate) fps")
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            log.debug("stopCapture: \(error.localizedDescription)")
        }
        frameStore.clear()
        log.notice("Capture stopped")
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        guard frameStore.store(pixelBuffer: pixelBuffer, time: CACurrentMediaTime()) else { return }
        if !receivedFrame {
            receivedFrame = true
            onFirstFrame?()
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture stopped with error: \(error.localizedDescription)")
        outputQueue.async { [self] in
            self.stream = nil
            frameStore.clear()
            onStopped?(error)
        }
    }
}
