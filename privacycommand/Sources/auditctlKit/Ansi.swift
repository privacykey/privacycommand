import Foundation

/// Minimal ANSI styling for the CLI. Colour is emitted only when the output is
/// a real terminal, `--no-color` wasn't passed, and the `NO_COLOR` convention
/// (https://no-color.org) isn't set — so piping to a file or `grep` stays plain.
public struct Ansi: Sendable {
    public let enabled: Bool

    /// Auto-detects: honours `--no-color`, `NO_COLOR`, and whether stdout is a TTY.
    public init(noColor: Bool) {
        let isTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0
        let noColorEnv = ProcessInfo.processInfo.environment["NO_COLOR"]?.isEmpty == false
        self.init(enabled: isTTY && !noColor && !noColorEnv)
    }

    /// Explicit override — used by the TUI (which owns the terminal directly)
    /// and by tests that need deterministic, colour-free output.
    public init(enabled: Bool) {
        self.enabled = enabled
    }

    /// SGR codes we use. Raw value is the numeric parameter for `ESC[…m`.
    public enum Code: String, Sendable {
        case bold = "1"
        case dim = "2"
        case reverse = "7"
        case red = "31"
        case green = "32"
        case yellow = "33"
        case cyan = "36"
        case brightRed = "91"
    }

    /// Wrap `s` in the given styles, or return it untouched when colour is off.
    public func paint(_ s: String, _ codes: Code...) -> String {
        paint(s, codes)
    }

    /// Array form, for callers that build the style list dynamically.
    public func paint(_ s: String, _ codes: [Code]) -> String {
        guard enabled, !codes.isEmpty else { return s }
        let sgr = codes.map(\.rawValue).joined(separator: ";")
        return "\u{001B}[\(sgr)m\(s)\u{001B}[0m"
    }
}
