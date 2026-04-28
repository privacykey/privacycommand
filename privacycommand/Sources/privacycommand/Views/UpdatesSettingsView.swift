import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// "Updates" tab in Settings. Shows the running version, lets the
/// user fire a manual check, configure automatic checks, and — if
/// the bundle was installed via Homebrew Cask — directs them to
/// `brew upgrade` instead of the in-app installer.
///
/// The view owns a `@StateObject UpdateController` so it survives
/// across tab switches without re-instantiating Sparkle. Every
/// branch on `controller.homebrew.isHomebrewInstall` is intentional:
/// Homebrew users get a slightly different surface that nudges them
/// toward the Cask path without hiding the underlying release info.
struct UpdatesSettingsView: View {
    /// Reads the singleton injected by `privacycommandApp` so this
    /// tab and the app-menu "Check for Updates…" command share one
    /// Sparkle stack. Must be `@EnvironmentObject` rather than
    /// `@StateObject` to avoid a parallel Sparkle instance racing
    /// over the same UserDefaults keys.
    @EnvironmentObject private var controller: UpdateController

    var body: some View {
        Form {
            currentVersionSection
            if controller.homebrew.isHomebrewInstall {
                homebrewBanner
            }
            automaticCheckSection
            actionsSection
            statusSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var currentVersionSection: some View {
        Section("This build") {
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    Text("v\(controller.currentVersion)").monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text("Stable channel").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Last checked") {
                if let date = controller.lastCheckedAt {
                    Text(date, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var homebrewBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox").foregroundStyle(.orange)
                    Text("This bundle was installed via Homebrew Cask.")
                        .font(.callout.bold())
                }
                Text("In-app installs are disabled for Cask-managed apps so `brew upgrade` stays in control of the on-disk version. The 'Check for updates' button below still works — it just stops short of replacing the bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cask = controller.homebrew.caskName {
                    HStack(spacing: 8) {
                        Text("brew upgrade --cask \(cask)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "brew upgrade --cask \(cask)",
                                forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var automaticCheckSection: some View {
        Section("Automatic checks") {
            Toggle("Check for updates in the background",
                   isOn: $controller.autoCheckEnabled)
                .disabled(controller.homebrew.isHomebrewInstall)
                .help(controller.homebrew.isHomebrewInstall
                      ? "Disabled because this bundle is managed by Homebrew."
                      : "When on, the app polls the appcast on the schedule below. Off by default.")

            Picker("Frequency", selection: $controller.checkInterval) {
                ForEach(UpdatePreferences.CheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.menu)
            .disabled(!controller.autoCheckEnabled
                      || controller.homebrew.isHomebrewInstall)

            Text("Privacycommand contacts the appcast feed at \(UpdateChannel.appcastURL.absoluteString) only when this is on or you tap Check for updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            HStack(spacing: 12) {
                Button {
                    controller.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        if controller.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Text("Check for updates")
                    }
                }
                .disabled(controller.isChecking)
                .keyboardShortcut("u", modifiers: [.command])

                Button("Open release notes") {
                    controller.openReleasesPage()
                }
                .buttonStyle(.borderless)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let message = controller.lastStatusMessage {
            Section {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Stop skipping") {
                        controller.clearSkippedVersion()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .opacity(message.localizedCaseInsensitiveContains("skip") ? 1 : 0)
                }
            }
        }
    }
}
