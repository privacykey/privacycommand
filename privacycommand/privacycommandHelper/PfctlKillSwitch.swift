import Foundation

/// Manages a `pf` anchor that drops all outbound traffic to a chosen
/// set of IP addresses. Used to implement the network kill switch.
///
/// **Approach**: pf can't filter by PID on macOS, only by user / port /
/// address / interface. We sidestep that limitation by collecting the
/// destination IPs the inspected app has been seen contacting (via
/// `NetworkMonitor`) and blackholing those at pf. While the kill
/// switch is engaged, *no process* on the machine can reach those
/// addresses — but in practice the inspected app is by far the most
/// likely consumer of the IPs in its own destination history, so the
/// collateral is small for the diagnostic value.
///
/// **Anchor lifecycle**:
///   1. Write the anchor file at /etc/pf.anchors/com.permissionauditor.killswitch
///   2. Append a hook line in /etc/pf.conf so the system pf includes our
///      anchor when reloaded. (We restore /etc/pf.conf on remove.)
///   3. Reload the system ruleset: `pfctl -f /etc/pf.conf`
///   4. Enable pf if it isn't already: `pfctl -e`
///   5. Populate the address table: `pfctl -a anchor -t blocked -T add ...`
///
/// On remove we flush the anchor (`pfctl -a anchor -F all`) and roll
/// back the /etc/pf.conf change. We never disable pf system-wide on
/// remove — that would clobber any other firewall rules the user has
/// configured (Lulu, Little Snitch, corporate MDM, etc.).
final class PfctlKillSwitch {

    static let anchorName = "com.permissionauditor.killswitch"
    static let tableName = "killswitch_blocked"
    static let anchorFile = "/etc/pf.anchors/\(anchorName)"
    static let pfConfPath = "/etc/pf.conf"
    static let pfConfBackupPath = "/etc/pf.conf.permauditor.bak"
    static let pfctlPath = "/sbin/pfctl"

    /// Tracks whether we've added the anchor hook to /etc/pf.conf so
    /// that `remove()` knows whether to roll back.
    private var didModifyPfConf = false

    // MARK: - Public API

    func install(addresses: [String]) throws {
        // Sanitize input — drop empty strings and obvious garbage. We
        // don't validate IPs strictly; pfctl will reject malformed
        // entries when the table is populated.
        let cleaned = addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        guard !cleaned.isEmpty else {
            throw KillSwitchError.noAddresses
        }

        // 1. Write the anchor file. The rule blocks outbound traffic to
        // the named table — table contents are populated separately so
        // we can update them without rewriting the rule.
        let anchorRule = """
            table <\(Self.tableName)> persist
            block drop out quick to <\(Self.tableName)>
            """
        try anchorRule.write(toFile: Self.anchorFile,
                             atomically: true, encoding: .utf8)

        // 2. Add an anchor hook to /etc/pf.conf if it isn't already there.
        try ensurePfConfHook()

        // 3. Reload the system ruleset so our anchor's hook is picked up.
        let load = run(Self.pfctlPath, ["-f", Self.pfConfPath])
        guard load.status == 0 else {
            throw KillSwitchError.pfctlFailed("pfctl -f", load.stderr)
        }

        // 4. Enable pf if it isn't already. Returns non-zero ("pf already
        // enabled") if it's already on — that's fine, we ignore stderr.
        _ = run(Self.pfctlPath, ["-E"])

        // 5. Populate the table. `-T flush` first to handle the case where
        // install() is called twice (e.g. user updated the address set).
        _ = run(Self.pfctlPath, ["-a", Self.anchorName,
                                 "-t", Self.tableName, "-T", "flush"])
        let add = run(Self.pfctlPath, ["-a", Self.anchorName,
                                       "-t", Self.tableName, "-T", "add"]
                      + cleaned)
        guard add.status == 0 else {
            throw KillSwitchError.pfctlFailed("pfctl -T add", add.stderr)
        }
    }

    func remove() throws {
        // Flush the anchor — drops all rules and the table contents.
        _ = run(Self.pfctlPath, ["-a", Self.anchorName, "-F", "all"])
        // Roll back our /etc/pf.conf change if we made one.
        try rollbackPfConfHook()
        // We deliberately do *not* disable pf — the user might have
        // their own pf rules (or another firewall) and we shouldn't
        // clobber those.
    }

    // MARK: - /etc/pf.conf hook management

    private func ensurePfConfHook() throws {
        let line = "anchor \"\(Self.anchorName)\" load anchor \"\(Self.anchorName)\" from \"\(Self.anchorFile)\""
        let existing = (try? String(contentsOfFile: Self.pfConfPath, encoding: .utf8)) ?? ""
        if existing.contains(line) { return }   // already installed

        // Back up the original pf.conf so remove() can restore it.
        if !FileManager.default.fileExists(atPath: Self.pfConfBackupPath) {
            try? existing.write(toFile: Self.pfConfBackupPath,
                                atomically: true, encoding: .utf8)
        }
        let updated = existing.hasSuffix("\n") ? existing + line + "\n"
                                               : existing + "\n" + line + "\n"
        try updated.write(toFile: Self.pfConfPath,
                          atomically: true, encoding: .utf8)
        didModifyPfConf = true
    }

    private func rollbackPfConfHook() throws {
        guard FileManager.default.fileExists(atPath: Self.pfConfBackupPath) else {
            return
        }
        let original = try String(contentsOfFile: Self.pfConfBackupPath,
                                  encoding: .utf8)
        try original.write(toFile: Self.pfConfPath,
                           atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: Self.pfConfBackupPath)
        // Reload pf so the rollback takes effect immediately.
        _ = run(Self.pfctlPath, ["-f", Self.pfConfPath])
        didModifyPfConf = false
    }

    // MARK: - Subprocess helper

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ path: String, _ args: [String]) -> RunResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch {
            return .init(status: -1, stdout: "", stderr: "\(error)")
        }
        task.waitUntilExit()
        let outStr = String(data: outPipe.fileHandleForReading.availableData,
                            encoding: .utf8) ?? ""
        let errStr = String(data: errPipe.fileHandleForReading.availableData,
                            encoding: .utf8) ?? ""
        return .init(status: task.terminationStatus, stdout: outStr, stderr: errStr)
    }
}

enum KillSwitchError: LocalizedError {
    case noAddresses
    case pfctlFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .noAddresses:
            return "No addresses supplied for the kill switch."
        case .pfctlFailed(let cmd, let stderr):
            return "\(cmd) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
