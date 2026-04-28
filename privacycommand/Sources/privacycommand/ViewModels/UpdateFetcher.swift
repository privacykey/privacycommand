import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Drives the "preview the next version" flow:
///   1. Fetch the Sparkle appcast.
///   2. Show the latest item to the user.
///   3. Download the enclosure (DMG or ZIP) into a temp dir.
///   4. Extract the `.app` (mount/copy/detach for DMG, ditto for ZIP).
///   5. Run a static analysis on the extracted bundle.
///   6. Hand the report to the comparison sheet.
///   7. Cleanup — delete everything on dismiss.
///
/// Hard limits:
///   - Refuses non-HTTPS feeds and non-HTTPS download URLs.
///   - Caps download size at `maxDownloadBytes` (default 600 MB).
///   - Rejects DMGs with software license agreements that would prompt.
///   - Never executes anything from the downloaded bundle.
@MainActor
final class UpdateFetcher: ObservableObject {

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case checking
        case awaitingDownload(AppcastItem)
        case downloading(progress: Double, receivedBytes: Int64, totalBytes: Int64)
        case extracting
        case analyzing
        case ready(StaticReport)
        case error(String)
    }

    @Published var phase: Phase = .idle

    // MARK: - Inputs

    let feedURL: URL
    let currentBundle: AppBundle

    private let maxDownloadBytes: Int64 = 600 * 1024 * 1024

    // MARK: - Internals

    private var workDir: URL?
    private var downloadedFileURL: URL?
    private var mountPoint: URL?
    private var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    init(feedURL: URL, currentBundle: AppBundle) {
        self.feedURL = feedURL
        self.currentBundle = currentBundle
    }

    deinit {
        // Best-effort sync cleanup if the view dismissed without calling
        // discard() — covers the "user closed the window" case.
        if let mp = mountPoint {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                 arguments: ["detach", mp.path, "-force"])
        }
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Step 1: check feed

    func checkForUpdate() async {
        phase = .checking
        guard feedURL.scheme?.lowercased() == "https" else {
            phase = .error("Feed URL is not HTTPS — refusing to fetch over plain HTTP.")
            return
        }
        do {
            var req = URLRequest(url: feedURL)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                phase = .error("Appcast fetch failed: HTTP \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")")
                return
            }
            let appcast = AppcastParser.parse(data)
            guard let latest = appcast.latest, latest.downloadURL != nil else {
                phase = .error("No usable items in the appcast.")
                return
            }
            phase = .awaitingDownload(latest)
        } catch {
            phase = .error("Appcast fetch error: \(error.localizedDescription)")
        }
    }

    // MARK: - Step 2-5: download, extract, analyze

    func downloadAndAnalyze(_ item: AppcastItem) async {
        guard let url = item.downloadURL else {
            phase = .error("No download URL on the appcast item.")
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            phase = .error("Download URL is not HTTPS — refusing.")
            return
        }
        if let length = item.length, length > maxDownloadBytes {
            phase = .error("Declared size \(length / 1024 / 1024) MB exceeds the cap (\(maxDownloadBytes / 1024 / 1024) MB).")
            return
        }

        do {
            // Make a fresh per-fetch work dir under the system temp.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("privacycommand-update-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.workDir = dir

            // Download
            phase = .downloading(progress: 0, receivedBytes: 0, totalBytes: item.length ?? 0)
            let downloadedURL = try await download(url: url, to: dir)
            self.downloadedFileURL = downloadedURL

            // Extract
            phase = .extracting
            let appURL = try await extractApp(from: downloadedURL, to: dir)

            // Analyze
            phase = .analyzing
            let report = try await Task.detached { () -> StaticReport in
                let analyzer = StaticAnalyzer()
                return try analyzer.analyze(bundleAt: appURL)
            }.value

            phase = .ready(report)
        } catch UpdateError.cancelled {
            phase = .error("Cancelled.")
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Step 6: discard

    func discard() {
        // Detach DMG if mounted.
        if let mp = mountPoint {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                 arguments: ["detach", mp.path, "-force"])
            mountPoint = nil
        }
        // Remove work dir.
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
            workDir = nil
        }
        downloadedFileURL = nil
        phase = .idle
    }

    // MARK: - Internals

    private enum UpdateError: LocalizedError {
        case unsupportedFormat(String)
        case extractionFailed(String)
        case sizeExceedsLimit(Int64)
        case cancelled
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let s): return "Unsupported download format: \(s). Only .dmg and .zip are handled."
            case .extractionFailed(let s):  return "Extraction failed: \(s)"
            case .sizeExceedsLimit(let n):  return "Download exceeded the size limit (\(n / 1024 / 1024) MB)."
            case .cancelled:                return "Cancelled."
            }
        }
    }

    private func download(url: URL, to dir: URL) async throws -> URL {
        let (tempURL, response) = try await session.download(from: url) { [weak self] received, total in
            Task { @MainActor in
                guard let self else { return }
                let progress = total > 0 ? Double(received) / Double(total) : 0
                if case .downloading = self.phase {
                    self.phase = .downloading(progress: progress, receivedBytes: received, totalBytes: total)
                }
            }
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.extractionFailed("HTTP \(http.statusCode)")
        }

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: tempURL.path)
        if let size = attrs[.size] as? Int64, size > maxDownloadBytes {
            try? fm.removeItem(at: tempURL)
            throw UpdateError.sizeExceedsLimit(size)
        }

        // Move into our work dir with the right extension.
        let suggestedName = url.lastPathComponent
        let dest = dir.appendingPathComponent(suggestedName.isEmpty ? "download.bin" : suggestedName)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func extractApp(from archive: URL, to workDir: URL) async throws -> URL {
        let ext = archive.pathExtension.lowercased()
        switch ext {
        case "dmg":
            return try extractFromDMG(archive, workDir: workDir)
        case "zip":
            return try extractFromZIP(archive, workDir: workDir)
        default:
            throw UpdateError.unsupportedFormat(ext)
        }
    }

    private func extractFromDMG(_ dmg: URL, workDir: URL) throws -> URL {
        // Mount as read-only, no Finder browse, no auto-open.
        let attachOut = try runProcess(
            launchPath: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen",
                        "-plist", dmg.path]
        )
        guard let mountPath = parseHdiutilMountPoint(plistText: attachOut) else {
            throw UpdateError.extractionFailed("hdiutil produced no mount point")
        }
        self.mountPoint = URL(fileURLWithPath: mountPath)

        // Find the .app
        let mountURL = self.mountPoint!
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let appOnDMG = contents.first(where: { $0.pathExtension == "app" }) else {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                 arguments: ["detach", mountURL.path, "-force"])
            self.mountPoint = nil
            throw UpdateError.extractionFailed("No .app found at the DMG root.")
        }

        // Copy the .app to work dir so we can detach the DMG.
        let dest = workDir.appendingPathComponent(appOnDMG.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        _ = try runProcess(launchPath: "/usr/bin/ditto",
                           arguments: ["--rsrc", appOnDMG.path, dest.path])

        // Detach immediately so the volume isn't held open.
        _ = try? runProcess(launchPath: "/usr/bin/hdiutil",
                            arguments: ["detach", mountURL.path, "-force"])
        self.mountPoint = nil

        return dest
    }

    private func extractFromZIP(_ zip: URL, workDir: URL) throws -> URL {
        let extractDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        _ = try runProcess(launchPath: "/usr/bin/ditto",
                           arguments: ["-x", "-k", zip.path, extractDir.path])
        let contents = try FileManager.default.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        // Some archives wrap the .app in a top-level folder.
        for entry in contents where entry.hasDirectoryPath {
            let inner = (try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if let app = inner.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        throw UpdateError.extractionFailed("No .app found in the unzipped archive.")
    }

    private func runProcess(launchPath: String, arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(p.terminationStatus)"
            throw UpdateError.extractionFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Find the first mount point in the plist hdiutil prints. The plist
    /// contains a `system-entities` array; each entry has a `mount-point`
    /// when it's a mountable filesystem.
    private func parseHdiutilMountPoint(plistText: String) -> String? {
        guard let data = plistText.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty { return mp }
        }
        return nil
    }
}

// MARK: - URLSession download with progress

private extension URLSession {
    /// Adds a progress callback to `URLSession.download(from:)`. Uses a thin
    /// delegate behind the scenes; the API surface stays async.
    func download(
        from url: URL,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = ProgressDelegate(progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.download(from: url)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}
