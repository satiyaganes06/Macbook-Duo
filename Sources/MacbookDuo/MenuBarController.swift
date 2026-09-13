import AppKit
import DuoCore

/// The only UI: a status item whose menu shows sensor / capture state and the few
/// controls the first version needs.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let engine: EffectEngine
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    // Status lines that change while the menu is open; retitled in place.
    private weak var lidItem: NSMenuItem?
    private weak var stateItem: NSMenuItem?

    init(engine: EffectEngine) {
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacBook Duo")
            button.image?.isTemplate = true
            button.toolTip = "MacBook Duo"
        }
        menu.delegate = self
        statusItem.menu = menu
        engine.onStatusChange = { [weak self] in self?.updateIcon() }
        rebuild()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
        // Only retitle the live status lines while open. Rebuilding the whole menu on a
        // timer would tear down any submenu the user is hovering (visible as flicker).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshLiveItems()
        }
        RunLoop.main.add(refreshTimer!, forMode: .eventTracking)
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Building

    private func updateIcon() {
        let status = engine.status()
        let symbol: String
        switch status.state {
        case .paused: symbol = "laptopcomputer.slash"
        case .active: symbol = "laptopcomputer.and.arrow.down"
        default: symbol = status.settings.enabled ? "laptopcomputer" : "laptopcomputer.slash"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacBook Duo")
        statusItem.button?.image?.isTemplate = true
    }

    private func rebuild() {
        let status = engine.status()
        menu.removeAllItems()

        addInfo("MacBook Duo")
        if status.sensorAvailable {
            lidItem = addInfo(Self.lidLine(status))
        } else {
            lidItem = nil
            addInfo("Lid angle sensor not found on this Mac")
            addInfo("Automatic mode unavailable; Preview still works")
        }
        stateItem = addInfo(Self.stateLine(status))
        if status.reduceMotion {
            addInfo("Reduce Motion is on: using a simple fade")
        }
        if !status.screenRecordingGranted {
            addInfo("Screen Recording permission needed")
        }
        if let error = status.lastError {
            addInfo("Last error: \(error)")
        }

        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = status.settings.enabled ? .on : .off
        menu.addItem(enabled)

        let styleMenu = NSMenu()
        for style in EffectStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = status.settings.style == style ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let preview = NSMenuItem(title: "Preview Effect", action: #selector(runPreview), keyEquivalent: "p")
        preview.target = self
        preview.isEnabled = status.screenRecordingGranted || status.settings.style == .fade || status.reduceMotion
        menu.addItem(preview)

        let calibrate = NSMenuItem(title: "Use Current Angle as Resting Position", action: #selector(calibrate), keyEquivalent: "")
        calibrate.target = self
        calibrate.isEnabled = status.sensorAvailable && status.sensorAngle != nil
        menu.addItem(calibrate)

        let pauseTitle = status.state == .paused ? "Resume" : "Emergency Stop"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "f")
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.target = self
        menu.addItem(pause)

        if !status.screenRecordingGranted {
            let settingsItem = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
            settingsItem.target = self
            menu.addItem(settingsItem)
            let resetItem = NSMenuItem(title: "Reset Screen Recording Permission…", action: #selector(resetPermission), keyEquivalent: "")
            resetItem.target = self
            resetItem.toolTip = "Clears a stale grant from an earlier build so macOS asks again"
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacBook Duo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func addInfo(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    /// Updates only the titles of the live status lines; keeps submenus intact.
    private func refreshLiveItems() {
        let status = engine.status()
        if let lidItem {
            let title = Self.lidLine(status)
            if lidItem.title != title { lidItem.title = title }
        }
        if let stateItem {
            let title = Self.stateLine(status)
            if stateItem.title != title { stateItem.title = title }
        }
    }

    private static func lidLine(_ status: EngineStatus) -> String {
        let angle = status.sensorAngle.map { String(format: "%.0f°", $0) } ?? "—"
        let reference = status.referenceAngle.map { String(format: "%.0f°", $0) } ?? "calibrating…"
        return "Lid: \(angle)   Resting: \(reference)"
    }

    private static func stateLine(_ status: EngineStatus) -> String {
        var line = "State: \(status.state.rawValue)"
        if status.previewRunning { line += " (preview)" }
        if status.state == .active {
            line += String(format: "  %.0f%%", status.visualProgress * 100)
        }
        return line
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        engine.setEnabled(!engine.status().settings.enabled)
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = EffectStyle(rawValue: raw) else { return }
        engine.setStyle(style)
    }

    @objc private func runPreview() {
        engine.runPreview()
    }

    @objc private func calibrate() {
        engine.calibrateNow()
    }

    @objc private func togglePause() {
        engine.togglePause()
    }

    @objc private func resetPermission() {
        engine.resetScreenRecordingPermission()
    }

    @objc private func openPrivacySettings() {
        engine.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
