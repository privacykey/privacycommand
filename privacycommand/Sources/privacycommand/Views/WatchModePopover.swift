import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Popover content shown from the menu-bar `MenuBarExtra`. Lists recent
/// watch-mode changes plus controls for stopping watch / opening the main
/// window.
struct WatchModePopover: View {
    @ObservedObject var manager: WatchModeManager
    @ObservedObject var coordinator: AnalysisCoordinator
    /// SwiftUI helper for activating an existing window scene.
    @Environment(\.openWindow) private var openWindow

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
            footer
        }
        .frame(width: 380)
        .frame(maxHeight: 540)
        .onAppear {
            // Visiting the popover counts as having seen the changes.
            manager.markAllRead()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill").foregroundStyle(.blue)
                Text("Watching \(manager.watchedBundleName)")
                    .font(.headline)
                Spacer()
                if let started = manager.startedAt {
                    Text(durationString(since: started))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                bringMainWindowFront()
            } label: {
                Label("Open auditor", systemImage: "macwindow")
            }
            Spacer()
            if !manager.changes.isEmpty {
                Button("Clear log") { manager.clearLog() }
                    .controlSize(.small)
            }
            Button(role: .destructive) {
                Task { await stopWatching() }
            } label: {
                Label("Stop watching", systemImage: "stop.circle")
            }
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
