import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// `@MainActor` `ObservableObject` wrapping Sparkle 2's
/// `SPUStandardUpdaterController` and exposing the bits the Settings
/// UI needs as `@Published` properties.
///
/// **Why a wrapper rather than using Sparkle directly.** Sparkle's
/// classes are AppKit-flavoured `NSObject`s; bridging them into a
/// SwiftUI Settings view in a way that keeps Preview happy and lets
/// us toggle automatic checks without a relaunch is cleaner with one
/// glue class.
///
/// **Homebrew co-existence.** When `HomebrewDetector` reports that
/// the running bundle lives under `/opt/homebrew/Caskroom/...`,
/// Sparkle's `automaticallyChecksForUpdates` is forced to `false` and
/// the Settings UI substitutes a "Run `brew upgrade --cask
/// privacycommand`" banner for the install button. Manual "Check for
/// updates" still works — it's helpful to know when a new version
/// exists even when you're not the one applying it.
///
/// **Gating Sparkle behind `canImport`.** The wrapper compiles
/// cleanly when Sparkle isn't available (early SPM resolve, CI
/// without the dep) by stubbing the operations to no-ops. That keeps
/// `swift build` green while you're wiring the dependency into Xcode
/// for the first time.
@MainActor
final class UpdateController: ObservableObject {

    // MARK: - Published state

    /// True while Sparkle is fetching the appcast or downloading an
    /// update. Drives the spinner on the "Check for updates" button.
    @Published private(set) var isChecking: Bool = false

    /// Mirrors `UpdatePreferences.autoCheckEnabled`. Setting flips
    /// the underlying Sparkle property live.
    @Published var autoCheckEnabled: Bool {
        didSet {
            UpdatePreferences.setAutoCheckEnabled(autoCheckEnabled)
            applyAutoCheckSetting()
        }
    }

    /// Mirrors `UpdatePreferences.checkInterval`.
    @Published var checkInterval: UpdatePreferences.CheckInterval {
        didSet {
            UpdatePreferences.setCheckInterval(checkInterval)
            applyCheckIntervalSetting()
        }
    }

    /// Last time Sparkle finished fetching the appcast.
    @Published private(set) var lastCheckedAt: Date?

    /// Latest message we want to surface to the user — driven by the
    /// Sparkle delegate methods below. Never block-triggers an alert;
    /// the Settings UI shows it inline.
    @Published private(set) var lastStatusMessage: String?

    /// True when this bundle was installed via Homebrew Cask. The
    /// Settings UI swaps the "Install" path for a `brew upgrade`
    /// banner in that case.
    let homebrew: HomebrewDetector.Result

    /// Display version pulled from `CFBundleShortVersionString`.
    /// Cached at init so the Settings UI doesn't have to re-read the
    /// bundle on each render.
    let currentVersion: String

    // MARK: - Init

    #if canImport(Sparkle)
    /// Sparkle's controller owns the lifecycle. We instantiate eagerly
    /// (`startingUpdater: true`) so background checks can run as soon
    /// as the user enables them.
    private let updaterController: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()
    #endif

    init() {
        self.homebrew = HomebrewDetector.detect()
        self.autoCheckEnabled = UpdatePreferences.autoCheckEnabled
        self.checkInterval = UpdatePreferences.checkInterval
        self.lastCheckedAt = UpdatePreferences.lastCheckedAt
        self.currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "(unknown)"

        #if canImport(Sparkle)
        // `startingUpdater: true` boots Sparkle's background scheduler
        // immediately. The `applyAutoCheckSetting()` below will turn
        // that scheduler off if the user hasn't opted in.
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.controller = self
        #endif

        applyAutoCheckSetting()
        applyCheckIntervalSetting()
    }

    // MARK: - Public actions

    /// Run an explicit "Check for updates" against the appcast.
    /// Always allowed, even on Homebrew installs — knowing a new
    /// version exists is useful regardless of who's applying it.
    func checkForUpdates() {
        #if canImport(Sparkle)
        isChecking = true
        lastStatusMessage = "Checking for updates…"
        updaterController.checkForUpdates(nil)
        #else
        lastStatusMessage = "Sparkle is not linked into this build."
        #endif
    }

    /// Open the GitHub Releases page in the default browser. Used by
    /// the "Release notes" link in Settings, and by the Homebrew
    /// banner's "View latest release" action.
    func openReleasesPage() {
        NSWorkspace.shared.open(UpdateChannel.releasesPageURL)
    }

    /// Stop skipping a previously-skipped version, so Sparkle will
    /// surface it again on the next check. The Settings UI exposes
    /// this when `lastStatusMessage` indicates a skip is in effect.
    func clearSkippedVersion() {
        #if canImport(Sparkle)
        // Sparkle stores the skipped version under
        // `SUSkippedVersion` / `SUSkippedMinorVersion` in
        // UserDefaults; clearing both is the documented way to undo
        // a skip without API for it.
        UserDefaults.standard.removeObject(forKey: "SUSkippedVersion")
        UserDefaults.standard.removeObject(forKey: "SUSkippedMinorVersion")
        UserDefaults.standard.removeObject(forKey: UpdatePreferences.Key.skippedVersion)
        lastStatusMessage = "Cleared the skipped-version preference."
        #endif
    }

    // MARK: - Internal — called by the Sparkle delegate

    fileprivate func didFinishCheck(success: Bool, message: String?) {
        isChecking = false
        if success {
            UpdatePreferences.recordCheckCompleted()
            lastCheckedAt = UpdatePreferences.lastCheckedAt
        }
        if let message { lastStatusMessage = message }
    }

    // MARK: - Sparkle setting application

    private func applyAutoCheckSetting() {
        #if canImport(Sparkle)
        // Homebrew installs override the user's preference. We never
        // let Sparkle silently install over a Cask-managed bundle;
        // the "Check for updates" button still works, but the
        // background scheduler stays off so users aren't tempted
        // toward a broken install path.
        let effective = autoCheckEnabled && !homebrew.isHomebrewInstall
        updaterController.updater.automaticallyChecksForUpdates = effective
        #endif
    }

    private func applyCheckIntervalSetting() {
        #if canImport(Sparkle)
        updaterController.updater.updateCheckInterval = checkInterval.sparkleSeconds
        #endif
    }
}

// MARK: - Sparkle delegate

#if canImport(Sparkle)
/// Sparkle's delegate methods are `@objc` and pre-Swift-concurrency,
/// so we keep them on a separate `NSObject` and bounce results back
/// to the `@MainActor`-isolated controller. Holding the controller
/// weakly avoids a retain cycle (the controller owns Sparkle, which
/// holds a reference to this delegate).
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var controller: UpdateController?

    /// Sparkle's preferred channels — single-element list keeps us
    /// on stable. If we ever add a beta channel, this is where the
    /// opt-in toggle plumbs through.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [UpdateChannel.channel]
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor [weak controller] in
            controller?.didFinishCheck(success: true, message: nil)
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let message = error.map { "Update check failed: \($0.localizedDescription)" }
        Task { @MainActor [weak controller] in
            controller?.didFinishCheck(success: error == nil, message: message)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        Task { @MainActor [weak controller] in
            controller?.didFinishCheck(
                success: true,
                message: "Update available: v\(v).")
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak controller] in
            controller?.didFinishCheck(
                success: true,
                message: "You're on the latest version.")
        }
    }
}
#endif
