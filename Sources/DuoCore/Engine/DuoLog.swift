import Foundation

/// Plain stderr diagnostics, enabled by running the binary with `DUO_DEBUG=1`.
/// Handy when the unified log is inconvenient:
///
///     DUO_DEBUG=1 "build/MacBook Duo.app/Contents/MacOS/MacbookDuo"
public enum DuoLog {
    public static let enabled = ProcessInfo.processInfo.environment["DUO_DEBUG"] != nil

    public static func note(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[duo] " + message() + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
