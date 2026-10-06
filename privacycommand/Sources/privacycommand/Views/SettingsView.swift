import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// The Settings panes, in tab order: General, Helper, VM agent, Updates.
/// `SurfaceSettings` wraps each one in a grouped form and adds the About
/// button to General itself.
@MainActor
enum PrivacycommandSettings {
    static func panes(
        app: SurfaceApp,
        menuBar: SurfaceMenuBarPreference,
        watchManager: WatchModeManager,
        updates: SurfaceUpdates,
        updateController: UpdateController
    ) -> [SurfacePane] {
        [
            SurfacePane("General", systemImage: "gearshape") {
                GeneralPane(app: app, menuBar: menuBar, watchManager: watchManager)
            },
            SurfacePane("Helper", systemImage: "shield.lefthalf.filled") {
                HelperPane()
            },
            SurfacePane("VM agent", systemImage: "macwindow.on.rectangle") {
                GuestAgentSettingsView()
            },
            updatesPane(updates: updates, controller: updateController),
        ]
    }

    /// The standard Updates pane. A copy installed through Homebrew Cask
    /// gets a section above it pointing at `brew upgrade`, which stays in
    /// charge of the on-disk bundle.
    private static func updatesPane(updates: SurfaceUpdates, controller: UpdateController) -> SurfacePane {
        guard controller.homebrew.isHomebrewInstall else { return .updates(updates) }
        return SurfacePane("Updates", systemImage: "arrow.down.circle") {
            HomebrewSection(cask: controller.homebrew.caskName)
            SurfaceUpdateSections(updates: updates)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    let app: SurfaceApp
    @ObservedObject var menuBar: SurfaceMenuBarPreference
    @ObservedObject var watchManager: WatchModeManager
    @AppStorage("autoSaveRuns") private var autoSaveRuns = true
    @EnvironmentObject private var coordinator: AnalysisCoordinator
    @State private var cachedCount = 0
    @State private var cachedSizeBytes: Int64 = 0

    var body: some View {
        Section("Run history") {
            Toggle(isOn: $autoSaveRuns) {
                SurfaceInfoLabel("Save runs to history automatically",
                                 info: "Every analysis and monitored run is written to ~/Library/Application Support/privacycommand/runs and listed in the History tab. When this is off, a run is only kept when you save a report from the File menu.")
            }
            LabeledContent("Saved runs") {
                HStack(spacing: 8) {
                    Text("\(coordinator.recentRuns.count)").monospacedDigit()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([RunStore.shared.baseURL])
                    }
                    SurfaceDestructiveButton(
                        "Delete All Runs…", gate: .typed("DELETE"),
                        question: "Delete all saved runs?",
                        consequence: "This removes the saved report for every run, \(coordinator.recentRuns.count) in total. It cannot be undone.",
                        confirmTitle: "Delete Runs"
                    ) {
                        for meta in coordinator.recentRuns {
                            coordinator.deleteRun(id: meta.id)
                        }
                    }
                    .disabled(coordinator.recentRuns.isEmpty)
                }
            }
        }
        .task {
            coordinator.refreshRecents()
            await refreshCacheStats()
        }
        Section("Analysis cache") {
            LabeledContent {
                HStack(spacing: 8) {
                    Text("\(cachedCount)").monospacedDigit()
                    if cachedCount > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text(cacheSizeLabel).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([StaticReportCache.shared.baseURL])
                    }
                    SurfaceDestructiveButton(
                        "Clear Cache…", gate: .confirm,
                        question: "Clear the analysis cache?",
                        consequence: "The cached static report for every app is removed. Nothing else is lost: an app is simply analysed again the next time you open it.",
                        confirmTitle: "Clear Cache"
                    ) {
                        StaticReportCache.shared.clear()
                        cachedCount = 0
                        cachedSizeBytes = 0
                    }
                    .disabled(cachedCount == 0)
                }
            } label: {
                SurfaceInfoLabel("Cached analyses",
                                 info: "Opening an app you have already analysed reuses its cached static report instead of analysing it again. Safe to clear at any time.")
            }
        }
        SurfaceMenuBarSection(app: app, preference: menuBar, icons: WatchModeIconStyle.allCases.map { style in
            SurfaceMenuBarIcon(id: style.rawValue, title: style.displayName, image: Image(systemName: style.idleSymbol))
        }) {
            LabeledContent {
                Text(watchManager.isWatching
                     ? "Watching \(watchManager.watchedBundleName)"
                     : "Appears while you watch an app")
                    .foregroundStyle(.secondary)
            } label: {
                SurfaceInfoLabel("Status",
                                 info: "The menu bar item is shown while a watched run is active (Run ▸ Start Watching…) and disappears when the run stops. The icon fills in while there are unread changes.")
            }
        }
    }

