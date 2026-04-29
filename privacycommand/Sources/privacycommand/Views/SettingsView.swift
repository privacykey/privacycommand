import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// macOS-style preferences window with three tabs. Reachable via ⌘, or the
/// "privacycommand → Settings…" menu item that SwiftUI auto-installs when
/// you declare a `Settings` scene.
struct SettingsView: View {

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .frame(minWidth: 540, minHeight: 380)
            HelperSettingsView()
                .tabItem { Label("Helper", systemImage: "shield.lefthalf.filled") }
                .frame(minWidth: 540, minHeight: 380)
            GuestAgentSettingsView()
                .tabItem { Label("VM agent", systemImage: "macwindow.on.rectangle") }
                .frame(minWidth: 540, minHeight: 380)
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .frame(minWidth: 540, minHeight: 380)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .frame(minWidth: 540, minHeight: 380)
        }
        .padding()
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("autoSaveRuns") private var autoSaveRuns = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("watchModeIconStyle") private var watchModeIconRaw = WatchModeIconStyle.shield.rawValue
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section("Run history") {
                Toggle("Save runs to history automatically", isOn: $autoSaveRuns)
                    .help("When off, only Export menu actions persist runs to disk.")
                LabeledContent("Saved runs") {
                    HStack(spacing: 8) {
                        Text("\(coordinator.recentRuns.count)")
                            .monospacedDigit()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([RunStore.shared.baseURL])
                        }
                        Button("Clear all…", role: .destructive) {
                            showingClearConfirm = true
                        }
                    }
                }
            }
            Section("Watch mode") {
                LabeledContent("Menu-bar icon") {
                    Picker("", selection: $watchModeIconRaw) {
                        ForEach(WatchModeIconStyle.allCases) { style in
                            HStack {
                                Image(systemName: style.idleSymbol)
                                Text(style.displayName)
                            }
                            .tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280)
                }
                .help("Changes the icon shown in the menu bar while watching an app.")
                LabeledContent("Preview") {
                    let style = WatchModeIconStyle(rawValue: watchModeIconRaw) ?? .shield
                    HStack(spacing: 16) {
                        Label("Idle", systemImage: style.idleSymbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                        Label("3 unread", systemImage: style.alertSymbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.primary)
                    }
                }
            }
            Section("Onboarding") {
                LabeledContent("Show wizard on next launch") {
                    Button("Replay") {
                        hasCompletedOnboarding = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { coordinator.refreshRecents() }
        .confirmationDialog(
            "Delete all saved runs?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(coordinator.recentRuns.count) run(s)", role: .destructive) {
                clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the saved JSON reports for every run. You can't undo this.")
        }
    }

    private func clearAll() {
        for meta in coordinator.recentRuns {
            coordinator.deleteRun(id: meta.id)
        }
    }
}

// MARK: - Helper

private struct HelperSettingsView: View {
    @EnvironmentObject var helperInstaller: HelperInstaller

    var body: some View {
        Form {
            Section("Privileged helper") {
                statusRow
                if let version = helperInstaller.helperVersion {
                    LabeledContent("Reported version") {
                        Text(version)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                actionRow
            }

            Section("How it works") {
                Text("The helper runs as a `root` daemon under launchd. It accepts XPC connections only from this app, signed by the same Team ID. It spawns `fs_usage(1)` to observe a target process's file activity and streams parsed events back to the GUI. It auto-stops when the run ends and unloads after a few seconds idle.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { helperInstaller.refresh() }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .foregroundStyle(statusColor)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch helperInstaller.status {
        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Bundle the helper") {
                    Text("See HELPER.md").font(.caption).foregroundStyle(.secondary)
                }
                // Surface the path we tried so the user can verify
                // whether the .app actually has the plist where we
                // expect it. If this points at a file that exists,
                // the lookup itself is broken; if it points at a
                // missing file, the build's Copy Files phase didn't
                // run.
                let plistURL = Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Library/LaunchDaemons")
                    .appendingPathComponent(HelperToolID.daemonPlistName)
                Text("Looking for: \(plistURL.path)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal app contents in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        Bundle.main.bundleURL.appendingPathComponent("Contents")
                    ])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        case .notRegistered, .unknown:
            LabeledContent("Install") {
                Button("Install helper") { helperInstaller.install() }
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
                    Button("Test connection") { _ = helperInstaller.ensureConnected() }
                    Button("Uninstall", role: .destructive) { helperInstaller.uninstall() }
                }
            }
        case .error:
            LabeledContent("Retry") {
                Button("Try again") { helperInstaller.install() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // Visual helpers

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
        case .requiresApproval:  return "Awaiting approval"
        case .installed:         return "Installed"
        case .error(let m):      return "Error: \(m)"
        }
    }
}

// MARK: - About

/// Reused both by Settings → About and by a dedicated Window scene
/// driven from the App menu's "About" command. Internal access (no
/// `private` modifier) so privacycommandApp can reach it.
struct AboutSettingsView: View {
    private let version: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    private let build:   String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 128, height: 128)
                }
                WordmarkView(fontSize: 44)
                Text("Version \(version) (\(build))")
                    .font(.callout).foregroundStyle(.secondary)

                Text("Inspect any macOS app to see what it can ask for and what it actually does.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .foregroundStyle(.secondary)

                Divider().padding(.horizontal, 60)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 20, alignment: .topLeading),
                        GridItem(.flexible(), spacing: 20, alignment: .topLeading)
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    capability("Static analysis", "Info.plist, entitlements, signing, frameworks, hard-coded URLs.")
                    capability("Network monitoring", "lsof + nettop polling — no special permission needed.")
                    capability("File monitoring", "Optional privileged helper backed by fs_usage(1).")
                    capability("Risk scoring", "Aggregate static + dynamic findings with explainable contributors.")
                    capability("Run history", "Persisted to ~/Library/Application Support/privacycommand/runs/")
                    capability("Compare runs", "Diff two saved reports side-by-side.")
                    capability("Reports", "Export to JSON, HTML, or PDF.")
                }
                .padding(.horizontal, 28)

                Divider().padding(.horizontal, 60)

                if let repoURL = URL(string: "https://github.com/privacykey/privacycommand") {
                    Link(destination: repoURL) {
                        HStack(spacing: 8) {
                            Image("GitHub")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text("Source on GitHub")
                            Image(systemName: "arrow.up.forward.square")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    Text(repoURL.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private func capability(_ title: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Wordmark

/// SwiftUI rendering of the privacycommand wordmark — `privacy` in regular
/// weight using primary text color, `command` in medium weight filled with
/// the brand purple gradient. Mirrors the SVG wordmark in `brand/lockup.svg`
/// without depending on an asset-catalog SVG (avoids Xcode SVG-rendering
/// quirks around currentColor).
///
/// The colors are placeholders (Tailwind purple-400 → purple-800) until the
/// PrivacyKey brand-guidelines doc is dropped into this repo. Swap the two
/// `Color(red:green:blue:)` values to match the brand purples exactly.
struct WordmarkView: View {
    var fontSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            Text("privacy")
                .fontWeight(.regular)
                .foregroundStyle(.primary)
            Text("command")
                .fontWeight(.medium)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 167.0/255.0, green: 139.0/255.0, blue: 250.0/255.0), // #A78BFA
                            Color(red:  91.0/255.0, green:  33.0/255.0, blue: 182.0/255.0)  // #5B21B6
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .font(.system(size: fontSize))
        .kerning(-fontSize * 0.025)
        .accessibilityLabel("privacycommand")
    }
}

#Preview("Wordmark") {
    VStack(spacing: 24) {
        WordmarkView(fontSize: 44)
        WordmarkView(fontSize: 64)
    }
    .padding(40)
}
