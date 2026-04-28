import Foundation

// MARK: - Public types

public struct RunSearchHit: Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, Hashable, Sendable {
        case bundleInfo
        case privacyKey
        case finding
        case hardcodedDomain
        case hardcodedPath
        case networkHost
        case fileEvent

        public var label: String {
            switch self {
            case .bundleInfo:        return "Bundle"
            case .privacyKey:        return "Privacy key"
            case .finding:           return "Finding"
            case .hardcodedDomain:   return "Hard-coded domain"
            case .hardcodedPath:     return "Hard-coded path"
            case .networkHost:       return "Network"
            case .fileEvent:         return "File event"
            }
        }
        public var systemImage: String {
            switch self {
            case .bundleInfo:        return "shippingbox"
            case .privacyKey:        return "key"
            case .finding:           return "exclamationmark.triangle"
            case .hardcodedDomain:   return "globe"
            case .hardcodedPath:     return "folder"
            case .networkHost:       return "network"
            case .fileEvent:         return "doc"
            }
        }
    }

    public let id: String
    public let runID: UUID
    public let runDisplayName: String
    public let runVersion: String?
    public let runEndedAt: Date
    public let category: Category
    public let detail: String   // The matched value, for display
    public let context: String? // Optional secondary context (process, op, port…)

    public init(
        runID: UUID,
        runDisplayName: String,
        runVersion: String?,
        runEndedAt: Date,
        category: Category,
        detail: String,
        context: String? = nil
    ) {
        self.id = "\(runID.uuidString):\(category.rawValue):\(detail.prefix(120))"
        self.runID = runID
        self.runDisplayName = runDisplayName
        self.runVersion = runVersion
        self.runEndedAt = runEndedAt
        self.category = category
        self.detail = detail
        self.context = context
    }
}

public struct RunSearchResult: Hashable, Sendable, Identifiable {
    public var id: UUID { meta.id }
    public let meta: RunReportMeta
    public let hits: [RunSearchHit]
    public var hitCount: Int { hits.count }
}

// MARK: - Searcher

/// Streams a query across saved runs in parallel, looking inside the full
/// `RunReport` JSON of each run for matches in:
///   - bundle name / id
///   - declared privacy keys (raw key, purpose string)
///   - findings (severity, message)
///   - hard-coded domains, paths, URLs from the static analyzer
///   - dynamic network events (host, IP)
///   - dynamic file events (path)
///
/// Designed for libraries up to a few thousand runs; persistent indexing is
/// out of scope for MVP. Each run's full JSON is read off-thread; results are
/// grouped and sorted newest-first so users land on the freshest match.
public final class RunSearcher: Sendable {

    public init() {}

    /// Search every meta in `runs`. Returns a list of result groups, one per
    /// matching run, sorted by `endedAt` desc. A meta with no hits is omitted.
    public func search(query: String, in runs: [RunReportMeta]) async -> [RunSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let groups = await withTaskGroup(of: RunSearchResult?.self) { group -> [RunSearchResult] in
            for meta in runs {
                group.addTask {
                    let hits = await Self.searchOne(query: q, meta: meta)
                    return hits.isEmpty ? nil : RunSearchResult(meta: meta, hits: hits)
                }
            }
            var out: [RunSearchResult] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }
        return groups.sorted { $0.meta.endedAt > $1.meta.endedAt }
    }

    // MARK: - Per-run

    /// Searches a single run's full JSON. Static-only and non-throwing — if
    /// the file is missing or malformed we return zero hits.
    private static func searchOne(query q: String, meta: RunReportMeta) async -> [RunSearchHit] {
        // Cheap metadata pre-checks first, before paying for a JSON decode.
        var hits: [RunSearchHit] = []
        let displayName = meta.bundle.bundleName ?? meta.bundle.bundleID ?? "?"

        if (meta.bundle.bundleName?.lowercased().contains(q) == true) ||
           (meta.bundle.bundleID?.lowercased().contains(q) == true) {
            hits.append(.init(
                runID: meta.id,
                runDisplayName: displayName,
                runVersion: meta.bundle.bundleVersion,
                runEndedAt: meta.endedAt,
                category: .bundleInfo,
                detail: meta.bundle.bundleID ?? meta.bundle.bundleName ?? "—"
            ))
        }

        // Now the deep search. RunStore.load is blocking; keep this off the
        // main actor by virtue of being called from a TaskGroup's background
        // task.
        guard let report = try? RunStore.shared.load(id: meta.id) else { return hits }

        let s = report.staticReport

        // Privacy keys
        for k in s.declaredPrivacyKeys {
            if k.rawKey.lowercased().contains(q) || k.purposeString.lowercased().contains(q) {
                hits.append(.init(
                    runID: meta.id, runDisplayName: displayName,
                    runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                    category: .privacyKey,
                    detail: k.rawKey,
                    context: k.purposeString.isEmpty ? "(empty purpose string)" : k.purposeString
                ))
            }
        }

        // Findings
        for f in s.warnings where f.message.lowercased().contains(q) {
            hits.append(.init(
                runID: meta.id, runDisplayName: displayName,
                runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                category: .finding,
                detail: f.message,
                context: f.severity.rawValue
            ))
        }

        // Hard-coded domains
        for d in s.hardcodedDomains where d.lowercased().contains(q) {
            hits.append(.init(
                runID: meta.id, runDisplayName: displayName,
                runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                category: .hardcodedDomain,
                detail: d
            ))
        }

        // Hard-coded paths
        for p in s.hardcodedPaths where p.lowercased().contains(q) {
            hits.append(.init(
                runID: meta.id, runDisplayName: displayName,
                runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                category: .hardcodedPath,
                detail: p
            ))
        }

        // Dynamic events. Walk once, dispatch on case to avoid two passes.
        for event in report.events {
            switch event {
            case .network(let n):
                let host = n.remoteHostname ?? n.remoteEndpoint.address
                if host.lowercased().contains(q) || n.remoteEndpoint.address.contains(q) {
                    hits.append(.init(
                        runID: meta.id, runDisplayName: displayName,
                        runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                        category: .networkHost,
                        detail: host,
                        context: "\(n.processName) → :\(n.remoteEndpoint.port) (\(n.netProto.rawValue.uppercased()))"
                    ))
                }
            case .file(let f):
                if f.path.lowercased().contains(q) {
                    hits.append(.init(
                        runID: meta.id, runDisplayName: displayName,
                        runVersion: meta.bundle.bundleVersion, runEndedAt: meta.endedAt,
                        category: .fileEvent,
                        detail: f.path,
                        context: "\(f.processName) \(f.op.rawValue) (\(f.category.rawValue))"
                    ))
                }
            case .process:
                continue   // Process events don't carry user-meaningful strings beyond the path, which is covered by hardcodedPaths.
            }
        }

        return hits
    }
}
