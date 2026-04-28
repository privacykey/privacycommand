import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

// MARK: - Reusable list

/// One row per saved run. Click to load it; right-click for delete / reveal.
struct RecentRunsList: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    var maxRows: Int? = nil

    var body: some View {
        let rows = (maxRows.map { Array(coordinator.recentRuns.prefix($0)) }) ?? coordinator.recentRuns

        if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                Text("No saved runs yet").foregroundStyle(.secondary).font(.callout)
                Text("Drop an .app to analyze it — saved automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { meta in
                    RecentRow(meta: meta)
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(meta) }
                            Button("Delete", role: .destructive) {
                                coordinator.deleteRun(id: meta.id)
                            }
                        }
                        .onTapGesture { coordinator.loadFromStore(id: meta.id) }
                    Divider()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        }
    }

    private func reveal(_ meta: RunReportMeta) {
        let dir = RunStore.shared.directory(for: meta.id)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

// MARK: - One row

private struct RecentRow: View {
    let meta: RunReportMeta
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meta.displayName).font(.headline)
                    if let v = meta.bundle.bundleVersion {
                        Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let id = meta.bundle.bundleID {
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Risk badge — compact form
            RiskTierBadge(score: meta.summary.riskScore)

            // Counts
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(meta.summary.networkEventCount) net · \(meta.summary.fileEventCount) file")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(relative(meta.endedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered ? Color.accentColor.opacity(0.06) : .clear)
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Full-tab history view

struct HistoryView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var showingCompare = false
    @State private var query: String = ""
    @State private var results: [RunSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Run history").font(.title3.bold())
                Text("\(coordinator.recentRuns.count) saved")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()

                searchField
                    .frame(maxWidth: 280)

                Button {
                    showingCompare = true
                } label: {
                    Label("Compare two runs", systemImage: "rectangle.lefthalf.inset.filled.arrow.left")
                }
                .disabled(coordinator.recentRuns.count < 2)
                Button("Refresh") { coordinator.refreshRecents() }
                    .buttonStyle(.borderless)
            }

            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    RecentRunsList()
                        .frame(maxWidth: .infinity)
                } else {
                    searchResultsView
                }
            }
        }
        .padding(20)
        .task { coordinator.refreshRecents() }
        .sheet(isPresented: $showingCompare) {
            CompareView(onClose: { showingCompare = false })
                .environmentObject(coordinator)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search across all runs", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
                .onChange(of: query) { _ in runSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsView: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: isSearching ? "hourglass" : "magnifyingglass")
                    .font(.title2).foregroundStyle(.secondary)
                Text(isSearching ? "Searching…" : "No matches.")
                    .foregroundStyle(.secondary)
                if !isSearching {
                    Text("Searches bundle info, privacy keys, findings, hard-coded domains and paths, and observed network and file events.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(totalHits) hit\(totalHits == 1 ? "" : "s") across \(results.count) run\(results.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(results) { result in
                    SearchResultGroup(result: result, query: query)
                        .environmentObject(coordinator)
                }
            }
        }
    }

    private var totalHits: Int { results.reduce(0) { $0 + $1.hitCount } }

    // MARK: - Search lifecycle

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let runs = coordinator.recentRuns
        searchTask = Task {
            // Debounce so per-keystroke search doesn't thrash the disk.
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            let r = await RunSearcher().search(query: q, in: runs)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = r
                self.isSearching = false
            }
        }
    }
}

// MARK: - One group of hits per matching run

private struct SearchResultGroup: View {
    let result: RunSearchResult
    let query: String
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(result.meta.displayName).font(.headline)
                        if let v = result.meta.bundle.bundleVersion {
                            Text("v\(v)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("· \(result.hitCount) hit\(result.hitCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let id = result.meta.bundle.bundleID {
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RiskTierBadge(score: result.meta.summary.riskScore)
                Button("Open") { coordinator.loadFromStore(id: result.meta.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(12)

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.hits.prefix(10))) { hit in
                        hitRow(hit)
                    }
                    if result.hits.count > 10 {
                        Text("…and \(result.hits.count - 10) more in this run")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 32)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }

    private func hitRow(_ hit: RunSearchHit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: hit.category.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(hit.category.label)
                .font(.caption.bold()).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            highlightedText(hit.detail, query: query)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if let ctx = hit.context {
                Text(ctx).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// Bolds the matching substring to make hits scannable.
    private func highlightedText(_ text: String, query: String) -> Text {
        guard !query.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive])
        else {
            return Text(text).font(.callout)
        }
        let before = text[..<range.lowerBound]
        let match  = text[range]
        let after  = text[range.upperBound...]
        return Text(before).font(.callout)
             + Text(match).font(.callout.bold()).foregroundColor(.accentColor)
             + Text(after).font(.callout)
    }
}
