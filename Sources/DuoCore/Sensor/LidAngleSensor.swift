import Foundation
import IOKit.hid
import QuartzCore
import os

/// Reads the continuous lid-angle sensor found in Apple silicon MacBooks.
///
/// The sensor is an IOHID device (Apple vendor `0x05AC`, product `0x8104`, HID sensor
/// usage page `0x20`, usage `0x8A`) that only answers feature-report polls: report ID 1
/// carries the angle in degrees as a little-endian 16-bit value at bytes 1-2, where
/// `0` is closed. Intel machines and some early models only expose an open/closed
/// switch and are reported as unavailable.
public final class LidAngleSensor {
    public struct Reading: Equatable {
        public var angle: Double
        public var time: TimeInterval
        public init(angle: Double, time: TimeInterval) {
            self.angle = angle
            self.time = time
        }
    }

    public let productName: String
    /// Called on the sensor queue for every successful poll.
    public var onReading: ((Reading) -> Void)?
    /// Called on the sensor queue once polling has failed repeatedly.
    public var onFailure: ((String) -> Void)?

    /// Poll rates. The sensor is polled quickly while the lid is moving and slowly at rest.
    public var activeHz: Double = 120
    public var idleHz: Double = 30
    /// How long after the last change the fast rate is kept.
    public var activeHold: TimeInterval = 1.5

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "duo.lid-sensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastAngle: Double?
    private var lastChange: TimeInterval = 0
    private var currentHz: Double = 0
    private var consecutiveFailures = 0
    private let log = Logger(subsystem: "com.satiyaganes.MacbookDuo", category: "sensor")

    private static let usagePage = 0x0020
    private static let usage = 0x008A
    private static let appleVendorID = 0x05AC

    /// Finds the lid-angle sensor, or `nil` when this Mac does not expose one.
    public static func discover() -> LidAngleSensor? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: usagePage,
            kIOHIDPrimaryUsageKey as String: usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              !devices.isEmpty else {
            return nil
        }
        // Prefer Apple's own sensor if more than one device matches the usage.
        let sorted = devices.sorted { a, _ in
            (IOHIDDeviceGetProperty(a, kIOHIDVendorIDKey as CFString) as? Int) == appleVendorID
        }
        for device in sorted {
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            let sensor = LidAngleSensor(manager: manager, device: device)
            if sensor.readOnce() != nil {
                return sensor
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return nil
    }

    private init(manager: IOHIDManager, device: IOHIDDevice) {
        self.manager = manager
        self.device = device
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        self.productName = name ?? "Apple lid angle sensor" + (transport.map { " (\($0))" } ?? "")
    }

    deinit {
        timer?.cancel()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Synchronous single read. Returns degrees, or `nil` on failure / implausible data.
    public func readOnce() -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        let angle = Double(raw)
        // Plausible physical range. Anything else is a glitch we should not render.
        guard angle >= 0, angle <= 200 else { return nil }
        return angle
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            lastChange = CACurrentMediaTime()
            schedule(hz: activeHz)
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            currentHz = 0
        }
    }

    private func schedule(hz: Double) {
        guard hz != currentHz else { return }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / hz
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        currentHz = hz
    }

    private func poll() {
        let now = CACurrentMediaTime()
        guard let angle = readOnce() else {
            consecutiveFailures += 1
            if consecutiveFailures == 20 {
                log.error("Lid sensor stopped answering")
                onFailure?("Lid angle sensor stopped responding")
            }
            return
        }
        consecutiveFailures = 0
        if angle != lastAngle {
            lastAngle = angle
            lastChange = now
        }
        onReading?(Reading(angle: angle, time: now))
        let wantedHz = (now - lastChange) < activeHold ? activeHz : idleHz
        if wantedHz != currentHz {
            schedule(hz: wantedHz)
        }
    }
}
