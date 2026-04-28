import Foundation

public struct RunReport: Codable, Hashable, Sendable {
    public let id: UUID
    public let auditorVersion: String
    public let startedAt: Date
    public let endedAt: Date
    public let bundle: AppBundle
    public let staticReport: StaticReport
    public let events: [DynamicEvent]
    public let summary: RunSummary
    public let fidelityNotes: [String]
    /// Behavioural anomalies detected over the run (periodic beacons,
    /// activity bursts, undeclared destinations). Backward-compatible
    /// Codable: older saved reports decode as `.empty`.
    public let behavior: BehaviorReport
    /// Pasteboard / camera / mic audit-log entries recorded over the run.
    public let liveProbeEvents: [LiveProbeEvent]

    public init(
        id: UUID = .init(),
        auditorVersion: String,
        startedAt: Date,
        endedAt: Date,
        bundle: AppBundle,
        staticReport: StaticReport,
        events: [DynamicEvent],
        summary: RunSummary,
        fidelityNotes: [String],
        behavior: BehaviorReport = .empty,
        liveProbeEvents: [LiveProbeEvent] = []
    ) {
        self.id = id
        self.auditorVersion = auditorVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundle = bundle
        self.staticReport = staticReport
        self.events = events
        self.summary = summary
        self.fidelityNotes = fidelityNotes
        self.behavior = behavior
        self.liveProbeEvents = liveProbeEvents
    }

    private enum CodingKeys: String, CodingKey {
        case id, auditorVersion, startedAt, endedAt, bundle, staticReport
        case events, summary, fidelityNotes, behavior, liveProbeEvents
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.auditorVersion = try c.decode(String.self, forKey: .auditorVersion)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try c.decode(Date.self, forKey: .endedAt)
        self.bundle = try c.decode(AppBundle.self, forKey: .bundle)
        self.staticReport = try c.decode(StaticReport.self, forKey: .staticReport)
        self.events = try c.decode([DynamicEvent].self, forKey: .events)
        self.summary = try c.decode(RunSummary.self, forKey: .summary)
        self.fidelityNotes = try c.decode([String].self, forKey: .fidelityNotes)
        self.behavior = try c.decodeIfPresent(BehaviorReport.self, forKey: .behavior) ?? .empty
        self.liveProbeEvents = try c.decodeIfPresent([LiveProbeEvent].self, forKey: .liveProbeEvents) ?? []
    }
}

public struct RunSummary: Codable, Hashable, Sendable {
    public let processCount: Int
    public let fileEventCount: Int
    public let networkEventCount: Int
    public let topRemoteHosts: [HostFrequency]
    public let topPathCategories: [PathCategoryCount]
    public let surprisingEventCount: Int
    public let riskScore: RiskScore

    public init(
        processCount: Int,
        fileEventCount: Int,
        networkEventCount: Int,
        topRemoteHosts: [HostFrequency],
        topPathCategories: [PathCategoryCount],
        surprisingEventCount: Int,
        riskScore: RiskScore = .zero
    ) {
        self.processCount = processCount
        self.fileEventCount = fileEventCount
        self.networkEventCount = networkEventCount
        self.topRemoteHosts = topRemoteHosts
        self.topPathCategories = topPathCategories
        self.surprisingEventCount = surprisingEventCount
        self.riskScore = riskScore
    }

    /// Tolerate older saved reports that don't have `riskScore`.
    private enum CodingKeys: String, CodingKey {
        case processCount, fileEventCount, networkEventCount,
             topRemoteHosts, topPathCategories, surprisingEventCount, riskScore
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.processCount         = try c.decode(Int.self, forKey: .processCount)
        self.fileEventCount       = try c.decode(Int.self, forKey: .fileEventCount)
        self.networkEventCount    = try c.decode(Int.self, forKey: .networkEventCount)
        self.topRemoteHosts       = try c.decode([HostFrequency].self, forKey: .topRemoteHosts)
        self.topPathCategories    = try c.decode([PathCategoryCount].self, forKey: .topPathCategories)
        self.surprisingEventCount = try c.decode(Int.self, forKey: .surprisingEventCount)
        self.riskScore            = try c.decodeIfPresent(RiskScore.self, forKey: .riskScore) ?? .zero
    }
}

public struct PathCategoryCount: Codable, Hashable, Sendable {
    public let category: PathCategory
    public let count: Int
    public init(category: PathCategory, count: Int) {
        self.category = category
        self.count = count
    }
}

public struct HostFrequency: Codable, Hashable, Sendable {
    public let host: String
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
    public let connectionCount: Int
    public init(host: String, bytesSent: UInt64, bytesReceived: UInt64, connectionCount: Int) {
        self.host = host
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.connectionCount = connectionCount
    }
}
