import AppKit
import Foundation
import Metal
import QuartzCore
import os

public enum EffectStyle: String, CaseIterable {
    /// The pane tilts around the hinge, expands, blurs and dims to black.
    case duo
    /// Rigid panels slide down behind one another with overlapping edges and contact shadows.
    case shutter
    /// Dark blades close around the desktop with a restrained mechanical twist.
    case iris
    /// The desktop winds down onto a roller at the hinge like a retracting screen.
    case roll
    /// The desktop pleats into horizontal folds that collapse toward the hinge.
    case accordion
    /// A plain black fade. Also used automatically when Reduce Motion is on.
    case fade

    public var title: String {
        switch self {
        case .duo: return "Duo"
        case .shutter: return "Shutter"
        case .iris: return "Iris"
        case .roll: return "Roll"
        case .accordion: return "Accordion"
        case .fade: return "Fade"
        }
    }

    public var summary: String {
        switch self {
        case .duo: return "Desktop tilts around the hinge, expands, softens and disappears"
        case .shutter: return "Rigid panels slide behind one another with contact shadows"
        case .iris: return "Dark blades overlap around the desktop with a mechanical twist"
        case .roll: return "Desktop winds onto a roller at the hinge like a projector screen"
        case .accordion: return "Desktop pleats into folds that collapse toward the hinge"
        case .fade: return "Simple fade to black, no capture needed"
        }
    }

    /// Whether the style needs the captured desktop (everything but the plain fade).
    public var usesDesktop: Bool { self != .fade }
}

public struct EffectSettings: Equatable {
    public var enabled: Bool = true
    public var style: EffectStyle = .duo
    public var progressModel = LidProgressModel()
    public var curves = EffectCurves()
    public var trackerConfiguration = ReferenceAngleTracker.Configuration()
    /// Filter response in rad/s. Settle time is about `4 / omega`.
    public var filterOmega: Double = 32
    /// Raw movement (degrees) that starts capture ahead of the dead zone.
    public var armThresholdDegrees: Double = 1.0
    /// A drop of this many degrees inside `motionWindow` counts as "closing".
    public var motionThresholdDegrees: Double = 1.0
    public var motionWindow: TimeInterval = 1.5
    /// How long the visual must sit at rest before the overlay hides.
    public var settleDelay: TimeInterval = 0.4
    /// How long capture keeps running after the overlay hides.
    public var captureLinger: TimeInterval = 2.0
    /// No sensor reading for this long while active clears the effect.
    public var sensorTimeout: TimeInterval = 2.0
    public var captureFrameRate: Int = 60
    public var renderFrameRate: Double = 60
    /// Resting angle used for the preview when no sensor has produced one.
    public var previewFallbackReference: Double = 110
    public var previewDuration: TimeInterval = 5

    public init() {}

    private static let enabledKey = "duo.enabled"
    private static let styleKey = "duo.style"

    public static func load(defaults: UserDefaults = .standard) -> EffectSettings {
        var settings = EffectSettings()
        if defaults.object(forKey: enabledKey) != nil {
            settings.enabled = defaults.bool(forKey: enabledKey)
        }
        if let raw = defaults.string(forKey: styleKey), let style = EffectStyle(rawValue: raw) {
            settings.style = style
        }
        return settings
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(style.rawValue, forKey: Self.styleKey)
    }
}

public enum EngineState: String {
    /// Nothing running; the sensor is polled slowly.
    case idle
    /// Capture is starting up.
    case arming
    /// Capture is running, overlay hidden.
    case ready
    /// Overlay visible and rendering.
    case active
    /// Emergency-stopped by the user; nothing runs until resumed.
    case paused
}

/// Snapshot for the menu bar UI.
public struct EngineStatus {
    public var state: EngineState
    public var sensorAvailable: Bool
    public var sensorName: String?
    public var sensorAngle: Double?
    public var referenceAngle: Double?
    public var targetProgress: Double
    public var visualProgress: Double
    public var screenRecordingGranted: Bool
    public var reduceMotion: Bool
    public var previewRunning: Bool
    public var lastError: String?
    public var settings: EffectSettings
}

/// Orchestrates the whole effect. Every piece of mutable state lives on `queue`;
/// AppKit work is hopped to the main thread and back asynchronously (never with a
/// synchronous hop in either direction, so the UI can query status safely).
public final class EffectEngine {
    public private(set) var settings: EffectSettings
    /// Fired on the main thread whenever something the menu shows may have changed.
    public var onStatusChange: (() -> Void)?

