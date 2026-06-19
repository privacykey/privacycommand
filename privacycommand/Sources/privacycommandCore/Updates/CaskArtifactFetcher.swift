import Foundation

/// Downloads an outdated Homebrew cask's **incoming** artifact, hands the `.app`
/// inside it to a caller, and guarantees teardown (DMG detach / temp-dir
/// removal) on every exit path.
///
/// Supported formats in v1: `.dmg` (mounted read-only via `DMGMounter`) and
/// `.zip` (extracted with `ditto -x -k`). `.pkg` and anything else are rejected
/// **before** downloading, so we never pull hundreds of MB we can't open.
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
            case .dmg, .zip:      return true
            case .pkg, .unknown:  return false
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

        public var errorDescription: String? {
            switch self {
            case .brewNotFound:            return "Homebrew (`brew`) not found."
            case .cacheLookupFailed:       return "Couldn't resolve the cask's download path from `brew --cache`."
            case .unsupportedFormat(let f):return "Incoming build is a .\(f.label) artifact — only .dmg and .zip casks can be previewed."
            case .fetchFailed(let m):      return "brew fetch failed: \(m)"
            case .extractionFailed(let m): return "Couldn't extract the archive: \(m)"
            case .dittoUnavailable:        return "/usr/bin/ditto isn't available to extract the .zip."
            case .noAppInside:             return "No .app bundle was found inside the download."
            case .attachFailed(let m):     return "Couldn't mount the disk image: \(m)"
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

    /// Resolve the cask's incoming artifact, expose the `.app` inside it to
    /// `body`, and tear everything down afterwards — on success or throw.
    /// Unsupported formats throw `.unsupportedFormat` *before* any download.
    public static func withDownloadedApp<T>(
        token: String,
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
        switch format {
        case .dmg:
            let mount = try await mount(cacheURL)
            return try await withCleanup({ try? await DMGMounter.detach(mount) }) {
                guard let app = firstApp(in: mount.allMountPoints) else { throw FetchError.noAppInside }
                return try body(app)
            }
        case .zip:
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else {
                throw FetchError.dittoUnavailable
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("auditctl-fetch-\(UUID().uuidString)", isDirectory: true)
            try extractZip(cacheURL, into: dir)
            return try await withCleanup({ try? FileManager.default.removeItem(at: dir) }) {
                guard let app = DMGMounter.firstAppBundle(in: dir) else { throw FetchError.noAppInside }
                return try body(app)
            }
        case .pkg, .unknown:
            throw FetchError.unsupportedFormat(format)   // unreachable — guarded above
        }
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

    private static func firstApp(in points: [URL]) -> URL? {
        for p in points {
            if let app = DMGMounter.firstAppBundle(in: p) { return app }
        }
        return nil
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -x -k: extract a PKZip archive. ditto (unlike unzip) drops the
        // __MACOSX/AppleDouble noise and preserves bundle symlinks + perms.
        proc.arguments = ["-x", "-k", zip.path, dir.path]
        let err = Pipe()
        proc.standardOutput = FileHandle.nullDevice   // ditto is silent on stdout; nothing to drain
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw FetchError.extractionFailed(error.localizedDescription)
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: dir)
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FetchError.extractionFailed(msg?.isEmpty == false ? msg! : "ditto exited \(proc.terminationStatus)")
        }
    }
}
