import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct NetworkView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var hostFilter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Network destinations").font(.title3.bold())
                FidelityBadge(.bestEffort,
                              detail: "Polled from lsof every 500 ms. Short-lived UDP queries can be missed. TLS payloads are never decrypted.")
                Spacer()
                TextField("Host or IP", text: $hostFilter).frame(width: 220)
            }
            if filtered.isEmpty {
                emptyState
            } else {
                Table(filtered) {
                    TableColumn("Host") { e in
                        HStack(spacing: 4) {
                            Text(e.remoteHostname ?? e.remoteEndpoint.address)
                            DomainCategoryBadge(host: e.remoteHostname ?? e.remoteEndpoint.address, compact: true)
                        }
                    }
                    TableColumn("Type") { e in
                        DomainCategoryBadge(host: e.remoteHostname ?? e.remoteEndpoint.address)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("IP") { e in Text(e.remoteEndpoint.address).font(.callout.monospaced()) }
                    TableColumn("Port") { e in Text(String(e.remoteEndpoint.port)).font(.callout.monospaced()) }
                    TableColumn("Proto") { e in Text(e.netProto.rawValue.uppercased()) }
                    TableColumn("Process") { e in Text("\(e.processName) [\(e.pid)]") }
                    TableColumn("Bytes Tx/Rx") { e in Text("\(e.bytesSent) / \(e.bytesReceived)") }
                    TableColumn("First seen") { e in Text(e.firstSeen.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }
                    TableColumn("Last seen") { e in Text(e.lastSeen.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()) }
                }
            }
        }
        .padding(20)
    }

    private var networkEvents: [NetworkEvent] {
        coordinator.events.compactMap { if case .network(let n) = $0 { return n } else { return nil } }
    }

    private var filtered: [NetworkEvent] {
        networkEvents.filter { e in
            hostFilter.isEmpty
            || (e.remoteHostname ?? "").localizedCaseInsensitiveContains(hostFilter)
            || e.remoteEndpoint.address.contains(hostFilter)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
            Text("No network connections observed yet")
                .font(.headline)
            Text("Start a monitored run from the toolbar to begin polling for outbound connections.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
