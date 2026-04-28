import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct FileAccessView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @EnvironmentObject var helperInstaller: HelperInstaller
    @State private var processFilter: String = ""
    @State private var pathFilter: String = ""
    @State private var showOnlySurprising = false
    @State private var showOnlyOutsideScope = false
    @State private var showingCategoryGuide = false
    private let pathClassifier = PathClassifier()

    private var helperReady: Bool { helperInstaller.status == .installed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("File events").font(.title3.bold())
                if helperReady {
                    FidelityBadge(.bestEffort,
                                  detail: "Captured by the privileged helper running fs_usage(1). fs_usage may drop events under heavy I/O load.")
                } else {
                    FidelityBadge(.requiresEntitlement,
                                  detail: "Install the privileged helper from the Help menu to enable file monitoring.")
                }
                Spacer()
                Button {
                    showingCategoryGuide = true
                } label: {
                    Label("What do these categories mean?", systemImage: "questionmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Toggle("Surprising only", isOn: $showOnlySurprising)
                Toggle("Out of scope", isOn: $showOnlyOutsideScope)
                    .help("Show only events touching paths outside the inspected app's normal scope (other apps' containers, other users' homes, sensitive dotfiles like ~/.ssh).")
                TextField("Process", text: $processFilter).frame(width: 160)
                TextField("Path", text: $pathFilter).frame(width: 200)
            }
            if filteredEvents.isEmpty {
                emptyState
            } else {
                Table(filteredEvents) {
                    TableColumn("Time") { e in Text(e.timestamp.ISO8601Format()).font(.caption.monospaced()) }
                    TableColumn("Process") { e in Text("\(e.processName) [\(e.pid)]") }
                    TableColumn("Op") { e in Text(e.op.rawValue) }
                    TableColumn("Path") { e in
                        // Out-of-scope paths render in orange so they
                        // jump out of the scrolling list. The Scope
                        // column also tags them explicitly.
                        Text(e.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(isOutsideScope(e) ? Color.orange : Color.primary)
                            .help(e.path)
                    }
                    TableColumn("Category") { e in Text(e.category.rawValue) }
                    TableColumn("Scope") { e in
                        if isOutsideScope(e) {
                            Label("Outside", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("—").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 70, ideal: 90, max: 110)
                    TableColumn("Risk") { e in
                        Text(e.risk.rawValue)
                            .foregroundStyle(e.risk == .surprising ? .red : e.risk == .sensitive ? .orange : .primary)
                    }
                    TableColumn("Rule") { e in Text(e.ruleID ?? "—").font(.caption.monospaced()) }
                }
            }
        }
        .padding(20)
        .sheet(isPresented: $showingCategoryGuide) {
            pathCategoryGuideSheet
        }
    }

    private var pathCategoryGuideSheet: some View {
        PathCategoryGuide(onClose: { showingCategoryGuide = false })
    }

    private var fileEvents: [FileEvent] {
        coordinator.events.compactMap { if case .file(let f) = $0 { return f } else { return nil } }
    }

    private var filteredEvents: [FileEvent] {
        fileEvents.filter { e in
            (processFilter.isEmpty || e.processName.localizedCaseInsensitiveContains(processFilter))
            && (pathFilter.isEmpty || e.path.localizedCaseInsensitiveContains(pathFilter))
            && (!showOnlySurprising || e.risk == .surprising)
            && (!showOnlyOutsideScope || isOutsideScope(e))
        }
    }

    /// Cheap per-event scope check. Doesn't memoize — paths are
    /// short-string compares so the cost is marginal even on long
    /// runs. The classifier's `isOutsideScope` returns `false` if no
    /// bundle context is provided, so we get a graceful empty-state
    /// before the user has selected a bundle.
    private func isOutsideScope(_ e: FileEvent) -> Bool {
        pathClassifier.isOutsideScope(
            path: e.path,
            ownerBundleURL: coordinator.bundle?.url,
            bundleID: coordinator.bundle?.bundleID)
    }

    @ViewBuilder
    private var emptyState: some View {
        if helperReady {
            VStack(spacing: 8) {
                Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                Text(coordinator.isMonitoring
                     ? "Waiting for the target to touch the file system…"
                     : "No file events captured yet")
                    .font(.headline)
                Text("The helper is installed and ready. File events will appear here as the monitored process reads or writes files.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "lock").font(.largeTitle).foregroundStyle(.blue)
                Text("File events not available in this build")
                    .font(.headline)
                Text("Install the privileged helper from **Help → Show Onboarding…** to enable best-effort fs_usage-based file events. Production-quality file monitoring requires Endpoint Security, which needs an Apple-granted entitlement.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}
