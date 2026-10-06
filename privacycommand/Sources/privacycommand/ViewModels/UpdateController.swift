import Foundation
import Sparkle
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Owns the one Sparkle updater for the app. The Updates pane and the
/// Check for Updates… item are the shared surfaces, driven by
/// `SurfaceUpdates(driver: updater, releaseNotes:)`; this class only keeps
/// the updater alive, pins it to the stable channel and applies the
/// Homebrew rule.
///
/// **Homebrew co-existence.** When `HomebrewDetector` reports that the
/// running bundle lives under `/opt/homebrew/Caskroom/...`, automatic
/// checks are turned off at every launch so Sparkle never replaces a
/// bundle that `brew upgrade --cask privacycommand` manages. A manual
/// check still works: knowing a new version exists is useful regardless
/// of who applies it, and the Updates pane says so.
@MainActor
final class UpdateController: ObservableObject {

    /// True when this bundle was installed via Homebrew Cask.
    let homebrew: HomebrewDetector.Result

    /// Sparkle's controller owns the lifecycle. Instantiated eagerly
    /// (`startingUpdater: true`) so background checks can run as soon as
    /// the user turns them on. `SUEnableAutomaticChecks` is false in
    /// Info.plist, so they start off and Sparkle never asks on its own.
    private let updaterController: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    /// The driver the shared Updates pane and app menu work with.
    var updater: SPUUpdater { updaterController.updater }

    init() {
        homebrew = HomebrewDetector.detect()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        if homebrew.isHomebrewInstall {
            updaterController.updater.automaticallyChecksForUpdates = false
        }
    }
}

// MARK: - Sparkle delegate

/// Sparkle's delegate methods are `@objc` and pre-Swift-concurrency, so
/// they live on a separate `NSObject`.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Sparkle's preferred channels — single-element list keeps us on
    /// stable. If we ever add a beta channel, this is where the opt-in
    /// toggle plumbs through.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [UpdateChannel.channel]
    }
}
