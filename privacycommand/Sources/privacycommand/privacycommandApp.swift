import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

@main
struct privacycommandApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @StateObject private var coordinator = AnalysisCoordinator()
    @StateObject private var helperInstaller = HelperInstaller()
    @StateObject private var watchManager = WatchModeManager()
    /// Owns the one Sparkle updater; `updates` drives the Updates pane and
    /// the Check for Updates… item from it.
    @StateObject private var updateController: UpdateController
    @StateObject private var updates: SurfaceUpdates
    /// The watch-mode menu bar icon, stored under the key the app has
    /// always used so an existing choice carries over.
    @StateObject private var menuBar = SurfaceMenuBarPreference(
        defaultIcon: WatchModeIconStyle.shield.rawValue,
        iconKey: "watchModeIconStyle"
    )
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let app = PrivacycommandSurface.app

    init() {
        let controller = UpdateController()
        _updateController = StateObject(wrappedValue: controller)
        _updates = StateObject(wrappedValue: SurfaceUpdates(
            driver: controller.updater,
            releaseNotes: PrivacycommandSurface.releaseNotes
        ))
    }

    /// The shared manual and shortcut windows open by default; the welcome
    /// replays the first-run onboarding.
    private var help: SurfaceHelp {
        SurfaceHelp(replayWelcome: { hasCompletedOnboarding = false })
    }

    /// Decoded icon style, falling back to the shield if the stored value
    /// no longer matches a case.
    private var watchIcon: WatchModeIconStyle {
        WatchModeIconStyle(rawValue: menuBar.icon) ?? .shield
    }

    var body: some Scene {
        // `id: "main"` so batch mode's "Analyze in Main Window" can focus
        // this window via `openWindow(id:)`.
        WindowGroup("privacycommand", id: "main") {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                        .environmentObject(coordinator)
                        .environmentObject(helperInstaller)
                        .environmentObject(watchManager)
                } else {
                    OnboardingView(onComplete: { hasCompletedOnboarding = true })
                        .environmentObject(helperInstaller)
                }
            }
            .frame(minWidth: 980, minHeight: 640)
            .onAppear {
                helperInstaller.refresh()
                coordinator.helperInstaller = helperInstaller
                // Hand the coordinator to the delegate so it can ask for
                // the live tracked-PID set on willTerminate, plus the
                // watch manager so applicationShouldTerminateAfterLastWindowClosed
                // can ask whether to keep running.
                appDelegate.coordinator = coordinator
                appDelegate.watchManager = watchManager
            }
        }
        .commands {
            // About, Check for Updates… and the three Help items.
            SurfaceCommands(app: app, help: help, updates: updates)

            // File holds the app's own open and export actions in place of
            // New Window: this is a single-window app.
            CommandGroup(replacing: .newItem) {
                Button("Open .app…") { coordinator.presentOpenPanel() }
                    .keyboardShortcut("o")
                OpenBatchScanMenuItem()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Run Report (JSON)…") { coordinator.exportJSON() }
                    .disabled(!coordinator.hasRunReport)
                Button("Save Run Report (HTML)…") { coordinator.exportHTML() }
                    .disabled(!coordinator.hasRunReport)
                Button("Save Run Report (PDF)…") { coordinator.exportPDF() }
                    .disabled(!coordinator.hasRunReport)
            }

            CommandGroup(after: .toolbar) {
                OpenKnowledgeBaseMenuItem()
            }

            CommandMenu("Run") {
                Button("Start Monitored Run") { Task { await coordinator.startMonitoredRun() } }
                    .keyboardShortcut("r")
                    .disabled(!coordinator.canStartRun)
                Button("Stop Monitored Run") { Task { await coordinator.stopMonitoredRun() } }
                    .keyboardShortcut(".")
                    .disabled(!coordinator.canStopRun)
                Button(coordinator.isPaused ? "Resume App" : "Pause App (Kill Switch)") {
                    Task { await coordinator.toggleKillSwitch() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!coordinator.isMonitoring)
                Divider()
                Button(watchManager.isWatching ? "Stop Watching" : "Start Watching…") {
                    if watchManager.isWatching {
                        watchManager.stop()
                        Task { await coordinator.stopMonitoredRun() }
                    } else {
                        Task {
                            if !coordinator.isMonitoring { await coordinator.startMonitoredRun() }
                            watchManager.start(coordinator: coordinator)
                        }
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!coordinator.canStartRun && !watchManager.isWatching)
            }
        }

        // Adds ⌘, support and the "Settings…" menu item under the app menu.
        Settings {
            SurfaceSettings(app: app, panes: PrivacycommandSettings.panes(
                app: app,
                menuBar: menuBar,
                watchManager: watchManager,
                updates: updates,
                updateController: updateController
            ))
            .environmentObject(coordinator)
            .environmentObject(helperInstaller)
        }

        SurfaceAboutWindow(app: app, help: help)
        SurfaceManualWindow(app: app)
        SurfaceShortcutsWindow(groups: PrivacycommandSurface.shortcuts)

        // Standalone window so users can keep the KB open while browsing
        // their report. Identified by id so the View → Knowledge Base… item
        // can request it via @Environment(\.openWindow).
        Window("Knowledge Base", id: "knowledge-base") {
            KnowledgeBaseBrowserView()
        }

        // Batch mode — scan many apps at once and triage them in a sortable,
        // filterable table. Standalone window (id) so the File menu item can
        // request it via @Environment(\.openWindow). Shares the coordinator so
        // "Analyze in Main Window" can hand an app to the deep-dive flow.
        Window("Scan Apps", id: "batch-scan") {
            BatchScanView()
                .environmentObject(coordinator)
        }

        // Menu-bar item for watch mode. Only inserted while watching, so
        // it disappears the moment the user (or a connection failure)
        // stops the run. Uses the windowed style so we get a SwiftUI
        // popover instead of the standard menu rendering.
        //
        // `WatchModeManager.isWatching` is `private(set)` (start/stop are
        // the canonical entry points), so we wrap it in a computed
        // Binding here. A `false` write — caused by the user removing the
        // menu-bar icon via the system, or anything else SwiftUI deems a
        // dismissal — gets translated into `manager.stop()` plus a
        // monitor stop, matching the explicit "Stop watching" path. Writes
        // that do not change the value are ignored.
        MenuBarExtra(isInserted: Binding(
            get: { watchManager.isWatching },
            set: { newValue in
                if !newValue && watchManager.isWatching {
                    watchManager.stop()
                    Task { await coordinator.stopMonitoredRun() }
                }
            }
        )) {
            WatchModePopover(manager: watchManager, coordinator: coordinator)
        } label: {
            Image(systemName: watchManager.unreadCount > 0
                  ? watchIcon.alertSymbol : watchIcon.idleSymbol)
                .accessibilityLabel(watchManager.unreadCount > 0
                                    ? "privacycommand, \(watchManager.unreadCount) unread changes"
                                    : "privacycommand, watching")
            if watchManager.unreadCount > 0 {
                Text(" \(watchManager.unreadCount)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Tiny wrapper view so the menu item can call `openWindow` from the
/// environment — `.commands` doesn't otherwise expose env values.
private struct OpenKnowledgeBaseMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Knowledge Base…") {
            openWindow(id: "knowledge-base")
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}

/// Opens the batch-scan window from the File menu. Same `openWindow`-from-
/// commands trick as the Knowledge Base item.
private struct OpenBatchScanMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Scan Installed Apps…") {
            openWindow(id: "batch-scan")
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}

/// Tracks a weak reference to the active coordinator so we can terminate the
/// target's process tree if the auditor is being quit (cmd-Q, force-quit
/// dialog approval, etc.) — without leaving Chrome / Slack / whatever still
/// running orphaned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AnalysisCoordinator?
    weak var watchManager: WatchModeManager?

    /// The bundled `AppIcon` asset catalog entry (and the legacy
    /// `AppIcon.icns` in Resources) supply the Dock / About-window icon at
    /// build time, so no runtime override is needed. The previous
    /// `AppIconRenderer.install()` call rendered a SwiftUI placeholder via
    /// `NSApp.applicationIconImage` — keeping it would clobber the real
    /// branded icon. The renderer struct in `AppIconView.swift` is kept for
    /// reference / quick previews but is no longer wired into the app.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppIconRenderer.install() — disabled; bundle asset catalog wins.
    }

    /// While watch mode is active, closing the main window should not
    /// terminate the app — the menu-bar item is the user's only handle on
    /// the live run. We return `false` here whenever watching, otherwise
    /// fall through to the system default.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if watchManager?.isWatching == true { return false }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let coordinator else { return }
        // We're on the main thread here. The coordinator's monitor is an
        // actor — fetching the live PID set is `async`, so we drive a
        // RunLoop tick to wait for it (acceptable on terminate; the process
        // is going away).
        let semaphore = DispatchSemaphore(value: 0)
        var pids: Set<Int32> = []
        Task.detached {
            pids = await coordinator.currentlyTrackedPIDsForExit()
            semaphore.signal()
        }
        // Cap at 1 second — terminate handlers shouldn't block forever.
        _ = semaphore.wait(timeout: .now() + .seconds(1))
        AnalysisCoordinator.terminateTargetTree(pids)
    }
}
