import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Sloth-style snapshot of "what is this app holding open right now?".
/// Refreshes every poll cycle of `ResourceMonitor`. Filterable by Kind,
/// process, and a free-text search over the NAME column.
struct ResourcesView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @EnvironmentObject var helperInstaller: HelperInstaller

    @State private var search: String = ""
    @State private var processFilter: String = ""
    @State private var enabledKinds: Set<OpenResource.Kind> = Set(OpenResource.Kind.allCases)
    @State private var showingKindGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Open resources").font(.title3.bold())
                FidelityBadge(.bestEffort,
                              detail: "Snapshot from `lsof -p` at ~1 Hz. Short-lived FDs may be missed between polls.")
                Spacer()
                Button {
                    showingKindGuide = true
                } label: {
                    Label("What do these mean?", systemImage: "questionmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                if coordinator.isMonitoring {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("live").foregroundStyle(.green).font(.caption)
                    }
                } else {
                    Text("snapshot frozen").foregroundStyle(.secondary).font(.caption)
                }
            }

            kindChips
            HStack {
                TextField("Process", text: $processFilter).frame(width: 160)
                TextField("Path / name", text: $search).frame(maxWidth: .infinity)
                Spacer()
                Text("\(filtered.count) of \(coordinator.openResources.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if coordinator.openResources.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchesState
            } else {
                Table(filtered) {
                    // Tight defaults so Name/path gets the bulk of the
                    // space. The user can still drag dividers to override
                    // these — Table column customization persistence
                    // requires macOS 14+, which we don't currently target.
                    TableColumn("Kind") { r in
                        HStack(spacing: 4) {
                            Image(systemName: r.kind.systemImage).foregroundStyle(.secondary)
                            Text(r.kind.label).font(.caption)
                            InfoButton(articleID: r.kind.kbArticleID)
                        }
                    }
                    .width(min: 110, ideal: 130, max: 170)

                    TableColumn("Process") { r in
                        Text("\(r.processName) [\(r.pid)]")
                            .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 130, ideal: 160, max: 240)

                    TableColumn("FD") { r in
                        HStack(spacing: 3) {
                            Text(r.fd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            InfoButton(articleID: "resource-fd")
                        }
                    }
                    .width(min: 50, ideal: 60, max: 90)

                    // No max — Name/path takes whatever's left over.
                    TableColumn("Name / path") { r in
                        Text(r.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(r.name)   // hover to see full path
                    }
                    .width(min: 240, ideal: 420)

                    TableColumn("Node") { r in
                        Text(r.node ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 100, max: 160)
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showingKindGuide) {
            ResourceKindGuide(onClose: { showingKindGuide = false })
        }
    }

    // MARK: - Subviews

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    enabledKinds = Set(OpenResource.Kind.allCases)
                } label: {
                    Text("All").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)

                Button {
                    enabledKinds = []
                } label: {
                    Text("None").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 14)

                ForEach(OpenResource.Kind.allCases, id: \.self) { kind in
                    chip(kind)
                }
            }
        }
    }

    private func chip(_ kind: OpenResource.Kind) -> some View {
        let on = enabledKinds.contains(kind)
        let count = coordinator.openResources.filter { $0.kind == kind }.count
        let tooltip = KnowledgeBase.article(id: kind.kbArticleID)?.summary ?? kind.label
        return Button {
            if on { enabledKinds.remove(kind) } else { enabledKinds.insert(kind) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: kind.systemImage).imageScale(.small)
                Text(kind.label)
                Text("\(count)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .font(.caption.weight(on ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                        in: .capsule)
            .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .opacity(count == 0 ? 0.5 : 1)
        .help(tooltip)
        .contextMenu {
            Button("What is \(kind.label)?") {
                showingKindGuide = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
            Text(coordinator.isMonitoring
                 ? "Waiting for the first lsof poll…"
                 : "No open resources captured.")
                .font(.headline)
            Text("Start a monitored run from the toolbar to see what files, sockets, pipes, and devices the app is holding open.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    private var noMatchesState: some View {
        VStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
            Text("No matches with current filters.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Filter

    private var filtered: [OpenResource] {
        coordinator.openResources.filter { r in
            enabledKinds.contains(r.kind) &&
            (processFilter.isEmpty || r.processName.localizedCaseInsensitiveContains(processFilter)) &&
            (search.isEmpty || r.name.localizedCaseInsensitiveContains(search))
        }
    }
}
