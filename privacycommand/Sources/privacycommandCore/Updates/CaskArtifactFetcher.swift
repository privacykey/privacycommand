import Foundation

/// Downloads an outdated Homebrew cask's **incoming** artifact, hands the `.app`
/// inside it to a caller, and guarantees teardown (DMG detach / temp-dir
/// removal) on every exit path.
///
/// Supported formats: `.dmg` (mounted read-only via `DMGMounter`), `.zip`
/// (extracted with `ditto -x -k`) and flat `.pkg` installers (expanded with
/// `pkgutil --expand-full` — never installed). A `.pkg` inside a `.dmg`/`.zip`
/// is expanded too. Anything else is rejected **before** downloading, so we
/// never pull hundreds of MB we can't open.
///
/// The format is read from `brew --cache --cask <token>` — which resolves the
/// would-be cache path *without* downloading — so the cheap skip happens first;
/// only then do we `brew fetch`.
public enum CaskArtifactFetcher {

    public enum Format: Equatable, Sendable {
        case dmg
        case zip
        case pkg
        case unknown(String)   // the raw (lowercased) extension

        public var label: String {
            switch self {
            case .dmg: return "dmg"
            case .zip: return "zip"
            case .pkg: return "pkg"
            case .unknown(let e): return e.isEmpty ? "unknown" : e
            }
        }

        public var isSupported: Bool {
            switch self {
            case .dmg, .zip, .pkg: return true
            case .unknown:         return false
            }
        }
    }

