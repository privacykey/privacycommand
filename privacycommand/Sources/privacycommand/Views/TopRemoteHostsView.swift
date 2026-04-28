import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Top remote hosts — recomputed on a configurable timer over a
/// configurable lookback window. Settings persist via @AppStorage so
/// the user's chosen window survives across launches.
///
/// Two knobs:
///   * **Window** — "all", "30s", "60s", "5min". Limits the events that
///     contribute to the ranking. Useful in long watch-mode runs where
///     the top-of-all-time host stops being interesting.
///   * **Refresh** — how often the timer fires. Lower values feel
///     snappier; higher values reduce visual flicker.
struct TopRemoteHostsView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @AppStorage("topHostsWindowSeconds") private var windowSeconds: Int = 0
    @AppStorage("topHostsRefreshSeconds") private var refreshSeconds: Int = 5

    /// Timer-driven re-render trigger. We don't actually use the value
    /// — its mere existence as a `@State` that mutates on each tick
    /// causes SwiftUI to recompute the body.
    @State private var lastRefresh: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Top remote hosts").font(.subheadline.bold())
                Spacer()
                windowPicker
                refreshPicker
            }
            if hosts.isEmpty {
                Text("No connections in the selected window.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(hosts.prefix(8), id: \.host) { h in
                    row(h)
                }
            }
            Text("Last refreshed \(timeAgo(lastRefresh))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .onReceive(Timer.publish(every: TimeInterval(max(refreshSeconds, 1)),
                                 on: .main, in: .common).autoconnect()) { _ in
            lastRefresh = Date()
        }
    }

    // MARK: - Pickers

    private var windowPicker: some View {
        Picker("Window", selection: $windowSeconds) {
            Text("All").tag(0)
            Text("30 s").tag(30)
            Text("60 s").tag(60)
            Text("5 min").tag(300)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 76)
        .help("Limit the ranking to network events within the last N seconds.")
    }

    private var refreshPicker: some View {
        Picker("Refresh", selection: $refreshSeconds) {
            Text("1 s").tag(1)
            Text("5 s").tag(5)
            Text("15 s").tag(15)
            Text("60 s").tag(60)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 70)
        .help("How often the ranking is recomputed.")
    }

    private func row(_ h: HostFrequency) -> some View {
        HStack {
            Image(systemName: "network").foregroundStyle(.secondary)
            Text(h.host).lineLimit(1).truncationMode(.middle)
            DomainCategoryBadge(host: h.host)
            Spacer()
            Text("\(h.connectionCount) conn\(h.connectionCount == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Aggregation

    /// Network events filtered to the configured window, then aggregated
    /// into HostFrequency entries (mirrors what RunSummary does, but
    /// for an arbitrary lookback rather than the whole run).
    private var hosts: [HostFrequency] {
        // `lastRefresh` is read here so the timer-driven mutation
        // forces SwiftUI to recompute this property on each tick.
        _ = lastRefresh
        let now = Date()
        let cutoff: Date? = windowSeconds > 0
            ? now.addingTimeInterval(-Double(windowSeconds))
            : nil
        let networkEvents: [NetworkEvent] = coordinator.events.compactMap {
            if case .network(let n) = $0 { return n } else { return nil }
        }
        let filtered = cutoff.map { c in networkEvents.filter { $0.lastSeen >= c } }
            ?? networkEvents
        let grouped = Dictionary(grouping: filtered,
                                 by: { $0.remoteHostname ?? $0.remoteEndpoint.address })
        let aggregated = grouped.map { (host, evs) in
            HostFrequency(host: host,
                          bytesSent: evs.reduce(0) { $0 + $1.bytesSent },
                          bytesReceived: evs.reduce(0) { $0 + $1.bytesReceived },
                          connectionCount: evs.count)
        }
        return aggregated.sorted { $0.connectionCount > $1.connectionCount }
    }

    private func timeAgo(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 1 { return "just now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        return "\(elapsed / 60)m \(elapsed % 60)s ago"
    }
}
