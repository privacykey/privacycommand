import Foundation

// MARK: - Lightweight metadata

/// A *subset* of `RunReport`'s fields, decoded from the same JSON. Used to
/// populate history lists without loading every event into memory.
///
/// Codable's default behavior is to ignore unknown JSON keys, so this struct
/// can decode any `RunReport.json` produced by `JSONExporter` regardless of
/// how rich the original report was.
public struct RunReportMeta: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let auditorVersion: String
    public let startedAt: Date
    public let endedAt: Date
    public let bundle: BundleMeta
    public let summary: SummaryMeta

    public struct BundleMeta: Codable, Hashable, Sendable {
        public let bundleID: String?
        public let bundleName: String?
        public let bundleVersion: String?
    }
    public struct SummaryMeta: Codable, Hashable, Sendable {
        public let processCount: Int
        public let fileEventCount: Int
        public let networkEventCount: Int
        public let surprisingEventCount: Int
        public let riskScore: RiskScore
    }

    public var displayName: String {
        bundle.bundleName ?? bundle.bundleID ?? "Untitled"
    }
    public var durationSeconds: Int {
        Int(endedAt.timeIntervalSince(startedAt))
    }
}

// MARK: - Store

/// Disk-backed run history. Each run is a directory under
/// `~/Library/Application Support/privacycommand/runs/<uuid>/` containing
/// a `report.json` (the full `RunReport` produced by `JSONExporter`).
///
/// Operations are synchronous and do disk I/O; call from a background queue
/// or `Task` if invoked from the main actor and you don't want to block.
public final class RunStore: @unchecked Sendable {

    public static let shared = RunStore()

    public let baseURL: URL