    private let queue = DispatchQueue(label: "duo.engine", qos: .userInteractive)
    private let log = Logger(subsystem: "com.satiyaganes.MacbookDuo", category: "engine")

    private let device: MTLDevice?
    private var library: MTLLibrary?
    private let frameStore: FrameStore?
    private var capture: ScreenCaptureManager?
    private var sensor: LidAngleSensor?

    private var overlay: OverlayWindow?      // main-thread object
    private var renderer: FoldRenderer?
    private var display: BuiltInDisplay?
    private var reduceMotion = false

    private var state: EngineState = .idle
    private var tracker: ReferenceAngleTracker
    private var filter: CriticallyDampedFilter
    private var lastReading: LidAngleSensor.Reading?
    private var recentReadings: [LidAngleSensor.Reading] = []
    private var reference: Double?
    private var rawMovement: Double = 0
    private var targetMovement: Double = 0
    private var targetProgress: Double = 0
    private var visualProgress: Double = 0
    private var armBlockedUntilRest = false
    private var lastError: String?

    private var renderTimer: DispatchSourceTimer?
    private var lastTick: TimeInterval = 0
    private var settledSince: TimeInterval?
    private var captureStopWork: DispatchWorkItem?

    private var previewTimer: DispatchSourceTimer?
    private var previewStart: TimeInterval?
    private var previewReference: Double = 110
    private var previewActive = false

    private var observers: [NSObjectProtocol] = []

    public init(settings: EffectSettings) {
        self.settings = settings
        tracker = ReferenceAngleTracker(configuration: settings.trackerConfiguration)
        filter = CriticallyDampedFilter(omega: settings.filterOmega)
        device = MTLCreateSystemDefaultDevice()
        if let device {
            frameStore = FrameStore(device: device)
        } else {
            frameStore = nil
        }
    }

    // MARK: - Lifecycle (call from the main thread)

    public func start() {
        if let device {
            do {
                library = try ShaderLibrary.load(device: device)
            } catch {
                lastError = error.localizedDescription
                log.error("Shader load failed: \(error.localizedDescription)")
            }
        } else {
            lastError = "Metal is not available on this Mac"
        }
        if let frameStore {
            let capture = ScreenCaptureManager(frameStore: frameStore)
            capture.onFirstFrame = { [weak self] in
                self?.queue.async { self?.evaluateActivation() }
            }
            capture.onStopped = { [weak self] error in
                self?.queue.async { self?.captureDidStop(error: error) }
            }
            self.capture = capture
        }

        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self?.queue.async { self?.reduceMotion = reduce }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { self?.recentReadings.removeAll() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { self?.screenParametersChanged() }
        })

        if let sensor = LidAngleSensor.discover() {
            self.sensor = sensor
            sensor.onReading = { [weak self] reading in
                self?.queue.async { self?.handle(reading: reading) }
            }
            sensor.onFailure = { [weak self] message in
                self?.queue.async { self?.clearEffect(reason: message, to: .idle, blockUntilRest: true) }
            }
            sensor.start()
            log.notice("Lid sensor: \(sensor.productName)")
            DuoLog.note("sensor found: \(sensor.productName), first read \(sensor.readOnce().map { "\($0)°" } ?? "n/a")")
        } else {
            log.notice("No continuous lid-angle sensor on this Mac; automatic mode disabled")
            DuoLog.note("no lid-angle sensor found")
        }

