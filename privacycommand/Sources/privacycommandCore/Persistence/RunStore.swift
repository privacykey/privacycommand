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
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
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