    public init() {
        // FileManager.urls(for:in:) returns [URL]. In the overwhelmingly
        // common case it has one element, but on certain sandbox
        // configurations / MDM-managed Macs / TCC-restricted setups it
        // can come back empty. The original `.first!` here was a
        // dormant trap waiting on those edge cases — a 0.1.1 user hit
        // it in the wild. Fall back to ~/Library/Application Support
        // composed from NSHomeDirectory(); same path the system would
        // have returned, but produced via a different API that doesn't
        // give up on us.
        let appSupportRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        let dir = appSupportRoot
            .appendingPathComponent("privacycommand", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseURL = dir
    }

    /// Save (overwriting) the report into its own subdirectory. Returns the
    /// final URL of the JSON file.
    @discardableResult
    public func save(_ report: RunReport) throws -> URL {
        let dir = directory(for: report.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("report.json")
        try JSONExporter.write(report: report, to: url)
        return url
    }

    /// Enumerate all saved runs as lightweight metadata. Sorted newest-first.
    public func list() -> [RunReportMeta] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var metas: [RunReportMeta] = []
        for entry in entries where entry.hasDirectoryPath {
            let reportURL = entry.appendingPathComponent("report.json")
            guard let data = try? Data(contentsOf: reportURL) else { continue }
            if let meta = try? decoder.decode(RunReportMeta.self, from: data) {
                metas.append(meta)
            }
        }
        return metas.sorted { $0.endedAt > $1.endedAt }
    }

    /// Load the full report for a given run id.
    public func load(id: UUID) throws -> RunReport {
        let url = directory(for: id).appendingPathComponent("report.json")
        let data = try Data(contentsOf: url)
        return try JSONExporter.decode(data)
    }

    /// Permanently delete a saved run.
    public func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Filesystem path of a saved run's directory (creates nothing — useful
    /// for `Reveal in Finder`).
    public func directory(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

// MARK: - Static-report cache

/// A disk cache of full `StaticReport`s, keyed by app bundle and invalidated
/// when the app's binary / Info.plist changes or the auditor version changes.
///
/// Why this exists: a "Scan all apps" pass already runs the full
/// `StaticAnalyzer` over every bundle, then discards the heavy `StaticReport`
/// to keep the batch table small (see `BatchAppResult`). Without a cache,
/// drilling into one of those apps re-runs the *identical* analysis from
/// scratch — the slow part the user already waited for. The batch scan now
/// writes each report here as it computes it, and the single-app open path
/// reads it back, so opening a just-scanned app is instant.
///
/// Freshness uses a cheap fingerprint computed *without* analysing the bundle:
/// the size + modification time of the main executable and Info.plist, plus the
/// auditor version. A lookup is therefore a couple of `stat`s and a small read.
/// When the app updates — or a newer auditor build changes the analysis logic —
/// the fingerprint no longer matches and the entry is recomputed. The cache is
/// strictly an optimisation: any uncertainty (unreadable bundle, decode
/// failure, write error) degrades to a normal scan, never a wrong result.
public final class StaticReportCache: @unchecked Sendable {

    public static let shared = StaticReportCache()

    public let baseURL: URL

    public init() {
        // Same Application Support resolution as `RunStore` — see the note
        // there on why we don't force-unwrap `urls(for:in:).first`.
        let appSupportRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupportRoot
            .appendingPathComponent("privacycommand", isDirectory: true)
            .appendingPathComponent("static-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.baseURL = dir
    }

    /// Test seam: point the cache at an arbitrary directory so unit tests don't
    /// touch the shared Application Support cache.
    init(baseURL: URL) {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        self.baseURL = baseURL
    }

    private struct Entry: Codable {
        let fingerprint: String
        let report: StaticReport
    }

    /// Return a cached report for `url` iff one exists and its fingerprint still
    /// matches the bundle on disk. Any miss — no entry, changed app, newer
    /// auditor, or an unreadable bundle — returns `nil` so the caller re-scans.
    public func load(for url: URL, auditorVersion: String) -> StaticReport? {
        guard let fp = fingerprint(for: url, auditorVersion: auditorVersion),
              let data = try? Data(contentsOf: entryURL(for: url)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(Entry.self, from: data),
              entry.fingerprint == fp else { return nil }
        return entry.report
    }

    /// Persist `report` for `url`. Best-effort: a bundle we can't fingerprint
    /// (or a write failure) is silently skipped.
    public func store(_ report: StaticReport, for url: URL, auditorVersion: String) {
        guard let fp = fingerprint(for: url, auditorVersion: auditorVersion) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Entry(fingerprint: fp, report: report)) else { return }
        try? data.write(to: entryURL(for: url), options: .atomic)
    }

    /// Number of cached app analyses currently on disk.
    public var count: Int { entries().count }

    /// Total bytes the cache occupies on disk.
    public var sizeBytes: Int64 {
        entries().reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }

    /// Delete every cached report. Safe and non-destructive in the data sense:
    /// reports regenerate on demand, so this only costs a re-analysis the next
    /// time each app is opened.
    public func clear() {
        for url in entries() { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Internals

    private func entries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    /// Cache file for a bundle: a stable 64-bit FNV-1a of its absolute path, so
    /// the same app maps to the same file across launches without smuggling a
    /// long, awkward path into a filename.
    private func entryURL(for url: URL) -> URL {
        baseURL.appendingPathComponent("\(Self.fnv1a(url.standardizedFileURL.path)).json")
    }

    /// A cheap content fingerprint computed without analysing the bundle: the
    /// size + mtime of the Info.plist and the main executable, the bundle
    /// version, and the auditor version. Returns `nil` when the bundle can't be
    /// read — callers treat that as "don't serve from cache".
    func fingerprint(for url: URL, auditorVersion: String) -> String? {
        let fm = FileManager.default
        // Resolve Info.plist + main executable for both standard
        // (`Contents/…`) and flat bundle layouts.
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let hasContents = fm.fileExists(atPath: contents.path)
        let infoPlist = hasContents
            ? contents.appendingPathComponent("Info.plist")
            : url.appendingPathComponent("Info.plist")

        guard let plistData = try? Data(contentsOf: infoPlist),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil)) as? [String: Any],
              let execName = plist["CFBundleExecutable"] as? String
        else { return nil }

        let execDir = hasContents
            ? contents.appendingPathComponent("MacOS", isDirectory: true)
            : url
        guard let execStamp = Self.stamp(execDir.appendingPathComponent(execName), fm: fm)
        else { return nil }

        let plistStamp = Self.stamp(infoPlist, fm: fm) ?? "0:0"
        let version = (plist["CFBundleVersion"] as? String) ?? ""
        return "v1|\(auditorVersion)|\(version)|plist:\(plistStamp)|exec:\(execStamp)"
    }

    /// `"<size>:<mtime>"` for a file, or `nil` if it can't be stat'd.
    private static func stamp(_ url: URL, fm: FileManager) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(Int64(mtime))"
    }

    private static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
