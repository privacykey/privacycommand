import Foundation

/// Runs `brew upgrade` for the casks `UpgradeGate` cleared. Kept apart from
/// `HomebrewCaskInventory` (which only reads) so the one place that changes
/// the machine is easy to find and audit.
public enum HomebrewUpgrader {

    /// `brew upgrade --cask [--greedy] <tokens…>`. Pure, so it's testable and
    /// so the human output can show the exact command it is about to run (or
    /// the one to run by hand for the casks that were held).
    public static func arguments(casks: [String], greedy: Bool) -> [String] {
        var args = ["upgrade", "--cask"]
        if greedy { args.append("--greedy") }
        return args + casks
    }

    public static func commandLine(casks: [String], greedy: Bool) -> String {
        (["brew"] + arguments(casks: casks, greedy: greedy)).joined(separator: " ")
    }

    public enum UpgradeError: Error, LocalizedError {
        case brewNotFound
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .brewNotFound:        return "Homebrew (`brew`) not found."
            case .launchFailed(let m): return "Couldn't run brew upgrade: \(m)"
            }
        }
    }

    /// Run `brew upgrade` for `casks`, letting brew write to the given handles
    /// (the terminal normally; stderr when stdout has to stay machine-readable).
    /// stdin is inherited so a `.pkg` cask can still ask for an administrator
    /// password. Returns brew's exit status.
    ///
    /// Homebrew's auto-update is suppressed for this one call so brew installs
    /// the build that was just analyzed, not a newer one that may have landed
    /// in the tap meanwhile — the gate's verdict has to be about the build
    /// that ends up on disk.
    public static func run(casks: [String], greedy: Bool,
                           stdout: FileHandle = .standardOutput,
                           stderr: FileHandle = .standardError) throws -> Int32 {
        guard let brew = HomebrewCaskInventory.brewExecutable() else {
            throw UpgradeError.brewNotFound
        }
        let proc = Process()
        proc.executableURL = brew
        proc.arguments = arguments(casks: casks, greedy: greedy)
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        proc.environment = env
        proc.standardOutput = stdout
        proc.standardError = stderr
        do { try proc.run() } catch { throw UpgradeError.launchFailed(error.localizedDescription) }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
