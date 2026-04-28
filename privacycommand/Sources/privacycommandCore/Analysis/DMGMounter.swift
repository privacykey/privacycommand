import Foundation

/// Wraps `hdiutil` for read-only DMG mount/detach + a small helper to
/// find the first `.app` bundle inside a freshly-mounted volume.
///
/// **Why we shell out** rather than using DiskImages.framework — that
/// framework requires extra entitlements we don't ship with, and the
/// CLI is well-documented, predictable, and easy to parse with the
/// `-plist` flag. We always pass `-readonly -nobrowse -noautoopen` so
/// mounted images don't show up in the user's Finder sidebar and the
/// underlying file isn't modified.
public enum DMGMounter {

    public struct Mount: Sendable, Hashable, Codable {
        public let dmgURL: URL
        /// First mount point (the one we'll search for a .app in).
        public let primaryMountPoint: URL
        /// Every mount point hdiutil reported. Multi-volume DMGs (rare
        /// but real) need all of these to be `detach`ed on cleanup.
        public let allMountPoints: [URL]

        public init(dmgURL: URL,
                    primaryMountPoint: URL,
                    allMountPoints: [URL]) {
            self.dmgURL = dmgURL
            self.primaryMountPoint = primaryMountPoint
            self.allMountPoints = allMountPoints
        }
    }

    public enum MountError: LocalizedError {
        case hdiutilUnavailable
        case hdiutilFailed(Int32, String)
        case parseFailed
        case noMountPoints

        public var errorDescription: String? {
            switch self {
            case .hdiutilUnavailable:
                return "/usr/bin/hdiutil isn't available on this system."
            case .hdiutilFailed(let code, let stderr):
                return "hdiutil exited with status \(code). \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .parseFailed:
                return "Couldn't parse hdiutil's plist output."
            case .noMountPoints:
                return "The disk image mounted but reported no mount points — nothing to inspect."
            }
        }
    }

    /// Mount a DMG read-only and return where it landed. Yields a
    /// non-zero `Mount` even for multi-volume DMGs — the caller picks
    /// which volume to inspect (we default to the first).
    public static func mount(dmg url: URL) async throws -> Mount {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else {
            throw MountError.hdiutilUnavailable
        }
        let result = try await runHdiutil(arguments: [
            "attach", "-nobrowse", "-noautoopen", "-readonly", "-plist", url.path
        ])
        guard let plist = try? PropertyListSerialization.propertyList(
            from: result, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw MountError.parseFailed
        }
        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let first = mountPoints.first else {
            throw MountError.noMountPoints
        }
        return Mount(dmgURL: url,
                     primaryMountPoint: first,
                     allMountPoints: mountPoints)
    }

    /// Detach every mount point associated with a `Mount`. Forgiving —
    /// uses `-force` after a brief retry so a still-busy volume isn't
    /// blocked indefinitely if the user's just closed the auditor.
    public static func detach(_ mount: Mount) async throws {
        for point in mount.allMountPoints {
            do {
                _ = try await runHdiutil(arguments: ["detach", point.path])
            } catch {
                // Retry once with -force.
                _ = try? await runHdiutil(arguments: ["detach", "-force", point.path])
            }
        }
    }

    /// Walk a freshly-mounted volume looking for the first `.app`
    /// bundle. We deliberately stop at the first hit — most DMGs ship a
    /// single app, and surfacing a chooser for the rare multi-app DMG
    /// would be more confusing than helpful.
    public static func firstAppBundle(in mountPoint: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        // Prefer top-level .app first — most DMGs have exactly that.
        if let top = entries.first(where: { $0.pathExtension == "app" }) {
            return top
        }
        // Otherwise walk one level deeper (some DMGs nest under "Applications/").
        for sub in entries where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let app = firstAppBundle(in: sub) { return app }
        }
        return nil
    }

    // MARK: - Subprocess

    private static func runHdiutil(arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            task.arguments = arguments
            // Suppress the License Agreement prompt by sending /dev/null
            // on stdin. macOS's hdiutil shows the SLA on read-only
            // attaches if the DMG ships one; with stdin closed it emits
            // the EULA text and exits non-zero. We accept that — the
            // user can run `hdiutil attach -agree` themselves if they
            // need to bypass an SLA-bearing image.
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardInput = FileHandle(forReadingAtPath: "/dev/null")
            task.standardOutput = outPipe
            task.standardError = errPipe

            // 60-second wall-clock cap. Mounting a sparse DMG can be
            // slow on first attach but rarely takes more than a few
            // seconds. We don't want to wedge the auditor if hdiutil
            // wedges.
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if task.isRunning { task.terminate() }
            }
            task.terminationHandler = { proc in
                timeoutTask.cancel()
                let outData = outPipe.fileHandleForReading.availableData
                let errData = errPipe.fileHandleForReading.availableData
                if proc.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: MountError.hdiutilFailed(
                        proc.terminationStatus, stderr))
                }
            }
            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
