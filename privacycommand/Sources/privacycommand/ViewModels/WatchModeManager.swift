import Foundation
import SwiftUI
import Combine
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Long-running supervisor on top of `AnalysisCoordinator` that watches a
/// monitored run for *changes* — new hosts contacted, new behavioural
/// anomalies appearing, surprising file/network events — and surfaces them
/// as a deduplicated list with an unread counter for the menu-bar UI.
///
/// The coordinator already keeps the dynamic monitor running indefinitely;
/// this manager just diffs each tick of `coordinator.events` /
/// `coordinator.behaviorReport` against the previous state and emits one
/// `WatchModeChange` per genuinely-new thing.
@MainActor
final class WatchModeManager: ObservableObject {

    // MARK: - Published state

    /// Reverse-chronological log. Capped at `maxChanges` so the popover
    /// stays cheap to render even after a multi-day run.
    @Published private(set) var changes: [WatchModeChange] = []

    /// Number of changes the user hasn't seen yet. Drives the menu-bar
    /// badge.
    @Published private(set) var unreadCount: Int = 0

    /// True only while we're actively diffing the coordinator's stream.
    @Published private(set) var isWatching: Bool = false

    /// User-readable bundle name shown in the popover header. Captured at
    /// `start(coordinator:)` so it's stable even if the bundle changes.
    @Published private(set) var watchedBundleName: String = ""

    /// Started-at time, displayed as a "watching for X" callout.
    @Published private(set) var startedAt: Date?

    // MARK: - Internal state

    private weak var coordinator: AnalysisCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    private var seenHosts: Set<String> = []
    private var seenAnomalyIDs: Set<String> = []
    private var seenSurprisingEventIDs: Set<UUID> = []
    private var seenProbeEventIDs: Set<UUID> = []
    private var seenResourceSpikeIDs: Set<Date> = []
    private let maxChanges = 200

    // MARK: - Public API

    /// Begin observing `coordinator.events` / `coordinator.behaviorReport`.
    /// Caller is responsible for first having started a monitored run via
    /// the coordinator. Calling `start` while already watching is a no-op.
    func start(coordinator: AnalysisCoordinator) {
        guard !isWatching else { return }
        self.coordinator = coordinator
        self.isWatching = true
        self.startedAt = Date()
        self.watchedBundleName = coordinator.bundle?.bundleName
            ?? coordinator.bundle?.url.deletingPathExtension().lastPathComponent
            ?? "(unknown)"
        seenHosts.removeAll()
        seenAnomalyIDs.removeAll()
        seenSurprisingEventIDs.removeAll()
        seenProbeEventIDs.removeAll()
        seenResourceSpikeIDs.removeAll()
        changes.removeAll()
        unreadCount = 0
        // Seed the "previously seen" sets with whatever's already on the
        // coordinator so we don't double-report things from the warm-up
        // period before the user clicked Start Watching.
        recompute(seedingOnly: true)
        // We piggyback on `objectWillChange` of the coordinator instead of
        // KVO-ing every published property — the coordinator publishes on
        // every event arrival, so this fires often enough to catch
        // everything but cheap enough to ignore when nothing changed.
        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires *before* the new values are written;
                // hop one runloop tick so we read post-update state.
                DispatchQueue.main.async { self?.recompute(seedingOnly: false) }
            }
            .store(in: &cancellables)
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        coordinator = nil
        cancellables.removeAll()
    }

    /// Zero the unread badge. Doesn't touch the change log itself.
    func markAllRead() {
        unreadCount = 0
    }

    /// Clear the change log entirely.
    func clearLog() {
        changes.removeAll()
        unreadCount = 0
    }

    // MARK: - Diffing

    private func recompute(seedingOnly: Bool) {
        guard let coordinator else { return }

        // 1. New hosts.
        for case .network(let n) in coordinator.events {
            let host = n.remoteHostname ?? n.tlsSNI ?? n.remoteEndpoint.address
            guard !host.isEmpty, !seenHosts.contains(host) else { continue }
            seenHosts.insert(host)
            if !seedingOnly {
                emit(.init(kind: .newDestination(
                    host: host,
                    pid: n.pid,
                    processName: n.processName)))
            }
        }

        // 2. New behavioural anomalies.
        let report = coordinator.behaviorReport
        for anomaly in report.anomalies where !seenAnomalyIDs.contains(anomaly.id) {
            seenAnomalyIDs.insert(anomaly.id)
            if !seedingOnly {
                emit(.init(kind: .newAnomaly(anomaly)))
            }
        }

        // 3. New events with surprising risk. We don't enumerate every
        // event each tick (would be O(n²)); instead we rely on the
        // coordinator's eventIndices to give us the suffix that's new
        // since the last call.
        for ev in coordinator.events {
            switch ev {
            case .file(let f) where f.risk == .surprising:
                if seenSurprisingEventIDs.insert(f.id).inserted, !seedingOnly {
                    emit(.init(kind: .surprisingFile(f)))
                }
            case .network(let n) where n.risk == .surprising:
                if seenSurprisingEventIDs.insert(n.id).inserted, !seedingOnly {
                    emit(.init(kind: .surprisingNetwork(n)))
                }
            default: break
            }
        }

        // 4. Live probe events (pasteboard / camera / mic) — every new
        // one is interesting by definition.
        for probe in coordinator.liveProbeEvents
            where seenProbeEventIDs.insert(probe.id).inserted {
            if !seedingOnly {
                emit(.init(kind: .liveProbe(probe)))
            }
        }

        // 5. CPU spike samples. Each Sample is unique by timestamp so
        // we track seen samples by date.
        for sample in coordinator.resourceSamples
            where sample.wasSpike
            && seenResourceSpikeIDs.insert(sample.timestamp).inserted {
            if !seedingOnly {
                emit(.init(kind: .resourceSpike(sample)))
            }
        }
    }

    private func emit(_ change: WatchModeChange) {
        changes.insert(change, at: 0)
        if changes.count > maxChanges {
            changes.removeLast(changes.count - maxChanges)
        }
        unreadCount += 1
    }
}

