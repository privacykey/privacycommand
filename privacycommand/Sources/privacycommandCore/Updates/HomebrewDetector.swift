import Foundation

/// Detects when the running app was installed via **Homebrew Cask**,
/// rather than dragged into `/Applications` or downloaded from a DMG.
///
/// **Why this matters for updates.** Homebrew users expect `brew
/// upgrade` to be the canonical update path. If Sparkle silently
/// replaces a Cask-installed `.app`, the next `brew upgrade` will
/// fight us — the Cask treats the on-disk version as "not the one I
/// installed" and may refuse to upgrade or roll us back.
///
/// The fix is simple: Sparkle's "Check for updates" still runs (so
/// users see when a new version exists), but the **install** step is
/// suppressed and the UI directs them to `brew upgrade --cask
/// privacycommand`. The same banner shows in the Updates settings
/// section.
///
/// **How we detect.** Homebrew installs Casks under
/// `/opt/homebrew/Caskroom/<name>/<version>/<App>.app` (Apple Silicon)
/// or `/usr/local/Caskroom/...` (Intel) and symlinks the resulting
/// `.app` into `/Applications`. The bundle's actual path resolves
/// (via the symlink) into one of those two prefixes, so we check
/// `Bundle.main.bundleURL.resolvingSymlinksInPath()` against the
/// known prefixes.
///
/// Caskroom paths can be customised via `HOMEBREW_CASKROOM`, so we
/// also honour that environment variable for power users.
public enum HomebrewDetector {

    /// One-shot detection result. `Result.notHomebrew` is the
    /// expected case for users who downloaded the DMG manually.
    public struct Result: Sendable, Hashable, Codable {
        public let isHomebrewInstall: Bool
        /// Path to the resolved `.app` bundle inside the Caskroom,
        /// for diagnostic display only. Nil when not a Homebrew
        /// install.
        public let caskroomPath: String?
        /// Suggested cask name — derived from the parent folder. We
        /// don't currently use this for anything but the Settings
        /// banner shows it so the user can copy-paste the right
        /// `brew upgrade --cask <name>` command.
        public let caskName: String?

        public static let notHomebrew = Result(
            isHomebrewInstall: false,
            caskroomPath: nil,
            caskName: nil)
    }

    /// Inspect the currently-running bundle. Stateless and cheap —
    /// safe to call from `init` of a settings view-model.
    public static func detect() -> Result {
        detect(at: Bundle.main.bundleURL)
    }

    /// Test seam — lets the unit tests pass an arbitrary URL.
    public static func detect(at bundleURL: URL) -> Result {
        let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

        for prefix in caskroomPrefixes() {
            // Match either an exact path under the prefix or a
            // path that has the prefix as an ancestor. We use a
            // trailing slash so `/opt/homebrew/Caskroom-other` doesn't
            // match `/opt/homebrew/Caskroom`.
            let needle = prefix.hasSuffix("/") ? prefix : prefix + "/"
            guard resolved.hasPrefix(needle) else { continue }

            // Cask folder layout: <prefix>/<cask-name>/<version>/<App>.app
            // Slice out the cask name from the first path component
            // after the prefix.
            let tail = String(resolved.dropFirst(needle.count))
            let caskName = tail.split(separator: "/").first.map(String.init)
            return Result(
                isHomebrewInstall: true,
                caskroomPath: resolved,
                caskName: caskName)
        }
        return .notHomebrew
    }

    // MARK: - Caskroom prefix discovery

    private static func caskroomPrefixes() -> [String] {
        var roots: [String] = []
        // Honour HOMEBREW_CASKROOM if it's set in the environment —
        // power users sometimes relocate the Caskroom.
        if let custom = ProcessInfo.processInfo.environment["HOMEBREW_CASKROOM"],
           !custom.isEmpty {
            roots.append(custom)
        }
        // Standard Apple Silicon prefix.
        roots.append("/opt/homebrew/Caskroom")
        // Standard Intel prefix.
        roots.append("/usr/local/Caskroom")
        return roots
    }
}
