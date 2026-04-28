import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct ContentView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var selectedTab: Tab = .summary

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case staticAnalysis = "Static"
        case fileAccess = "Files"
        case network = "Network"
        case resources = "Resources"
        case probes = "Probes"
        case timeline = "Timeline"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if coordinator.bundle == nil {
                DropTargetView()
            } else {
                main
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Modal sheet covers the whole window while a static-analysis
        // pass is running. Constant `true` projection of `isAnalyzing`
        // is fine — the underlying @Published flag flips back when the
        // detached task finishes, dismissing the sheet automatically.
        .sheet(isPresented: $coordinator.isAnalyzing) {
            AnalyzingSheet(bundleURL: coordinator.analyzingURL)
                .interactiveDismissDisabled(true)
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tabItem { Label("Summary", systemImage: "rectangle.dashed") }
                    .tag(Tab.summary)
                StaticAnalysisView()
                    .tabItem { Label("Static", systemImage: "doc.text.magnifyingglass") }
                    .tag(Tab.staticAnalysis)
                FileAccessView()
                    .tabItem { Label("Files", systemImage: "folder.badge.questionmark") }
                    .tag(Tab.fileAccess)
                NetworkView()
                    .tabItem { Label("Network", systemImage: "network") }
                    .tag(Tab.network)
                ResourcesView()
                    .tabItem { Label("Resources", systemImage: "list.bullet.indent") }
                    .tag(Tab.resources)
                LiveProbesView()
                    .tabItem { Label("Probes", systemImage: "waveform.badge.exclamationmark") }
                    .tag(Tab.probes)
                TimelineView()
                    .tabItem { Label("Timeline", systemImage: "list.bullet.rectangle") }
                    .tag(Tab.timeline)
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                    .tag(Tab.history)
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @EnvironmentObject var watchManager: WatchModeManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                bundleIdentity
                Spacer()
                statusBadges
                Divider().frame(height: 22)
                runControls
                secondaryActions
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if let err = coordinator.lastError {
                errorStrip(err)
            }
        }
    }

    // MARK: - Sections

    private var bundleIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(coordinator.bundle?.bundleName ?? "—")
                .font(.title2).bold()
                .lineLimit(1).truncationMode(.tail)
            Text(coordinator.bundle?.bundleID ?? "")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder
    private var statusBadges: some View {
        if let score = coordinator.riskScore {
            RiskTierBadge(score: score)
        }
        if let report = coordinator.staticReport {
            Label(report.codeSigning.teamIdentifier ?? "no team",
                  systemImage: "checkmark.seal")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(report.codeSigning.teamIdentifier != nil
                                 ? Color.primary : .orange)
        }
    }

    /// Run primary controls: Start / Stop, with Pause inline while
    /// running. Always rendered as text+icon since these are the
    /// most-used actions.
    @ViewBuilder
    private var runControls: some View {
        if coordinator.isMonitoring {
            Button {
                Task { await coordinator.toggleKillSwitch() }
            } label: {
                if coordinator.isPaused {
                    Label("Resume", systemImage: "play.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            .help(coordinator.isPaused
                  ? "App is frozen. SIGCONT will resume it."
                  : "Freeze the inspected app's process tree (SIGSTOP). The app can't network, write files, or run code while paused.")
            // Network-only kill switch. Requires the privileged helper.
            // Different from Pause: the app keeps running so you can
            // observe its failure-handling behaviour.
            Button {
                Task { await coordinator.toggleNetworkKillSwitch() }
            } label: {
                if coordinator.isNetworkBlocked {
                    Label("Network blocked", systemImage: "wifi.slash")
                        .foregroundStyle(.red)
                } else {
                    Label("Block network", systemImage: "wifi.exclamationmark")
                }
            }
            .help(coordinator.isNetworkBlocked
                  ? "pf anchor is active — the app's known destinations are blackholed. Click to lift."
                  : "Block outbound traffic to the IPs the app has contacted so far. The process keeps running so you can see how it handles network failures. Requires the privileged helper.")
            Button(role: .destructive) {
                Task {
                    watchManager.stop()
                    await coordinator.stopMonitoredRun()
                }
            } label: { Label("Stop run", systemImage: "stop.fill") }
            .keyboardShortcut(".")
        } else {
            Button {
                Task { await coordinator.startMonitoredRun() }
            } label: { Label("Start run", systemImage: "play.fill") }
            .disabled(!coordinator.canStartRun)
            .keyboardShortcut("r")
        }
    }

    /// Secondary actions — Watch + Open. Icon-only to keep the header
    /// compact; tooltips carry the meaning.
    @ViewBuilder
    private var secondaryActions: some View {
        // Watch toggle — text label when active so the user knows
        // they're in watch mode without checking the menu bar.
        if watchManager.isWatching {
            Button {
                watchManager.stop()
                Task { await coordinator.stopMonitoredRun() }
            } label: {
                Label("Watching…", systemImage: "eye.fill")
                    .foregroundStyle(.blue)
            }
            .help("Click to stop watch mode.")
        } else {
            Button {
                Task {
                    if !coordinator.isMonitoring {
                        await coordinator.startMonitoredRun()
                    }
                    watchManager.start(coordinator: coordinator)
                }
            } label: {
                Image(systemName: "eye")
            }
            .help("Watch — keep this run alive in the menu bar and notify on changes (⇧⌘W).")
            .disabled(!coordinator.canStartRun && !coordinator.isMonitoring)
        }

        // Eject — only visible when the inspected app came from a DMG.
        // Sits next to Open so the icons stay grouped.
        if let mount = coordinator.mountedDMG {
            Button {
                Task { await coordinator.ejectMountedDMG() }
            } label: {
                Image(systemName: "eject.fill")
                    .foregroundStyle(.blue)
            }
            .help("Eject \(mount.dmgURL.lastPathComponent). The static report stays readable but starting a monitored run will fail because the executable file goes away.")
        }

        Button { coordinator.presentOpenPanel() } label: {
            Image(systemName: "doc.viewfinder")
        }
        .help("Open another .app bundle or .dmg (⌘O).")
        .keyboardShortcut("o")
    }

    /// Inline error strip below the header. Auto-clears when the user
    /// taps the X. Less obtrusive than a modal alert and matches what
    /// other macOS pro tools do.
    private func errorStrip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2).truncationMode(.tail)
            Spacer()
            Button {
                coordinator.lastError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}
