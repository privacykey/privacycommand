import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

@main
struct privacycommandApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// User-chosen menu-bar icon for watch mode. Defaults to the shield —
    /// matches the privacycommand brand mark.
    @AppStorage("watchModeIconStyle") private var watchModeIconRaw = WatchModeIconStyle.shield.rawValue
    @StateObject private var coordinator = AnalysisCoordinator()
    @StateObject private var helperInstaller = HelperInstaller()
    @StateObject private var watchManager = WatchModeManager()
    /// Singleton update controller — shared between the menu-bar
    /// "Check for Updates…" command and the Settings → Updates tab.
    /// Both surfaces read the same `@StateObject` via the SwiftUI
    /// environment so they don't instantiate parallel Sparkle stacks
    /// (which would race over the same UserDefaults keys).
    @StateObject private var updateController = UpdateController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Decoded icon style — falls back to `.shield` if the persisted raw
    /// string doesn't match any case (e.g. after we add/remove options
    /// in a future build).
    private var watchIcon: WatchModeIconStyle {
        WatchModeIconStyle(rawValue: watchModeIconRaw) ?? .shield
    }

    var body: some Scene {
        WindowGroup("privacycommand") {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                        .environmentObject(coordinator)
                        .environmentObject(helperInstaller)
                        .environmentObject(watchManager)
                        .environmentObject(updateController)
                } else {
                    OnboardingView(onComplete: { hasCompletedOnboarding = true })
                        .environmentObject(helperInstaller)
                }
            }
            .frame(minWidth: 980, minHeight: 640)
            .onAppear {
                // Note: AppIconRenderer.install() now runs in
                // AppDelegate.applicationDidFinishLaunching so the
                // About panel and Dock both have the rendered icon
                // even before the first window appears.
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
            CommandGroup(replacing: .newItem) { }   // single-window app

            // Replace the default macOS About panel (which only shows
            // CFBundleName + version + copyright) with our richer
            // SwiftUI About window. The default panel doesn't show
            // capability / GitHub-link content, and on cold launch
            // doesn't even pick up the rendered icon because
            // AppIconRenderer.install() only runs when a content
            // window appears.
            CommandGroup(replacing: .appInfo) {
                OpenAboutMenuItem()
            }

            CommandMenu("Run") {
                Button("Open .app…") { coordinator.presentOpenPanel() }
                    .keyboardShortcut("o")
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
            CommandMenu("Export") {
                Button("Save Run Report (JSON)…") { coordinator.exportJSON() }
                    .disabled(!coordinator.hasRunReport)
                Button("Save Run Report (HTML)…") { coordinator.exportHTML() }
                    .disabled(!coordinator.hasRunReport)
                Button("Save Run Report (PDF)…") { coordinator.exportPDF() }
                    .disabled(!coordinator.hasRunReport)
            }
            CommandGroup(after: .help) {
                Divider()
                OpenKnowledgeBaseMenuItem()
                Button("Show Onboarding…") { hasCompletedOnboarding = false }
                Button("Refresh Helper Status") { helperInstaller.refresh() }
            }

            // Conventional macOS placement for the updater item: just
            // after "About <App>" inside the application menu. ⌘U
            // matches the Settings → Updates "Check for updates"
            // button so muscle-memory carries between the two.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }

        // Adds ⌘, support and the "Settings…" menu item under the app menu.
        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(helperInstaller)
                .environmentObject(updateController)
        }

        // Standalone window so users can keep the KB open while browsing
        // their report. Identified by id so the Help → Knowledge Base… item
        // can request it via @Environment(\.openWindow).
        Window("Knowledge Base", id: "knowledge-base") {
            KnowledgeBaseBrowserView()
        }

        // Custom About window — replaces the default Apple About panel
        // (set up via CommandGroup(replacing: .appInfo) above). Renders
        // the same content the Settings → About tab does so we don't
        // maintain two copies.
        Window("About privacycommand", id: "about") {
            AboutSettingsView()
                .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 600)
        }
        .windowResizability(.contentSize)

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
        // monitor stop, matching the explicit "Stop watching" path.
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

/// Same trick for the About panel. SwiftUI's default `.appInfo` group
/// shows Apple's stock About sheet; this opens our custom Window scene.
private struct OpenAboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About privacycommand") {
            openWindow(id: "about")
        }
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
    /// `AppIcon.icns` in Resources) supply the Dock / About-panel icon at
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