// MARK: - Icon style

/// Five SF-Symbol-based options for the menu-bar watch icon. Persisted via
/// `@AppStorage("watchModeIconStyle")` (raw string of the case) so the
/// user's choice survives quits.
enum WatchModeIconStyle: String, CaseIterable, Identifiable {
    case eye          = "eye"
    case magnifier    = "magnifier"
    case binoculars   = "binoculars"
    case radar        = "radar"
    case shield       = "shield"

    var id: String { rawValue }

    /// Human-readable name in the settings dropdown.
    var displayName: String {
        switch self {
        case .eye:        return "Eye"
        case .magnifier:  return "Search bar (magnifying glass)"
        case .binoculars: return "Binoculars"
        case .radar:      return "Radar antenna"
        case .shield:     return "Shield"
        }
    }

    /// SF Symbol name when there are no unread changes.
    var idleSymbol: String {
        switch self {
        case .eye:        return "eye"
        case .magnifier:  return "magnifyingglass"
        case .binoculars: return "binoculars"
        case .radar:      return "antenna.radiowaves.left.and.right"
        case .shield:     return "shield"
        }
    }

    /// SF Symbol name when there *are* unread changes — solid / filled
    /// version for visual feedback.
    var alertSymbol: String {
        switch self {
        case .eye:        return "eye.fill"
        case .magnifier:  return "magnifyingglass.circle.fill"
        case .binoculars: return "binoculars.fill"
        case .radar:      return "antenna.radiowaves.left.and.right.circle.fill"
        case .shield:     return "shield.fill"
        }
    }
}

// MARK: - Change model

struct WatchModeChange: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind

    init(timestamp: Date = Date(), kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }

    enum Kind: Hashable {
        case newDestination(host: String, pid: Int32, processName: String)
        case newAnomaly(BehaviorReport.Anomaly)
        case surprisingFile(FileEvent)
        case surprisingNetwork(NetworkEvent)
        case liveProbe(LiveProbeEvent)
        case resourceSpike(SystemResourceMonitor.Sample)
    }

    var iconName: String {
        switch kind {
        case .newDestination:    return "globe.badge.chevron.backward"
        case .newAnomaly(let a):
            switch a.kind {
            case .periodicBeacon: return "waveform.path"
            case .burst:          return "bolt.fill"
            case .undeclaredHost: return "globe.badge.chevron.backward"
            }
        case .surprisingFile:    return "doc.badge.ellipsis"
        case .surprisingNetwork: return "network.badge.shield.half.filled"
        case .liveProbe(let p):  return p.kind.icon
        case .resourceSpike:     return "speedometer"
        }
    }

    var title: String {
        switch kind {
        case .newDestination(let host, _, let proc):
            return "New destination: \(host) (via \(proc))"
        case .newAnomaly(let a):
            return a.title
        case .surprisingFile(let f):
            return "Surprising file event: \((f.path as NSString).lastPathComponent)"
        case .surprisingNetwork(let n):
            return "Surprising connection: \(n.remoteHostname ?? n.remoteEndpoint.address)"
        case .liveProbe(let p):
            return p.kind.rawValue
        case .resourceSpike(let s):
            return String(format: "CPU spike — %.0f%% across %d PID%@",
                          s.cpuPercent, s.pidCount, s.pidCount == 1 ? "" : "s")
        }
    }

    var subtitle: String? {
        switch kind {
        case .newDestination(_, let pid, _):
            return "PID \(pid)"
        case .newAnomaly(let a):
            return a.summary
        case .surprisingFile(let f):
            return f.path
        case .surprisingNetwork(let n):
            return "Process \(n.processName) (PID \(n.pid)) → \(n.remoteEndpoint.address):\(n.remoteEndpoint.port)"
        case .liveProbe(let p):
            if p.pid > 0 {
                return "\(p.processName) [\(p.pid)]"
                    + (p.detail.map { " · \($0)" } ?? "")
            }
            return p.detail
        case .resourceSpike(let s):
            let mb = Double(s.residentBytes) / 1_048_576.0
            return String(format: "%.0f MB resident, +%.0f MB disk read, +%.0f MB disk written in last second",
                          mb,
                          Double(s.diskReadBytesDelta) / 1_048_576.0,
                          Double(s.diskWriteBytesDelta) / 1_048_576.0)
        }
    }
}
