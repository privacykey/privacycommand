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
        /// For casks that install via a `.pkg`: the package's path inside the
        /// downloaded artifact (the cask's `pkg` stanza), so `--fetch` can
        /// expand it to reach the incoming app.
        public let incomingPkgPath: String?

        public init(displayName: String, bundleURL: URL, source: Source, incomingPkgPath: String? = nil) {
            self.displayName = displayName
            self.bundleURL = bundleURL
            self.source = source
            self.incomingPkgPath = incomingPkgPath
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

    /// An outdated cask that `brew upgrade` would touch but preview can't
    /// analyze (it installs no app, or the app can't be found), with why.
    public struct SkippedCask: Sendable, Hashable {
        public let token: String
        public let installedVersion: String?
        public let availableVersion: String?
        public let reason: String

        public init(token: String, installedVersion: String?, availableVersion: String?, reason: String) {
            self.token = token
            self.installedVersion = installedVersion
            self.availableVersion = availableVersion
            self.reason = reason
        }
    }

    /// Everything a `brew upgrade` would touch, split into what preview can
    /// analyze and what it can't — so the preview never silently covers less
    /// than the upgrade does.
    public struct OutdatedScan: Sendable {
        /// Outdated casks resolved to an installed `.app`.
        public let targets: [PreviewTarget]
        /// Outdated casks with no analyzable app, each with a reason.
        public let skipped: [SkippedCask]
        /// Outdated formulae (command-line packages). `brew upgrade` updates
        /// these too, but preview only analyzes apps.
        public let outdatedFormulae: [String]
        /// Casks only `brew upgrade --greedy` would update (self-updating or
        /// `version :latest`). Empty when the scan was already greedy.
        public let greedyOnlyCasks: [String]

        public init(targets: [PreviewTarget], skipped: [SkippedCask],
                    outdatedFormulae: [String], greedyOnlyCasks: [String]) {
            self.targets = targets
            self.skipped = skipped
            self.outdatedFormulae = outdatedFormulae
            self.greedyOnlyCasks = greedyOnlyCasks
        }
    }

    /// How a cask installs, read from its `brew info` artifacts.
    public enum CaskInstall: Sendable, Hashable {
        /// An `app` artifact, at this install path.
        case app(URL)
        /// A `suite` artifact: a folder of apps at this install path.
        case suite(URL)
        /// A `.pkg` installer: the receipt-id patterns from its `uninstall
        /// pkgutil:` stanza, the package's path inside the download, and the
        /// cask's display names (used to pick the main app among several).
        case pkg(receipts: [String], pkgPath: String?, names: [String])
        /// Anything else (command-line `binary`, `font`, `prefpane`, …).
        case other(kinds: [String])
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

    /// Parse the outdated **formulae** from `brew outdated --json=v2` (pinned
    /// ones skipped, as for casks).
    public static func parseOutdatedFormulae(_ json: Data) -> [String] {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let formulae = root["formulae"] as? [[String: Any]] ?? []
        return formulae.compactMap { entry in
            if entry["pinned"] as? Bool == true { return nil }
            return entry["name"] as? String
        }
    }

    /// Parse `brew info --cask --json=v2 <tokens…>` into `token → installed .app URL`.
    /// Uses the `app` artifact's `target` (the exact install path) when present,
    /// otherwise falls back to `<appDir>/<App name>`.
    public static func parseAppTargets(
        _ json: Data,
        appDir: URL = URL(fileURLWithPath: "/Applications")
    ) -> [String: URL] {
        parseInstallKinds(json, appDir: appDir).compactMapValues {
            if case .app(let url) = $0 { return url }
            return nil
        }
    }

    /// Parse `brew info --cask --json=v2 <tokens…>` into `token → how it installs`.
    /// An `app` artifact wins over everything else, then `suite`, then `pkg`;
    /// a cask with none of those is `.other` with its artifact kinds.
    public static func parseInstallKinds(
        _ json: Data,
        appDir: URL = URL(fileURLWithPath: "/Applications")
    ) -> [String: CaskInstall] {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
        let casks = root["casks"] as? [[String: Any]] ?? []
        var out: [String: CaskInstall] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }

            // e.g. {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}.
            // `target` is the exact install path; otherwise `<appDir>/<name>`.
            func installPath(_ key: String) -> URL? {
                guard let artifact = artifacts.first(where: { $0[key] is [Any] }),
                      let first = (artifact[key] as? [Any])?.first else { return nil }
                if let target = artifact["target"] as? String, !target.isEmpty {
                    return URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                }
                return (first as? String).map { appDir.appendingPathComponent($0) }
            }

            if let app = installPath("app") {
                out[token] = .app(app)
            } else if let suite = installPath("suite") {
                out[token] = .suite(suite)
            } else if let pkg = artifacts.first(where: { $0["pkg"] is [Any] }) {
                // {"uninstall": [{"pkgutil": "org.x.*" | ["a", "b"], …}]}
                let receipts = artifacts
                    .compactMap { $0["uninstall"] as? [[String: Any]] }
                    .flatMap { $0 }
                    .flatMap { directive -> [String] in
                        if let one = directive["pkgutil"] as? String { return [one] }
                        return directive["pkgutil"] as? [String] ?? []
                    }
                out[token] = .pkg(receipts: receipts,
                                  pkgPath: (pkg["pkg"] as? [Any])?.first as? String,
                                  names: cask["name"] as? [String] ?? [])
            } else {
                let kinds = artifacts.flatMap(\.keys).filter { !ignoredArtifactKeys(contains: $0) }
                out[token] = .other(kinds: Array(Set(kinds)).sorted())
            }
        }
        return out
    }

    /// Artifact keys that describe housekeeping, not what the cask installs.
    private static func ignoredArtifactKeys(contains key: String) -> Bool {
        ["target", "uninstall", "zap", "preflight", "postflight", "manpage"].contains(key)
            || key.hasPrefix("uninstall_")
            || key.hasPrefix("generate_completions")
            || key.hasSuffix("_completion")
    }

    /// Plain-language reason a cask of these artifact kinds isn't previewed.
    public static func skipReason(forKinds kinds: [String]) -> String {
        let names: [String: String] = [
            "binary": "a command-line tool",
            "font": "fonts",
            "prefpane": "a System Settings pane",
            "qlplugin": "a Quick Look plug-in",
            "screen_saver": "a screen saver",
            "service": "a Services menu item",
            "artifact": "files",
        ]
        if kinds.contains("installer") {
            return "runs its own installer, so the app it installs can't be located"
        }
        let described = kinds.map { names[$0] ?? $0.replacingOccurrences(of: "_", with: " ") }
        guard !described.isEmpty else { return "installs no app" }
        return "installs \(described.joined(separator: " and ")), not an app"
    }

    /// Top-level `.app` bundles in `pkgutil --files <id>` output — e.g.
    /// `GPG Keychain.app` from `GPG Keychain.app/Contents/…`. Paths are
    /// relative to the receipt's install location; nested apps are ignored.
    public static func topLevelAppPaths(pkgutilFiles: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in pkgutilFiles.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "/", omittingEmptySubsequences: true)
            guard let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            let path = parts[...idx].joined(separator: "/")
            if seen.insert(path).inserted { out.append(path) }
        }
        return out
    }

    /// The main app among a `.pkg` cask's installed apps: one named like the
    /// cask, else one at the top of an Applications folder, else the first —
    /// never an uninstaller when there's an alternative.
    public static func choosePrimaryApp(_ candidates: [URL], names: [String], token: String) -> URL? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = Set((names + [token]).map(norm).filter { !$0.isEmpty })
        let usable = candidates.filter { !norm($0.lastPathComponent).contains("uninstall") }
        let pool = usable.isEmpty ? candidates : usable

        func score(_ url: URL) -> Int {
            let name = norm(url.deletingPathExtension().lastPathComponent)
            if wanted.contains(name) { return 3 }
            if wanted.contains(where: { name.contains($0) || $0.contains(name) }) { return 2 }
            return url.deletingLastPathComponent().lastPathComponent == "Applications" ? 1 : 0
        }
        // Stable: ties keep candidate order.
        return pool.enumerated().max { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa < sb : a.offset > b.offset
        }?.element
    }

    // MARK: - Discovery

    /// Everything `brew upgrade` (or `brew upgrade --greedy`) would touch:
    /// outdated casks resolved to installed `.app` bundles, the casks that
    /// can't be (with a reason), and the outdated formulae. When not `greedy`,
    /// also lists the casks only a greedy upgrade would add. Throws
    /// `.brewNotFound` if `brew` isn't installed.
    ///
    /// `progress` receives a plain-language label as each step starts — the
    /// first can take a while, because `brew outdated` refreshes Homebrew's
    /// package index when it's stale.
    public func outdatedScan(
        greedy: Bool = false,
        appDir: URL = URL(fileURLWithPath: "/Applications"),
        progress: ((String) -> Void)? = nil
    ) throws -> OutdatedScan {
        guard let brew = Self.brewExecutable() else { throw InventoryError.brewNotFound }

        // One call covers casks and formulae, matching what `brew upgrade` sees.
        progress?("Asking Homebrew what's outdated (it may refresh its package index first)")
        let outdatedJSON = try Self.run(brew, ["outdated", "--json=v2"] + (greedy ? ["--greedy"] : []))
        let outdated = try Self.parseOutdated(outdatedJSON)
        let formulae = Self.parseOutdatedFormulae(outdatedJSON)

        var greedyOnly: [String] = []
        if !greedy { progress?("Checking for casks that only update with --greedy") }
        if !greedy, let greedyJSON = try? Self.run(brew, ["outdated", "--cask", "--greedy", "--json=v2"]),
           let all = try? Self.parseOutdated(greedyJSON) {
            let regular = Set(outdated.map(\.token))
            greedyOnly = all.map(\.token).filter { !regular.contains($0) }
        }

        guard !outdated.isEmpty else {
            return OutdatedScan(targets: [], skipped: [], outdatedFormulae: formulae, greedyOnlyCasks: greedyOnly)
        }

        // One batched `info` call resolves every install path at once.
        progress?("Finding the installed apps for \(outdated.count) outdated cask\(outdated.count == 1 ? "" : "s")")
        let infoJSON = (try? Self.run(brew, ["info", "--cask", "--json=v2"] + outdated.map(\.token))) ?? Data()
        let installs = Self.parseInstallKinds(infoJSON, appDir: appDir)

        var targets: [PreviewTarget] = []
        var skipped: [SkippedCask] = []
        for cask in outdated {
            let source = PreviewTarget.Source.brewCask(
                token: cask.token, installed: cask.installedVersion, available: cask.availableVersion)
            switch Self.resolveInstalledApp(installs[cask.token], token: cask.token) {
            case .success(let found):
                targets.append(PreviewTarget(
                    displayName: found.app.deletingPathExtension().lastPathComponent,
                    bundleURL: found.app, source: source, incomingPkgPath: found.pkgPath))
            case .failure(let why):
                skipped.append(SkippedCask(token: cask.token, installedVersion: cask.installedVersion,
                                           availableVersion: cask.availableVersion, reason: why.reason))
            }
        }
        return OutdatedScan(targets: targets, skipped: skipped,
                            outdatedFormulae: formulae, greedyOnlyCasks: greedyOnly)
    }

    private struct ResolvedApp { let app: URL; let pkgPath: String? }
    private struct Unresolved: Error { let reason: String }

    /// Find the installed `.app` for one cask, or say why there isn't one.
    private static func resolveInstalledApp(_ install: CaskInstall?, token: String)
        -> Result<ResolvedApp, Unresolved> {
        let fm = FileManager.default
        switch install {
        case .none:
            return .failure(Unresolved(reason: "brew info returned nothing for it"))
        case .app(let url):
            guard fm.fileExists(atPath: url.path) else {
                return .failure(Unresolved(reason: "its app isn't at \(url.path) (moved or deleted?)"))
            }
            return .success(ResolvedApp(app: url, pkgPath: nil))
        case .suite(let dir):
            guard let app = DMGMounter.firstAppBundle(in: dir) else {
                return .failure(Unresolved(reason: "no app found in its suite folder \(dir.path)"))
            }
            return .success(ResolvedApp(app: app, pkgPath: nil))
        case .pkg(let receipts, let pkgPath, let names):
            let candidates = installedApps(forReceipts: receipts)
            guard let app = choosePrimaryApp(candidates, names: names, token: token) else {
                return .failure(Unresolved(reason: "installs with a .pkg, and none of its installed apps were found"))
            }
            return .success(ResolvedApp(app: app, pkgPath: pkgPath))
        case .other(let kinds):
            return .failure(Unresolved(reason: skipReason(forKinds: kinds)))
        }
    }

    /// Installed `.app` bundles recorded by the package receipts matching
    /// `patterns` (the cask's `uninstall pkgutil:` ids, which brew treats as
    /// regular expressions — as does `pkgutil --pkgs=`). A receipt's path is
    /// tried first; installers that stage in a temp dir and move the app later
    /// are caught by looking for the same bundle name in the Applications folders.
    static func installedApps(forReceipts patterns: [String]) -> [URL] {
        let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        let fm = FileManager.default
        func text(_ args: [String]) -> String {
            String(data: (try? run(pkgutil, args)) ?? Data(), encoding: .utf8) ?? ""
        }

        var ids: [String] = []
        for pattern in patterns {
            for id in text(["--pkgs=\(pattern)"]).split(whereSeparator: \.isNewline).map(String.init)
            where !ids.contains(id) {
                ids.append(id)
            }
        }

        var apps: [URL] = []
        for id in ids {
            var base = URL(fileURLWithPath: "/")
            if let plist = try? PropertyListSerialization.propertyList(
                   from: Data(text(["--pkg-info-plist", id]).utf8), format: nil) as? [String: Any] {
                base = URL(fileURLWithPath: plist["volume"] as? String ?? "/")
                    .appendingPathComponent(plist["install-location"] as? String ?? "")
            }
            for rel in topLevelAppPaths(pkgutilFiles: text(["--files", id])) {
                let recorded = base.appendingPathComponent(rel)
                let name = recorded.lastPathComponent
                let found = ([recorded] + defaultAppDirectories().map { $0.appendingPathComponent(name) })
                    .first { fm.fileExists(atPath: $0.path) }
                if let found, !apps.contains(found) { apps.append(found) }
            }
        }
        return apps
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
