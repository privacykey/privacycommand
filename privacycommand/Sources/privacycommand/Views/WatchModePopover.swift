import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Popover content shown from the menu-bar `MenuBarExtra`. The standard
/// header and footer frame the app's own content: the watched app, the
/// recent watch-mode changes, and the controls for the run.
struct WatchModePopover: View {
    @ObservedObject var manager: WatchModeManager
    @ObservedObject var coordinator: AnalysisCoordinator

    private let app = PrivacycommandSurface.app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if manager.changes.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            controls
            Divider()
            SurfacePopoverFooter(app: app, openApp: { bringMainWindowFront() })
                .padding(10)
        }
        .frame(width: 380)
        .frame(maxHeight: 600)
        .onAppear {
            // Visiting the popover counts as having seen the changes.
            manager.markAllRead()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SurfacePopoverHeader(app: app, mark: Image(nsImage: NSApplication.shared.applicationIconImage)) {
                if let started = manager.startedAt {
                    Text(durationString(since: started))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "eye.fill").foregroundStyle(.blue)
                Text("Watching \(manager.watchedBundleName)")
                    .font(.callout.weight(.semibold))
            }
            Text("\(manager.changes.count) change\(manager.changes.count == 1 ? "" : "s") · \(coordinator.events.count) total events")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text("Nothing new since you started watching.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(manager.changes) { change in
                    row(change)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 380)
    }

    private func row(_ c: WatchModeChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: c.iconName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.callout).lineLimit(2)
                if let sub = c.subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                Text(c.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The run's own controls. Stopping the watch is the primary action.
    private var controls: some View {
        HStack(spacing: 6) {
            if !manager.changes.isEmpty {
                Button("Clear Log") { manager.clearLog() }
                    .controlSize(.small)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await stopWatching() }
            } label: {
                Label("Stop Watching", systemImage: "stop.circle")
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func bringMainWindowFront() {
        NSApp.activate(ignoringOtherApps: true)
        // The main scene has the default identifier (none). Falling back
        // on a key-window order-front does the right thing on macOS 13+.
        if let win = NSApp.windows.first(where: { $0.title == "privacycommand"
            || $0.identifier?.rawValue.contains("Window") == true
            || ($0.contentView != nil && $0.canBecomeMain) }) {
            win.makeKeyAndOrderFront(nil)
        }
    }

    private func stopWatching() async {
        manager.stop()
        await coordinator.stopMonitoredRun()
    }

    private func durationString(since start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let h = elapsed / 3600, m = (elapsed % 3600) / 60, s = elapsed % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }
}
