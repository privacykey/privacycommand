import Foundation

/// Wrapper around `sfltool dumpbtm` (macOS 13+) that finds the BTM
/// (Background Task Management) records associated with a particular
/// inspected app bundle.
///
/// **What BTM is.** Since macOS 13, every login item, launchd agent /
/// daemon, and helper that's registered to run automatically gets logged
/// into a system-wide database that's user-visible from System Settings →
/// General → Login Items & Extensions. `sfltool dumpbtm` prints the
/// entire database in a structured form.
///
/// **The privilege wrinkle.** On early macOS 13 builds `sfltool dumpbtm`
/// ran unprivileged. Apple tightened it: on macOS 14+ the tool triggers
/// an Authorization Services prompt for an admin password. We have two
/// paths around that:
///   1. **Helper path.** When the privileged helper is installed, the
///      app calls `runSfltoolDumpBTM` over XPC. The helper is already
///      root and runs `sfltool` without prompting — clean UX, no
///      surprise password dialog. This is the auto path.
///   2. **Direct path (opt-in).** When the helper isn't installed and
///      the user explicitly clicks "Run BTM audit" in the Static tab,
///      the app shells out to `sfltool` itself. macOS will prompt for
///      admin; the user has consented by clicking the button so the
///      prompt is no longer a surprise.
///
/// We **never** auto-shell to `sfltool` from the app. The earlier code
/// did, which is why every Static-tab open used to fire an admin prompt.
public enum BTMAuditor {

    /// Build a result from raw `sfltool dumpbtm` output. Tested in
    /// isolation; reused by every entry point that successfully
    /// obtains the dump (helper or direct).
    public static func auditOutput(_ output: String, bundle: AppBundle) -> BTMAuditResult {
        let allRecords = parse(output: output)
        let matchedRecords = allRecords.filter { record in
            recordMatches(record, bundle: bundle)
        }
        return BTMAuditResult(
            state: .ok,
            allRecordCount: allRecords.count,
            matched: matchedRecords)
    }

    /// Direct path: shell out to `sfltool dumpbtm` from the running
    /// (unprivileged) app. **Will trigger an admin prompt on macOS
    /// 14+.** Only call this from a path the user explicitly opted
    /// into (e.g. a "Run BTM audit (requires admin)" button).
    ///
    /// Kept synchronous because the call is short and the GUI side
    /// already wraps it in `Task` for off-main execution.
    public static func auditDirect(bundle: AppBundle,
                                   timeout: TimeInterval = 30) -> BTMAuditResult {
        guard let output = runSFLTool(timeout: timeout) else {
            return BTMAuditResult(state: .toolUnavailable)
        }
        return auditOutput(output, bundle: bundle)
    }

    private static func recordMatches(_ record: BTMRecord, bundle: AppBundle) -> Bool {
        if let bid = bundle.bundleID, !bid.isEmpty,
           let recBid = record.bundleID, recBid == bid || recBid.hasPrefix(bid + ".") {
            return true
        }
        let bundlePath = bundle.url.path
        if let url = record.url, url.path.hasPrefix(bundlePath) {
            return true
        }
        return false
    }

    // MARK: - Subprocess

    private static func runSFLTool(timeout: TimeInterval) -> String? {
        // sfltool lives at /usr/bin/sfltool on macOS 13+. Older systems
        // don't ship it.
        let path = "/usr/bin/sfltool"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["dumpbtm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        // Block with a timeout — sfltool dumpbtm normally finishes in <1s.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline { task.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    // MARK: - Parsing

    /// `sfltool dumpbtm` emits records separated by blank lines. Each
    /// record is a list of `Key: Value` lines (sometimes indented).
    /// Recognised keys we care about: `Type`, `Disposition`, `URL`,
    /// `Identifier`, `Generation`, `Embedded item identifier`.
    static func parse(output: String) -> [BTMRecord] {
        var records: [BTMRecord] = []
        let blocks = output.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            var fields: [String: String] = [:]
            for line in lines where line.contains(":") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let k = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let v = String(parts[1]).trimmingCharacters(in: .whitespaces)
                fields[k] = v
            }
            guard !fields.isEmpty else { continue }
            // Heuristic: a real record has at least Type or Identifier.
            let typeRaw = fields["Type"] ?? ""
            let idRaw = fields["Identifier"] ?? ""
            guard !typeRaw.isEmpty || !idRaw.isEmpty else { continue }
            let dispo = fields["Disposition"] ?? ""

            let url: URL? = (fields["URL"] ?? fields["File URL"]).flatMap {
                URL(string: $0)
            }
            // Disposition strings often look like "[enabled, allowed, visible, notified]".
            let isEnabled = dispo.contains("enabled")
            let isAllowed = dispo.contains("allowed")

            records.append(BTMRecord(
                kind: BTMRecord.Kind(raw: typeRaw),
                bundleID: fields["Bundle Identifier"] ?? fields["Embedded item identifier"]
                    ?? fields["Identifier"],
                identifier: idRaw.isEmpty ? nil : idRaw,
                url: url,
                isEnabled: isEnabled,
                isAllowed: isAllowed,
                rawDisposition: dispo))
        }
        return records
    }
}

// MARK: - Public types

public struct BTMAuditResult: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// The BTM audit hasn't been requested yet. Default state for
        /// every newly-analysed bundle when the helper isn't
        /// installed; the Static tab renders an opt-in button in
        /// this state instead of auto-running.
        case notRequested
        /// Audit completed; `matched` and `allRecordCount` populated.
        case ok
        /// `sfltool` is missing (pre-macOS-13 or removed).
        case toolUnavailable
        /// Helper was supposed to run the dump but the call failed
        /// (helper not running, XPC error, etc.). Carries a short
        /// message the UI shows inline. Falls back to the opt-in
        /// button so the user can still get the data via the direct
        /// path.
        case failed(String)
    }
    public let state: State
    public let allRecordCount: Int
    public let matched: [BTMRecord]

    public init(state: State, allRecordCount: Int = 0, matched: [BTMRecord] = []) {
        self.state = state
        self.allRecordCount = allRecordCount
        self.matched = matched
    }
}

public struct BTMRecord: Sendable, Hashable, Identifiable {
    public var id: String { (identifier ?? "") + ":" + (url?.path ?? "") }
    public let kind: Kind
    public let bundleID: String?
    public let identifier: String?
    public let url: URL?
    public let isEnabled: Bool
    public let isAllowed: Bool
    public let rawDisposition: String

    public enum Kind: String, Sendable, Hashable, Codable {
        case loginItem        = "Login item"
        case loginItemFolder  = "Login items folder"
        case agent            = "Launch agent"
        case daemon           = "Launch daemon"
        case helper           = "Helper"
        case extensionItem    = "App extension"
        case other

        init(raw: String) {
            let l = raw.lowercased()
            if l.contains("daemon")           { self = .daemon }
            else if l.contains("agent")       { self = .agent }
            else if l.contains("login item")  { self = .loginItem }
            else if l.contains("login items") { self = .loginItemFolder }
            else if l.contains("helper")      { self = .helper }
            else if l.contains("extension")   { self = .extensionItem }
            else { self = .other }
        }
    }
}
