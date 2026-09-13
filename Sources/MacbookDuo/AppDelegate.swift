import AppKit
import Carbon.HIToolbox
import DuoCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: EffectEngine!
    private var menuBar: MenuBarController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DuoLog.note("launched pid \(ProcessInfo.processInfo.processIdentifier), bundle \(Bundle.main.bundleIdentifier ?? "none")")
        engine = EffectEngine(settings: EffectSettings.load())
        menuBar = MenuBarController(engine: engine)
        // Emergency exit: ⌃⌥⌘F pauses the effect and restores the desktop instantly.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.engine.togglePause()
        }
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}