        let granted = ScreenCaptureManager.hasPermission()
        DuoLog.note("shaders \(library == nil ? "FAILED" : "ok"), metal \(device == nil ? "missing" : "ok"), screen recording \(granted ? "granted" : "not granted"), enabled \(settings.enabled), style \(settings.style.rawValue), reduceMotion \(reduceMotion)")
        if let lastError { DuoLog.note("error: \(lastError)") }
        if settings.enabled, !granted {
            ScreenCaptureManager.requestPermission()
        }
        notifyStatus()
    }

    public func shutdown() {
        sensor?.stop()
        queue.sync {
            clearEffect(reason: nil, to: .idle, blockUntilRest: false)
        }
    }

    // MARK: - Commands (thread-safe)

    public func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            settings.enabled = enabled
            settings.save()
            if !enabled {
                clearEffect(reason: nil, to: .idle, blockUntilRest: false)
            } else if state == .paused {
                state = .idle
            }
            notifyStatus()
        }
        if enabled, !ScreenCaptureManager.hasPermission() {
            ScreenCaptureManager.requestPermission()
        }
    }

    public func setStyle(_ style: EffectStyle) {
        queue.async { [self] in
            guard settings.style != style else { return }
            settings.style = style
            settings.save()
            // Styles use the overlay differently; restart from a clean state.
            clearEffect(reason: nil, to: state == .paused ? .paused : .idle, blockUntilRest: false)
            notifyStatus()
        }
    }

    /// Emergency stop / resume (bound to ⌃⌥⌘F).
    public func togglePause() {
        queue.async { [self] in
            if state == .paused {
                state = .idle
                armBlockedUntilRest = true
                log.notice("Resumed")
            } else {
                clearEffect(reason: nil, to: .paused, blockUntilRest: false)
                log.notice("Emergency stop")
            }
            notifyStatus()
        }
    }

    /// Uses the current lid angle as the resting position.
    public func calibrateNow() {
        queue.async { [self] in
            guard let reading = lastReading else { return }
            tracker.calibrate(to: reading.angle, time: reading.time)
            reference = reading.angle
            apply(angle: reading.angle, reference: reading.angle)
            notifyStatus()
        }
    }

    public func requestPermission() {
        ScreenCaptureManager.requestPermission()
        notifyStatus()
    }

    /// Clears a Screen Recording entry left by an earlier build's signature (macOS then
    /// refuses silently and never re-prompts) and asks again so the prompt reappears.
    public func resetScreenRecordingPermission() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? "com.satiyaganes.MacbookDuo"]
        do {
            try task.run()
            task.waitUntilExit()
            log.notice("tccutil reset ScreenCapture exited \(task.terminationStatus)")
        } catch {
            log.error("tccutil failed: \(error.localizedDescription)")
        }
        ScreenCaptureManager.requestPermission()
        notifyStatus()
    }

    /// Plays the whole close-and-reopen arc without touching the lid.
    public func runPreview() {
        queue.async { [self] in
            guard !previewActive, state == .idle || state == .ready else { return }
            previewActive = true
            previewStart = nil
            previewReference = reference ?? settings.previewFallbackReference
            armBlockedUntilRest = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.previewTick() }
            timer.resume()
            previewTimer = timer
            notifyStatus()
        }
    }

    public func status() -> EngineStatus {
        let granted = ScreenCaptureManager.hasPermission()
        return queue.sync {
            EngineStatus(
                state: state,
                sensorAvailable: sensor != nil,
                sensorName: sensor?.productName,
                sensorAngle: lastReading?.angle,
                referenceAngle: reference,
                targetProgress: targetProgress,
                visualProgress: visualProgress,
                screenRecordingGranted: granted,
                reduceMotion: reduceMotion,
                previewRunning: previewActive,
                lastError: lastError,
                settings: settings
            )
        }
    }

    // MARK: - Sensor input (engine queue)

    private func handle(reading: LidAngleSensor.Reading) {
        lastReading = reading
        recentReadings.append(reading)
        let cutoff = reading.time - settings.motionWindow
        recentReadings.removeAll { $0.time < cutoff }
        if previewActive { return }
        guard let ref = tracker.update(angle: reading.angle, time: reading.time) else {
            return
        }
        if reference != ref {
            reference = ref
            DuoLog.note("resting angle: \(ref)°")
            notifyStatus()
        }
        apply(angle: reading.angle, reference: ref)
    }

    private func apply(angle: Double, reference ref: Double) {
        let model = settings.progressModel
        rawMovement = model.rawMovement(reference: ref, angle: angle)
        targetMovement = model.effectiveMovement(reference: ref, angle: angle)
        targetProgress = model.progress(effectiveMovement: targetMovement, reference: ref)
        filter.target = targetMovement
        if targetMovement <= 0 {
            armBlockedUntilRest = false
        }

        switch state {
        case .idle:
            guard settings.enabled, !armBlockedUntilRest else { return }
            if targetMovement > 0 || (rawMovement >= settings.armThresholdDegrees && isClosing) {
                arm()
            }
        case .ready:
            evaluateActivation()
        case .arming, .active, .paused:
            break
        }
    }

    /// True when the lid dropped by more than the motion threshold inside the window.
    private var isClosing: Bool {
        guard let newest = recentReadings.last else { return false }
        let highest = recentReadings.map(\.angle).max() ?? newest.angle
        return highest - newest.angle >= settings.motionThresholdDegrees
    }

    private var usesCapture: Bool {
        settings.style.usesDesktop && !reduceMotion
    }

    // MARK: - Arming / activation

    private func arm() {
        guard state == .idle else { return }
        guard device != nil, library != nil, frameStore != nil else {
            lastError = lastError ?? "Renderer unavailable"
            armBlockedUntilRest = true
            return
        }
        if usesCapture, !ScreenCaptureManager.hasPermission() {
            lastError = "Screen Recording permission needed (System Settings > Privacy & Security)"
            armBlockedUntilRest = true
            log.error("Not arming: Screen Recording permission missing")
            DuoLog.note("not arming: screen recording permission missing")
            ScreenCaptureManager.requestPermission()
            notifyStatus()
            return
        }
        state = .arming
        captureStopWork?.cancel()
        captureStopWork = nil
        log.notice("Arming")
        DuoLog.note("arming (raw movement \(String(format: "%.1f", rawMovement))°)")
        notifyStatus()

        DispatchQueue.main.async { [self] in
            guard let display = BuiltInDisplay.current() else {
                queue.async {
                    self.lastError = "Built-in display not found"
                    self.state = .idle
                    self.armBlockedUntilRest = true
                    self.notifyStatus()
                }
                return
            }
            let overlay = ensureOverlay(for: display)
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            queue.async { self.continueArming(display: display, overlay: overlay, reduceMotion: reduce) }
        }
    }

    /// Main thread. Creates (or recreates) the overlay to match the display.
    private func ensureOverlay(for display: BuiltInDisplay) -> OverlayWindow? {
        guard let device else { return nil }
        if let overlay, overlay.pixelSize == display.pixelSize, overlay.frame == display.screen.frame {
            return overlay
        }
        overlay?.orderOut(nil)
        let window = OverlayWindow(display: display, device: device)
        overlay = window
        return window
    }

    private func continueArming(display: BuiltInDisplay, overlay: OverlayWindow?, reduceMotion reduce: Bool) {
        guard state == .arming else { return }
        guard let overlay, let device, let library else {
            lastError = "Overlay unavailable"
            state = .idle
            armBlockedUntilRest = true
            return
        }
        self.display = display
        reduceMotion = reduce
        if renderer == nil || renderer?.layer !== overlay.metalLayer {
            do {
                renderer = try FoldRenderer(device: device, layer: overlay.metalLayer, library: library)
            } catch {
                lastError = error.localizedDescription
                state = .idle
                armBlockedUntilRest = true
                notifyStatus()
                return
            }
        }
        filter.reset(to: 0)
        filter.target = targetMovement

        guard usesCapture, let capture else {
            state = .ready
            notifyStatus()
            evaluateActivation()
            return
        }
        let displayID = display.displayID
        let pixelSize = display.pixelSize
        let frameRate = settings.captureFrameRate
        Task {
            do {
                try await capture.start(displayID: displayID, pixelSize: pixelSize, frameRate: frameRate)
                self.queue.async {
                    guard self.state == .arming else {
                        Task { await capture.stop() }
                        return
                    }
                    self.state = .ready
                    self.lastError = nil
                    DuoLog.note("capture ready")
                    self.notifyStatus()
                    self.evaluateActivation()
                    self.scheduleCaptureStopIfIdle()
                }
            } catch {
                self.queue.async {
                    self.lastError = error.localizedDescription
                    self.log.error("Capture start failed: \(error.localizedDescription)")
                    DuoLog.note("capture start failed: \(error.localizedDescription)")
                    self.state = .idle
                    self.armBlockedUntilRest = true
                    self.notifyStatus()
                }
            }
        }
    }

    private func evaluateActivation() {
        guard state == .ready, settings.enabled, targetMovement > 0 else { return }
        if usesCapture, frameStore?.latest == nil { return }
        activate()
    }

    private func activate() {
        guard state == .ready, let overlay else { return }
        state = .active
        settledSince = nil
        captureStopWork?.cancel()
        captureStopWork = nil
        lastTick = CACurrentMediaTime()
        log.notice("Effect active")
        DuoLog.note("effect active")
        notifyStatus()
        DispatchQueue.main.async { [self] in
            overlay.orderFrontRegardless()
            queue.async { self.startRenderLoop() }
        }
    }

    private func deactivate() {
        guard state == .active else { return }
        stopRenderLoop()
        renderer?.renderClear()
        filter.reset(to: 0)
        visualProgress = 0
        state = .ready
        hideOverlay()
        log.notice("Effect cleared")
        DuoLog.note("effect cleared")
        notifyStatus()
        scheduleCaptureStopIfIdle()
    }

    private func hideOverlay() {
        guard let overlay else { return }
        DispatchQueue.main.async {
            overlay.orderOut(nil)
        }
    }

    private func scheduleCaptureStopIfIdle() {
        captureStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .ready else { return }
            self.state = .idle
            self.stopCapture()
            self.notifyStatus()
        }
        captureStopWork = work
        queue.asyncAfter(deadline: .now() + settings.captureLinger, execute: work)
    }

    private func stopCapture() {
        guard let capture, capture.isRunning else { return }
        Task { await capture.stop() }
    }

    /// Tears everything down and restores the plain desktop immediately.
    private func clearEffect(reason: String?, to newState: EngineState, blockUntilRest: Bool) {
        if let reason {
            lastError = reason
            log.error("Clearing effect: \(reason)")
            DuoLog.note("clearing effect: \(reason)")
        }
        stopPreview()
        stopRenderLoop()
        captureStopWork?.cancel()
        captureStopWork = nil
        if state == .active {
            renderer?.renderClear()
        }
        hideOverlay()
        stopCapture()
        filter.reset(to: 0)
        visualProgress = 0
        settledSince = nil
        state = newState
        if blockUntilRest {
            armBlockedUntilRest = true
        }
        notifyStatus()
    }

    private func captureDidStop(error: Error?) {
        guard state == .arming || state == .ready || state == .active else { return }
        clearEffect(reason: error?.localizedDescription ?? "Capture stopped", to: .idle, blockUntilRest: true)
    }

    private func screenParametersChanged() {
        // Display set changed (clamshell, external monitor, resolution). Start over.
        if state == .arming || state == .ready || state == .active {
            clearEffect(reason: nil, to: .idle, blockUntilRest: false)
        }
        display = nil
    }

    // MARK: - Render loop (engine queue)

    private func startRenderLoop() {
        guard state == .active, renderTimer == nil else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        let hz = (thermal == .serious || thermal == .critical) ? 30.0 : settings.renderFrameRate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        renderTimer = timer
        lastTick = CACurrentMediaTime()
    }

    private func stopRenderLoop() {
        renderTimer?.cancel()
        renderTimer = nil
    }

    private func tick() {
        guard state == .active, let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.05)
        lastTick = now

        if !previewActive, let reading = lastReading, now - reading.time > settings.sensorTimeout {
            clearEffect(reason: "Lid sensor stopped reporting", to: .idle, blockUntilRest: true)
            return
        }

        let ref = previewActive ? previewReference : (reference ?? settings.previewFallbackReference)
        let visualMovement = filter.step(dt: dt)
        let progress = settings.progressModel.progress(effectiveMovement: visualMovement, reference: ref)
        visualProgress = progress

        if usesCapture {
            if let frame = frameStore?.latest {
                let curves = settings.curves
                let style = settings.style
                let parameters = FoldRenderer.Parameters(
                    style: style,
                    progress: progress,
                    tilt: curves.tiltRadians(effectiveMovementDegrees: visualMovement),
                    viewDistance: curves.viewDistance,
                    viewerHeight: curves.viewerHeight,
                    blurLevel: curves.blurLevel(progress: progress, style: style),
                    brightness: curves.brightness(progress: progress, style: style)
                )
                renderer.render(frame: frame, parameters: parameters)
            }
        } else {
            renderer.renderFade(opacity: settings.curves.fadeOpacity(progress: progress))
        }

        if targetMovement <= 0, visualMovement < 0.05 {
            if settledSince == nil { settledSince = now }
            if now - (settledSince ?? now) >= settings.settleDelay {
                deactivate()
            }
        } else {
            settledSince = nil
        }
    }

    // MARK: - Preview

    private func previewTick() {
        guard previewActive else { return }
        let now = CACurrentMediaTime()
        // Keep the sensor-timeout check happy while we drive the effect ourselves.
        lastReading = LidAngleSensor.Reading(angle: lastReading?.angle ?? previewReference, time: now)

        if previewStart == nil {
            // Hold at rest until capture is ready so the arc starts from a sharp desktop.
            apply(angle: previewReference - settings.progressModel.deadZone - 0.5, reference: previewReference)
            if state == .ready || state == .active {
                previewStart = now
            } else if state == .idle && armBlockedUntilRest {
                stopPreview()
                notifyStatus()
            }
            return
        }
        let t = (now - (previewStart ?? now)) / settings.previewDuration
        if t >= 1 {
            apply(angle: previewReference, reference: previewReference)
            stopPreview()
            notifyStatus()
            return
        }
        let fraction = 0.5 - 0.5 * cos(2 * .pi * t)
        let closed = settings.progressModel.closedAngle - 3
        let angle = previewReference - fraction * (previewReference - closed)
        apply(angle: angle, reference: previewReference)
    }

    private func stopPreview() {
        previewTimer?.cancel()
        previewTimer = nil
        previewActive = false
        previewStart = nil
    }

    // MARK: - Status

    private func notifyStatus() {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?()
        }
    }
}
