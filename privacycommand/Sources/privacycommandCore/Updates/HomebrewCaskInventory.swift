import Foundation

/// Discovers the set of apps worth previewing before an update, and resolves
/// each to an on-disk `.app` bundle the static analyzer can read.
///
/// Two sources:
///  - **Outdated Homebrew casks** (default): the apps a `brew upgrade` would
///    replace. We query `brew outdated --cask --json=v2` for the list and
///    `brew info --cask --json=v2 <tokens…>` to resolve each cask's installed
///    `.app` path.
///  - **Installed apps** (`--all-apps`): every top-level `.app` in the given
///    directories (defaults to `/Applications` and `~/Applications`).
///
/// JSON handling is split into pure `static` functions so it can be unit-tested
/// without Homebrew installed; only `outdatedCaskTargets()` shells out to `brew`.
public struct HomebrewCaskInventory: Sendable {

    public init() {}

    // MARK: - Models

    /// One app to preview, plus where it came from.
    public struct PreviewTarget: Sendable, Hashable {
        public let displayName: String
        public let bundleURL: URL
        public let source: Source

        public init(displayName: String, bundleURL: URL, source: Source) {
            self.displayName = displayName
            self.bundleURL = bundleURL
            self.source = source
        }

        public enum Source: Sendable, Hashable {
            /// Installed via Homebrew Cask and currently outdated.
            case brewCask(token: String, installed: String?, available: String?)
            /// A plain installed app discovered by scanning a directory.
            case installedApp
        }
    }

    /// One entry from `brew outdated --cask --json=v2`.
    public struct OutdatedCask: Sendable, Hashable {
        public let token: String
        public let installedVersion: String?
        public let availableVersion: String?

        public init(token: String, installedVersion: String?, availableVersion: String?) {
            self.token = token
            self.installedVersion = installedVersion
            self.availableVersion = availableVersion
        }
    }

    public enum InventoryError: Error, LocalizedError {
        case brewNotFound

        public var errorDescription: String? {
            switch self {
            case .brewNotFound:
                return "Homebrew (`brew`) not found under /opt/homebrew, /usr/local, or $HOMEBREW_PREFIX. Install Homebrew, or use `--all-apps` to preview installed apps directly."
            }
        }
    }

    // MARK: - Pure parsers (no brew required — unit-testable)

    /// Parse `brew outdated --cask --json=v2`. Pinned casks are skipped: a
    /// `brew upgrade` won't touch them, so they don't belong in the preview.
    public static func parseOutdated(_ json: Data) throws -> [OutdatedCask] {
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        let casks = root["casks"] as? [[String: Any]] ?? []
        return casks.compactMap { entry in
            guard let token = entry["name"] as? String else { return nil }
            if entry["pinned"] as? Bool == true { return nil }
            let installed = (entry["installed_versions"] as? [String])?.first
            let available = entry["current_version"] as? String
            return OutdatedCask(token: token,
                                installedVersion: installed,
                                availableVersion: available)
        }
    }