    private var cacheSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: cachedSizeBytes, countStyle: .file)
    }

    private func refreshCacheStats() async {
        let stats = await Task.detached {
            (count: StaticReportCache.shared.count, size: StaticReportCache.shared.sizeBytes)
        }.value
        cachedCount = stats.count
        cachedSizeBytes = stats.size
    }
}

// MARK: - Helper

private struct HelperPane: View {
    @EnvironmentObject private var helperInstaller: HelperInstaller

    private static let howItWorks = "The helper runs as a root daemon under launchd. It accepts XPC connections only from this app, signed by the same Team ID. It runs fs_usage to observe a target process's file activity and streams the parsed events back to the app, stops when the run ends and unloads after a few seconds idle. It also reads Background Task Management and installs the network kill switch's pf rules."

    var body: some View {
        Section("Privileged helper") {
            LabeledContent {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon).foregroundStyle(statusColor)
                    Text(statusTitle).foregroundStyle(statusColor)
                }
            } label: {
                SurfaceInfoLabel("Status", info: Self.howItWorks)
            }
            if let version = helperInstaller.helperVersion {
                LabeledContent("Reported version") {
                    Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            actionRow
        }
        .onAppear { helperInstaller.refresh() }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch helperInstaller.status {
        case .notFound:
            // Surface the path we tried so the user can verify whether
            // the .app actually has the plist where we expect it. If this
            // points at a file that exists, the lookup itself is broken;
            // if it points at a missing file, the build's Copy Files
            // phase didn't run.
            let plistURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons")
                .appendingPathComponent(HelperToolID.daemonPlistName)
            LabeledContent("Bundled helper") {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Reveal App Contents in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            Bundle.main.bundleURL.appendingPathComponent("Contents")
                        ])
                    }
                    Text("Not found at \(plistURL.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .notRegistered, .unknown:
            LabeledContent("Install") {
                Button("Install Helper") { helperInstaller.install() }
                    .buttonStyle(.borderedProminent)
            }
        case .requiresApproval:
            LabeledContent("Approve") {
                Button("Open System Settings") { helperInstaller.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .installed:
            LabeledContent("Manage") {
                HStack {
                    Button("Test Connection") { _ = helperInstaller.ensureConnected() }
                    SurfaceDestructiveButton(
                        "Uninstall Helper…", gate: .confirm,
                        question: "Uninstall the privileged helper?",
                        consequence: "File-event monitoring, the Background Task Management audit and the network kill switch stop working until you install it again. No saved runs are affected.",
                        confirmTitle: "Uninstall"
                    ) {
                        helperInstaller.uninstall()
                    }
                }
            }
        case .error:
            LabeledContent("Retry") {
                Button("Try Again") { helperInstaller.install() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusIcon: String {
        switch helperInstaller.status {
        case .unknown:           return "questionmark.circle"
        case .notFound:          return "shippingbox"
        case .notRegistered:     return "play.circle"
        case .requiresApproval:  return "hand.raised.circle"
        case .installed:         return "checkmark.shield.fill"
        case .error:             return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch helperInstaller.status {
        case .unknown, .notRegistered: return .secondary
        case .notFound:                return .orange
        case .requiresApproval:        return .blue
        case .installed:               return .green
        case .error:                   return .red
        }
    }

    private var statusTitle: String {
        switch helperInstaller.status {
        case .unknown:           return "Checking…"
        case .notFound:          return "Helper not bundled"
        case .notRegistered:     return "Not installed"
        case .requiresApproval:  return "Awaiting approval in System Settings"
        case .installed:         return "Installed"
        case .error(let m):      return "Error: \(m)"
        }
    }
}

// MARK: - Updates (Homebrew installs)

/// Shown above the standard Updates sections when the running bundle lives
/// in the Homebrew Caskroom.
private struct HomebrewSection: View {
    let cask: String?

    private var command: String { "brew upgrade --cask \(cask ?? "privacycommand")" }

    var body: some View {
        Section("Homebrew") {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } label: {
                SurfaceInfoLabel("Installed with Homebrew",
                                 info: "This copy of privacycommand was installed as a Homebrew Cask, so brew upgrade is the supported way to update it and stays in charge of the on-disk bundle. Automatic checks are turned off at every launch; Check Now still tells you when a new version exists.")
            }
        }
    }
}