    public enum FetchError: LocalizedError, Equatable {
        case brewNotFound
        case cacheLookupFailed
        case unsupportedFormat(Format)
        case fetchFailed(String)
        case extractionFailed(String)
        case dittoUnavailable
        case noAppInside
        case attachFailed(String)
        case pkgExpandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .brewNotFound:            return "Homebrew (`brew`) not found."
            case .cacheLookupFailed:       return "Couldn't resolve the cask's download path from `brew --cache`."
            case .unsupportedFormat(let f):return "Incoming build is a .\(f.label) artifact — only .dmg, .zip and .pkg casks can be previewed."
            case .fetchFailed(let m):      return "brew fetch failed: \(m)"
            case .extractionFailed(let m): return "Couldn't extract the archive: \(m)"
            case .dittoUnavailable:        return "/usr/bin/ditto isn't available to extract the .zip."
            case .noAppInside:             return "No .app bundle was found inside the download."
            case .attachFailed(let m):     return "Couldn't mount the disk image: \(m)"
            case .pkgExpandFailed(let m):  return "Couldn't expand the installer package: \(m)"
            }
        }

        /// A skip is an expected "can't preview this one" outcome (skip + carry
        /// on); a failure is an unexpected error worth flagging more loudly.
        public var isSkip: Bool {
            switch self {
            case .unsupportedFormat, .noAppInside, .dittoUnavailable: return true
            default: return false
            }
        }
    }

    // MARK: - Pure helpers (unit-testable, no brew)

    /// Map a cache-file extension (no leading dot, any case) to a `Format`.
    public static func detectFormat(cacheExtension ext: String) -> Format {
        switch ext.lowercased() {
        case "dmg":          return .dmg
        case "zip":          return .zip
        case "pkg", "mpkg":  return .pkg
        default:             return .unknown(ext.lowercased())
        }
    }

    /// Parse the single path `brew --cache --cask <token>` prints. Returns nil
    /// for empty/whitespace-only output.
    public static func parseCachePath(_ stdout: Data) -> URL? {
        guard let raw = String(data: stdout, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // brew prints exactly one path; defend against extra lines anyway.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return URL(fileURLWithPath: firstLine)
    }

    // MARK: - Scoped download + acquire + guaranteed cleanup

    /// What `withDownloadedApp` is doing, for progress display.
    public enum Phase: Sendable {
        /// `brew fetch` is downloading to `cacheFile` (brew's cache path).
        /// Until it finishes, the bytes so far are in `partialFile`.
        case downloading(cacheFile: URL)
        /// Mounting, extracting or expanding the download to reach the app.
        case unpacking
    }

    /// Where `brew fetch` keeps an unfinished download of `cacheFile`.
    public static func partialFile(for cacheFile: URL) -> URL {
        URL(fileURLWithPath: cacheFile.path + ".incomplete")
    }

    /// Resolve the cask's incoming artifact, expose the `.app` inside it to
    /// `body`, and tear everything down afterwards — on success or throw.
    /// Unsupported formats throw `.unsupportedFormat` *before* any download.
    ///
    /// - Parameters:
    ///   - preferredAppName: the installed bundle's file name (`Foo.app`), so
    ///     a download holding several apps yields the matching one.
    ///   - pkgPath: the cask's `pkg` stanza — the installer's path inside a
    ///     `.dmg`/`.zip` — for casks that install with a `.pkg`.
    ///   - progress: told when the download and the unpacking start; `body`
    ///     runs once the app is ready.
    public static func withDownloadedApp<T>(
        token: String,
        preferredAppName: String? = nil,
        pkgPath: String? = nil,
        progress: ((Phase) -> Void)? = nil,
        _ body: (URL) throws -> T
    ) async throws -> T {
        guard let brew = HomebrewCaskInventory.brewExecutable() else { throw FetchError.brewNotFound }

        // 1. Resolve the cache path (no download) and decide if we can open it.
        let cacheData: Data
        do {
            cacheData = try HomebrewCaskInventory.runChecked(brew, ["--cache", "--cask", token], timeout: 30)
        } catch HomebrewCaskInventory.RunError.launchFailed {
            throw FetchError.brewNotFound      // brew vanished/became non-executable mid-run
        } catch {
            throw FetchError.cacheLookupFailed
        }
        guard let cacheURL = parseCachePath(cacheData) else { throw FetchError.cacheLookupFailed }
        let format = detectFormat(cacheExtension: cacheURL.pathExtension)
        guard format.isSupported else { throw FetchError.unsupportedFormat(format) }

        // 2. Download. Idempotent + validates the checksum; runChecked throws on
        //    any non-zero exit carrying brew's stderr, so a failed/corrupt
        //    download is reported as .fetchFailed and never analyzed. A
        //    generous wall-clock cap keeps a wedged download from hanging forever.
        progress?(.downloading(cacheFile: cacheURL))
        do {
            _ = try HomebrewCaskInventory.runChecked(brew, ["fetch", "--cask", token], timeout: 600)
        } catch {
            throw FetchError.fetchFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            throw FetchError.fetchFailed("brew fetch reported success but left nothing in the cache.")
        }

        // 3. Acquire the .app + a teardown thunk, then run body with guaranteed
        //    cleanup. `defer` can't `await` (DMGMounter.detach is async), so the
        //    do/catch invokes cleanup explicitly on both paths.
        progress?(.unpacking)
        switch format {
        case .dmg:
            let mount = try await mount(cacheURL)
            return try await withCleanup({ try? await DMGMounter.detach(mount) }) {
                try withApp(in: mount.allMountPoints, preferredAppName: preferredAppName,
                            pkgPath: pkgPath, body)
            }
        case .zip:
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else {
                throw FetchError.dittoUnavailable
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("privacycommand-fetch-\(UUID().uuidString)", isDirectory: true)
            try extractZip(cacheURL, into: dir)
            return try await withCleanup({ try? FileManager.default.removeItem(at: dir) }) {
                try withApp(in: [dir], preferredAppName: preferredAppName, pkgPath: pkgPath, body)
            }
        case .pkg:
            return try withExpandedPkg(cacheURL, preferredAppName: preferredAppName, body)
        case .unknown:
            throw FetchError.unsupportedFormat(format)   // unreachable — guarded above
        }
    }

    // MARK: - Choosing the app

    /// Every `.app` under `root`, shallowest first, without descending into
    /// bundles or following symlinks (a DMG's `Applications` alias would
    /// otherwise lead into the host's own apps).
    static func appBundles(in root: URL, maxDepth: Int = 6) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var found: [URL] = []
        var level = [root]
        for _ in 0..<maxDepth where !level.isEmpty {
            var next: [URL] = []
            for dir in level {
                let entries = ((try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: Set(keys))
                    guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
                    if entry.pathExtension == "app" { found.append(entry) } else { next.append(entry) }
                }
            }
            level = next
        }
        return found
    }

    /// The app to analyze among those found: the one named like the installed
    /// app, else the first that isn't an uninstaller, else the first.
    public static func pickApp(_ apps: [URL], preferredName: String?) -> URL? {
        if let preferredName,
           let match = apps.first(where: { $0.lastPathComponent.caseInsensitiveCompare(preferredName) == .orderedSame }) {
            return match
        }
        return apps.first { !$0.lastPathComponent.lowercased().contains("uninstall") } ?? apps.first
    }

    /// Find the app inside an opened `.dmg`/`.zip` and run `body` on it. A
    /// `.pkg` cask's installer (its `pkgPath`, or failing an app, any `.pkg` at
    /// the top of the download) is expanded and searched instead.
    private static func withApp<T>(in roots: [URL], preferredAppName: String?, pkgPath: String?,
                                   _ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        if let pkgPath,
           let pkg = roots.map({ $0.appendingPathComponent(pkgPath) }).first(where: { fm.fileExists(atPath: $0.path) }) {
            return try withExpandedPkg(pkg, preferredAppName: preferredAppName, body)
        }
        if let app = pickApp(roots.flatMap { appBundles(in: $0) }, preferredName: preferredAppName) {
            return try body(app)
        }
        let pkgs = roots.flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles])) ?? [])
                .filter { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
        }
        guard let pkg = pkgs.first else { throw FetchError.noAppInside }
        return try withExpandedPkg(pkg, preferredAppName: preferredAppName, body)
    }

    /// Expand a flat installer package into a temp dir (nothing is installed
    /// and no install scripts run), run `body` on the app in its payload, then
    /// remove the temp dir.
    private static func withExpandedPkg<T>(_ pkg: URL, preferredAppName: String?,
                                           _ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("auditctl-pkg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw FetchError.pkgExpandFailed(error.localizedDescription)
        }
        // pkgutil requires the destination not to exist yet.
        let expanded = dir.appendingPathComponent("expanded", isDirectory: true)
        try runTool("/usr/sbin/pkgutil", ["--expand-full", pkg.path, expanded.path],
                    failure: FetchError.pkgExpandFailed)
        guard let app = pickApp(appBundles(in: expanded), preferredName: preferredAppName) else {
            throw FetchError.noAppInside
        }
        return try body(app)
    }

    // MARK: - internals

    /// Run `work`, then `cleanup` — on success *and* on throw.
    private static func withCleanup<T>(_ cleanup: @escaping () async -> Void,
                                       _ work: () throws -> T) async throws -> T {
        do {
            let result = try work()
            await cleanup()
            return result
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func mount(_ url: URL) async throws -> DMGMounter.Mount {
        do {
            return try await DMGMounter.mount(dmg: url)
        } catch {
            // SLA-bearing images and other attach failures land here.
            throw FetchError.attachFailed(error.localizedDescription)
        }
    }

    private static func extractZip(_ zip: URL, into dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw FetchError.extractionFailed(error.localizedDescription)
        }
        do {
            // -x -k: extract a PKZip archive. ditto (unlike unzip) drops the
            // __MACOSX/AppleDouble noise and preserves bundle symlinks + perms.
            try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], failure: FetchError.extractionFailed)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Run a system tool to completion, throwing `failure(<stderr>)` if it
    /// can't launch or exits non-zero. stdout is discarded.
    private static func runTool(_ path: String, _ args: [String],
                                failure: (String) -> FetchError) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let err = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            throw failure(error.localizedDescription)
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw failure(msg.isEmpty ? "\((path as NSString).lastPathComponent) exited \(proc.terminationStatus)" : msg)
        }
    }
}