    /// Parse `brew info --cask --json=v2 <tokens…>` into `token → installed .app URL`.
    /// Uses the `app` artifact's `target` (the exact install path) when present,
    /// otherwise falls back to `<appDir>/<App name>`.
    public static func parseAppTargets(
        _ json: Data,
        appDir: URL = URL(fileURLWithPath: "/Applications")
    ) -> [String: URL] {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let casks = root["casks"] as? [[String: Any]] ?? []
        var out: [String: URL] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            // The relevant artifact is the one carrying an "app" key, e.g.
            // {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}.
            for artifact in artifacts {
                guard let apps = artifact["app"] as? [Any], let first = apps.first else { continue }
                if let target = artifact["target"] as? String, !target.isEmpty {
                    out[token] = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                } else if let name = first as? String {
                    out[token] = appDir.appendingPathComponent(name)
                }
                break
            }
        }
        return out
    }

    // MARK: - Discovery

    /// Outdated Homebrew casks resolved to their installed `.app` bundles.
    /// Targets whose `.app` can't be found on disk are dropped (e.g. casks that
    /// install something other than an app). Throws `.brewNotFound` if `brew`
    /// isn't installed.
    public func outdatedCaskTargets(
        appDir: URL = URL(fileURLWithPath: "/Applications")
    ) throws -> [PreviewTarget] {
        guard let brew = Self.brewExecutable() else { throw InventoryError.brewNotFound }

        let outdated = try Self.parseOutdated(Self.run(brew, ["outdated", "--cask", "--json=v2"]))
        guard !outdated.isEmpty else { return [] }

        // One batched `info` call resolves every install path at once.
        let infoJSON = (try? Self.run(brew, ["info", "--cask", "--json=v2"] + outdated.map(\.token))) ?? Data()
        let appTargets = Self.parseAppTargets(infoJSON, appDir: appDir)

        let fm = FileManager.default
        return outdated.compactMap { cask in
            guard let url = appTargets[cask.token], fm.fileExists(atPath: url.path) else { return nil }
            return PreviewTarget(
                displayName: url.deletingPathExtension().lastPathComponent,
                bundleURL: url,
                source: .brewCask(token: cask.token,
                                  installed: cask.installedVersion,
                                  available: cask.availableVersion))
        }
    }

    /// Every top-level `.app` in the given directories, de-duplicated by
    /// resolved path and sorted by name.
    public static func installedApps(in dirs: [URL]) -> [PreviewTarget] {
        let fm = FileManager.default
        var targets: [PreviewTarget] = []
        var seen = Set<String>()
        for dir in dirs {
            let entries = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in entries where url.pathExtension == "app" {
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                targets.append(PreviewTarget(
                    displayName: url.deletingPathExtension().lastPathComponent,
                    bundleURL: url,
                    source: .installedApp))
            }
        }
        return targets.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// `/Applications` plus the per-user `~/Applications`.
    public static func defaultAppDirectories() -> [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    // MARK: - brew plumbing

    /// Locate the `brew` binary, honouring `$HOMEBREW_PREFIX` and the two
    /// standard prefixes (Apple Silicon / Intel) — same convention as
    /// `HomebrewDetector`'s Caskroom lookup.
    static func brewExecutable() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            candidates.append(prefix + "/bin/brew")
        }
        candidates.append("/opt/homebrew/bin/brew")
        candidates.append("/usr/local/bin/brew")
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Run `brew` and return its stdout. stderr is discarded (brew prints
    /// progress/warnings there that would only muddy the JSON). Best-effort:
    /// a non-zero exit is NOT an error here — callers that need the data even
    /// when brew grumbles (the `outdated`/`info` JSON parsers) use this.
    static func run(_ executable: URL, _ args: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        try proc.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return data
    }

    public enum RunError: LocalizedError {
        case launchFailed(String)
        case nonzeroExit(code: Int32, stderr: String)
        case timedOut(seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let m):     return "Couldn't run brew: \(m)"
            case .nonzeroExit(_, let e):   return e.isEmpty ? "brew exited with an error." : e
            case .timedOut(let s):         return "brew timed out after \(Int(s))s."
            }
        }
    }

    /// Run `brew`, draining both pipes off-thread (so large output can't fill a
    /// pipe buffer and deadlock), enforcing a wall-clock `timeout`, and throwing
    /// on a non-zero exit — carrying brew's stderr. Use for commands whose
    /// failure must be surfaced (notably `brew fetch`).
    static func runChecked(_ executable: URL, _ args: [String], timeout: TimeInterval) throws -> Data {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch { throw RunError.launchFailed(error.localizedDescription) }

        // Drain both pipes to EOF on a background queue, concurrently with the
        // running process, so neither buffer can fill and wedge the child.
        let queue = DispatchQueue(label: "brew.pipe.drain", attributes: .concurrent)
        let reads = DispatchGroup()
        var outData = Data(), errData = Data()
        reads.enter(); queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        reads.enter(); queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); reads.leave() }

        // Wall-clock watchdog: terminate a wedged brew so the CLI can't hang.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            throw RunError.timedOut(seconds: timeout)
        }

        reads.wait()   // both EOF after the process exits; reads.wait() orders the writes before us
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RunError.nonzeroExit(code: proc.terminationStatus, stderr: msg)
        }
        return outData
    }
}
