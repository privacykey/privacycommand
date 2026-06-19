import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct NetworkView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var hostFilter: String = ""
    @State private var highlightedIDs: Set<NetworkEvent.ID> = []
    @State private var showOnlyHighlighted = false

    /// External services a remote IP can be looked up against. Opened in the
    /// user's default browser — we never phone home ourselves.
    private static let ipLookups: [(label: String, systemImage: String, prefix: String)] = [
        ("Look up on ipinfo.io", "globe", "https://ipinfo.io/"),
        ("Reputation on AbuseIPDB", "shield.lefthalf.filled", "https://www.abuseipdb.com/check/"),
        ("Open ports on Shodan", "magnifyingglass", "https://www.shodan.io/host/"),
        ("WHOIS record", "doc.text.magnifyingglass", "https://www.whois.com/whois/")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Network destinations").font(.title3.bold())
                FidelityBadge(.bestEffort,
                              detail: "Polled from lsof every 500 ms. Short-lived UDP queries can be missed. TLS payloads are never decrypted.")
                Spacer()
                if !highlightedIDs.isEmpty {
                    Toggle(isOn: $showOnlyHighlighted) {
                        Label("Highlighted only (\(highlightedIDs.count))", systemImage: "star.fill")
                    }
                    .toggleStyle(.button)
                    .help("Show only rows you have highlighted")
                    Button {
                        highlightedIDs.removeAll()
                        showOnlyHighlighted = false
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .help("Remove all highlights")
                }
                TextField("Host or IP", text: $hostFilter).frame(width: 220)
            }
            if filtered.isEmpty {
                emptyState
            } else {
                Table(filtered) {
                    TableColumn("") { e in highlightButton(for: e) }
                        .width(28)
                    TableColumn("Host") { e in
                        HStack(spacing: 4) {
                            Text(e.remoteHostname ?? e.remoteEndpoint.address)
                                .fontWeight(highlightedIDs.contains(e.id) ? .semibold : .regular)
                            DomainCategoryBadge(host: e.remoteHostname ?? e.remoteEndpoint.address, compact: true)
                        }
                    }
                    TableColumn("Type") { e in
                        DomainCategoryBadge(host: e.remoteHostname ?? e.remoteEndpoint.address)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("IP") { e in ipMenu(for: e) }
                        .width(min: 130, ideal: 160)
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

    // MARK: - Row controls

    /// The IP cell doubles as a menu: clicking it offers external lookups,
    /// a copy action, and a highlight toggle for the row.
    @ViewBuilder
    private func ipMenu(for e: NetworkEvent) -> some View {
        let ip = e.remoteEndpoint.address
        let highlighted = highlightedIDs.contains(e.id)
        Menu {
            if Self.isRoutable(ip) {
                ForEach(Self.ipLookups, id: \.label) { item in
                    Button { open(item.prefix + ip) } label: {
                        Label(item.label, systemImage: item.systemImage)
                    }
                }
            } else {
                Text("Private / local address — no public lookup")
            }
            Divider()
            Button { copyToClipboard(ip) } label: {
                Label("Copy IP", systemImage: "doc.on.doc")
            }
            Divider()
            Button { toggleHighlight(e.id) } label: {
                Label(highlighted ? "Remove highlight" : "Highlight row",
                      systemImage: highlighted ? "star.slash" : "star")
            }
        } label: {
            Text(ip).font(.callout.monospaced())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func highlightButton(for e: NetworkEvent) -> some View {
        let highlighted = highlightedIDs.contains(e.id)
        return Button { toggleHighlight(e.id) } label: {
            Image(systemName: highlighted ? "star.fill" : "star")
                .foregroundStyle(highlighted ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(highlighted ? "Remove highlight" : "Highlight this row")
    }

    // MARK: - Actions

    private func toggleHighlight(_ id: NetworkEvent.ID) {
        if highlightedIDs.contains(id) {
            highlightedIDs.remove(id)
        } else {
            highlightedIDs.insert(id)
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Data

    private var networkEvents: [NetworkEvent] {
        coordinator.events.compactMap { if case .network(let n) = $0 { return n } else { return nil } }
    }

    private var filtered: [NetworkEvent] {
        networkEvents.filter { e in
            let matchesText = hostFilter.isEmpty
                || (e.remoteHostname ?? "").localizedCaseInsensitiveContains(hostFilter)
                || e.remoteEndpoint.address.localizedCaseInsensitiveContains(hostFilter)
            // Ignore the highlight filter when nothing is highlighted so the
            // toggle can't strand the user on an empty table.
            let matchesHighlight = !showOnlyHighlighted
                || highlightedIDs.isEmpty
                || highlightedIDs.contains(e.id)
            return matchesText && matchesHighlight
        }
    }

    /// True when the address can be meaningfully looked up against a public
    /// service (i.e. it is not loopback, link-local, private, or multicast).
    private static func isRoutable(_ ip: String) -> Bool {
        if ip.contains(":") {
            let lower = ip.lowercased()
            if lower == "::1" || lower == "::" { return false }
            if lower.hasPrefix("fe80") { return false }   // link-local
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return false } // unique-local
            if lower.hasPrefix("ff") { return false }     // multicast
            return true
        }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10, 127: return false                                   // private / loopback
        case 169 where octets[1] == 254: return false                // link-local
        case 172 where (16...31).contains(octets[1]): return false   // private
        case 192 where octets[1] == 168: return false                // private
        case 100 where (64...127).contains(octets[1]): return false  // carrier-grade NAT
        case 0, 224...255: return false                              // unspecified / multicast / reserved
        default: return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network").font(.largeTitle).foregroundStyle(.secondary)
            if networkEvents.isEmpty {
                Text("No network connections observed yet")
                    .font(.headline)
                Text("Start a monitored run from the toolbar to begin polling for outbound connections.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No connections match the current filter")
                    .font(.headline)
                Text("Adjust the search field or clear the highlighted-only filter.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
