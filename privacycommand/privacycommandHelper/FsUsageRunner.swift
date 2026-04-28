import Foundation

/// Spawns `fs_usage(1)` filtered to a PID, parses the output one line at a
/// time, and emits `FileEventWire` values via the supplied callback.
///
/// `fs_usage` is the supported user-space mechanism for observing
/// file-system syscalls on macOS. Caveats inherited from the tool:
///   - SIP-restricted on Apple-signed binaries.
///   - Lossy under heavy I/O load — events can be dropped silently.
///   - Output is text. The parser here is best-effort and tolerant of new
///     formats Apple may introduce; unparseable lines are dropped.
final class FsUsageRunner {
    typealias EventHandler = (FileEventWire) -> Void
    typealias LogHandler = (String) -> Void

    private let pid: Int32
    private let onEvent: EventHandler
    private let onLog: LogHandler

    private var process: Process?
    private var lineBuffer = HelperLineBuffer()

    init(pid: Int32, onEvent: @escaping EventHandler, onLog: @escaping LogHandler) {
        self.pid = pid
        self.onEvent = onEvent
        self.onLog = onLog
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
        process.arguments = ["-w", "-f", "filesys", String(pid)]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            if data.isEmpty { return }
            for line in self.lineBuffer.append(data) {
                self.parseAndEmit(line: line)
            }
        }

        try process.run()
        self.process = process
        onLog("fs_usage started for pid \(pid)")
    }

    func stop() {
        process?.terminate()
        process = nil
        onLog("fs_usage stopped")
    }

    // MARK: - Parsing

    /// `fs_usage -w -f filesys` lines look like:
    ///   23:14:27.123456  open  F=8 (R___)  /Users/alice/Documents/foo.txt   0.000123  Slack.123
    /// We extract op, path, and a guess at process name. PID is fixed (we
    /// filtered fs_usage to it).
    private func parseAndEmit(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.first.map({ $0.isNumber }) == true else { return }

        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return }

        let op = mapOp(tokens[1])
        let pathToken = tokens.last(where: { $0.hasPrefix("/") })
        guard let path = pathToken else { return }
        let processName = tokens.last.map { String($0.split(separator: ".").first ?? Substring($0)) } ?? "?"

        let event = FileEventWire(
            id: UUID(),
            timestamp: Date(),
            pid: pid,
            processName: processName,
            op: op,
            path: path,
            secondaryPath: nil,
            category: "unknown",
            risk: "expected",
            ruleID: nil
        )
        onEvent(event)
    }

    private func mapOp(_ raw: String) -> String {
        switch raw {
        case "open", "open_nocancel", "open_dprotected_np", "openat", "openat_nocancel": return "open"
        case "creat":                       return "create"
        case "mkdir":                       return "mkdir"
        case "rmdir":                       return "rmdir"
        case "rename", "renameat", "renameatx_np": return "rename"
        case "unlink", "unlinkat":          return "unlink"
        case "symlink", "symlinkat":        return "symlink"
        case "link", "linkat":              return "link"
        case "chmod", "fchmod", "fchmodat": return "chmod"
        case "chown", "fchown", "fchownat": return "chown"
        case "truncate", "ftruncate":       return "truncate"
        case "write", "writev", "pwrite":   return "write"
        case "read", "readv", "pread":      return "read"
        default:                            return "other"
        }
    }
}

/// Wire-format struct that encodes to JSON identical to `FileEvent` from
/// `privacycommandCore`. Kept separate so the helper target doesn't have
/// to link the full Core library — the encoded JSON is the only contract.
struct FileEventWire: Codable {
    let id: UUID
    let timestamp: Date
    let pid: Int32
    let processName: String
    let op: String
    let path: String
    let secondaryPath: String?
    let category: String
    let risk: String
    let ruleID: String?
}

/// Newline-delimited line accumulator. Local to the helper so the helper
/// target needs no dependency on the app's `ProcessRunner`.
final class HelperLineBuffer {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending.prefix(upTo: nl)
            pending.removeSubrange(...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                lines.append(s)
            }
        }
        return lines
    }
}
