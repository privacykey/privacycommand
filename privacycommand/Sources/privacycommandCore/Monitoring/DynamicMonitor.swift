import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Orchestrates a monitored run.
///
/// Tier A (this build): launches the bundle via `NSWorkspace`, tracks PIDs via
/// `ProcessTracker`, and tracks network destinations via `NetworkMonitor`.
/// File monitoring is intentionally **disabled** in Tier A — the UI must show
/// "Install the privileged helper for file events" rather than silently produce
/// empty output.
public actor DynamicMonitor {

    public enum State: Sendable, Equatable {
        case idle
        case launching
        case running(rootPID: Int32)
        case stopping
        case finished
        case failed(String)
    }

    public enum Tier: Sendable {
        case a    // user-space, no helper
        case b    // privileged helper installed
        case c    // ES + Network Extension
    }

    public nonisolated let stream: AsyncStream<DynamicEvent>
    private var continuation: AsyncStream<DynamicEvent>.Continuation?

    public private(set) var state: State = .idle
    public nonisolated let tier: Tier
    public nonisolated let bundle: AppBundle
    public nonisolated let staticReport: StaticReport
    public nonisolated let pathClassifier: PathClassifier
    public nonisolated let riskClassifier: RiskClassifier

    private var processTracker: ProcessTracker?
    private var networkMonitor: NetworkMonitor?
    private var startedAt: Date = .init()
    private var endedAt: Date?
    private var fileMonitorEnabled = false
    private var pidNames: [Int32: String] = [:]

    public init(
        bundle: AppBundle,
        staticReport: StaticReport,
        tier: Tier = .a,
        pathClassifier: PathClassifier = .init(),
        riskClassifier: RiskClassifier? = nil
    ) {
        self.bundle = bundle
        self.staticReport = staticReport
        self.tier = tier
        self.pathClassifier = pathClassifier
        self.riskClassifier = riskClassifier ?? RiskClassifier(
            declaredCategories: Set(staticReport.declaredPrivacyKeys.map(\.category))
        )
        // makeStream() avoids the IUO trick — see LiveProbeMonitor.init.
        let (stream, continuation) = AsyncStream<DynamicEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Launches the target bundle and starts the monitors. Returns the root PID.
    @discardableResult
    public func start() async throws -> Int32 {
        state = .launching
        let pid: Int32
        #if canImport(AppKit)
        pid = try await launchViaWorkspace()
        #else
        throw DynamicMonitorError.appKitUnavailable
        #endif

        startedAt = Date()
        state = .running(rootPID: pid)

        // Seed the tracker with the root PID PLUS the bundle path so that
        // helpers launched via XPC / launchd (Chrome's Helper apps, Slack's
        // XPC services, etc.) are picked up even though their ppid is 1.
        let pt = ProcessTracker(rootPID: pid, bundlePathPrefix: bundle.url.path)
        self.processTracker = pt
        await pt.start()

        let nm = NetworkMonitor(initialPIDs: [pid])
        self.networkMonitor = nm
        await nm.start()

        // Forward sub-streams into the public stream.
        Task { [weak self] in
            guard let self else { return }
            for await event in pt.stream {
                await self.handle(processEvent: event)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await event in nm.stream {
                await self.handle(networkEvent: event)
            }
        }
        return pid
    }

    public func stop() async {
        state = .stopping
        await processTracker?.stop()
        await networkMonitor?.stop()
        endedAt = Date()
        state = .finished
        continuation?.finish()
    }

    /// Snapshot of the currently-tracked PIDs (root + descendants). Used by
    /// auxiliary monitors (e.g. ResourceMonitor) that need to mirror the
    /// process tree.
    public func currentTrackedPIDs() async -> Set<Int32> {
        guard let pt = processTracker else { return [] }
        return await pt.currentPIDs
    }

    public nonisolated func summarize(events: [DynamicEvent]) -> RunSummary {
        let processCount = events.compactMap { e -> Int32? in
            if case .process(let p) = e, p.kind == .start { return p.pid }
            return nil
        }.count
        let fileEvents = events.compactMap { e -> FileEvent? in
            if case .file(let f) = e { return f } else { return nil }
        }
        let networkEvents = events.compactMap { e -> NetworkEvent? in
            if case .network(let n) = e { return n } else { return nil }
        }
        let topHosts = Dictionary(grouping: networkEvents, by: { $0.remoteHostname ?? $0.remoteEndpoint.address })
            .map { (host, evs) in
                HostFrequency(
                    host: host,
                    bytesSent: evs.reduce(0) { $0 + $1.bytesSent },
                    bytesReceived: evs.reduce(0) { $0 + $1.bytesReceived },
                    connectionCount: evs.count
                )
            }
            .sorted { $0.connectionCount > $1.connectionCount }
            .prefix(20)

        let topCats = Dictionary(grouping: fileEvents, by: { $0.category })
            .map { PathCategoryCount(category: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(20)

        let surprising = fileEvents.filter { $0.risk == .surprising }.count
            + networkEvents.filter { $0.risk == .surprising }.count

        let risk = RiskScorer().score(staticReport: staticReport, events: events)

        return RunSummary(
            processCount: processCount,
            fileEventCount: fileEvents.count,
            networkEventCount: networkEvents.count,
            topRemoteHosts: Array(topHosts),
            topPathCategories: Array(topCats),
            surprisingEventCount: surprising,
            riskScore: risk
        )
    }

    /// Returns the fidelity notes that should appear in the report.
    public nonisolated var fidelityNotes: [String] {
        var notes: [String] = []
        notes.append("Process tracking is poll-based at 250 ms; processes that fork+exec+exit faster than that may be missed.")
        notes.append("Network monitoring is poll-based at 500 ms; short-lived UDP queries may be missed and TLS payloads are never decrypted.")
        switch tier {
        case .a:
            notes.append("File-system monitoring is disabled in this build. Install the privileged helper to enable best-effort fs_usage-based file events.")
        case .b:
            notes.append("File-system monitoring is via fs_usage(1) running in the privileged helper. fs_usage may drop events under heavy load.")
        case .c:
            notes.append("File-system monitoring is via Endpoint Security; events are kernel-attributed.")
        }
        return notes
    }

    // MARK: - Internal

    private func handle(processEvent event: ProcessEvent) async {
        if event.kind == .start || event.kind == .exec {
            pidNames[event.pid] = (event.path as NSString).lastPathComponent
        }
        if event.kind == .exit {
            pidNames[event.pid] = nil
        }
        if let pt = processTracker, let nm = networkMonitor {
            let pids = await pt.currentPIDs
            await nm.updatePIDs(pids)
        }
        continuation?.yield(.process(event))
    }

    private func handle(networkEvent event: NetworkEvent) async {
        continuation?.yield(.network(event))
    }

    /// Called by the helper bridge (Tier B) or an ES client (Tier C) to inject
    /// a file event. Classifies the path category if the source supplied
    /// `.unknown`, then runs the risk classifier and yields the result.
    public func ingest(file event: FileEvent) {
        // Helpers / ES clients don't always know the user's home, so they may
        // have sent `.unknown`. Resolve it here using our path classifier.
        let resolvedCategory: PathCategory = event.category == .unknown
            ? pathClassifier.classify(event.path, ownerBundleURL: bundle.url)
            : event.category

        let withCategory = FileEvent(
            id: event.id,
            timestamp: event.timestamp,
            pid: event.pid,
            processName: event.processName,
            op: event.op,
            path: event.path,
            secondaryPath: event.secondaryPath,
            category: resolvedCategory,
            risk: .expected,
            ruleID: nil
        )
        let decision = riskClassifier.classify(file: withCategory)
        let final = FileEvent(
            id: withCategory.id,
            timestamp: withCategory.timestamp,
            pid: withCategory.pid,
            processName: withCategory.processName,
            op: withCategory.op,
            path: withCategory.path,
            secondaryPath: withCategory.secondaryPath,
            category: withCategory.category,
            risk: decision.risk,
            ruleID: decision.ruleID
        )
        continuation?.yield(.file(final))
    }

    #if canImport(AppKit)
    private func launchViaWorkspace() async throws -> Int32 {
        let url = bundle.url
        return try await withCheckedThrowingContinuation { cont in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { running, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let running, running.processIdentifier > 0 else {
                    cont.resume(throwing: DynamicMonitorError.couldNotResolvePID)
                    return
                }
                cont.resume(returning: running.processIdentifier)
            }
        }
    }
    #endif
}

public enum DynamicMonitorError: Error, LocalizedError {
    case appKitUnavailable
    case couldNotResolvePID

    public var errorDescription: String? {
        switch self {
        case .appKitUnavailable:    return "AppKit is unavailable in this build; cannot launch the target."
        case .couldNotResolvePID:   return "NSWorkspace launched the app but did not return a PID."
        }
    }
}
