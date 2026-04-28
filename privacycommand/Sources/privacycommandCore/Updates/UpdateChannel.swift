import Foundation

/// Static configuration for the auto-update pipeline. Centralised here
/// so the appcast URL, the GitHub repo path, and the release branch
/// names live in one place — bumping the appcast host or moving to a
/// custom domain is a one-file change.
public enum UpdateChannel {

    // ─── GitHub repo ───────────────────────────────────────────────

    /// Owner / repo path used by the release pipeline and by the
    /// "Open release notes" action in the Settings UI.
    public static let githubOwner = "privacykey"
    public static let githubRepo  = "privacycommand"

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")!
    }

    public static var latestReleaseURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    // ─── Sparkle appcast ───────────────────────────────────────────

    /// Where Sparkle fetches the signed appcast feed from. Hosted on
    /// the project's `gh-pages` branch via GitHub Pages so the static
    /// XML lives independently of the codebase on `main`.
    ///
    /// **Releasing.** `scripts/release.sh` builds the DMG, signs it
    /// with the release EdDSA private key (kept *out* of the repo —
    /// see `docs/RELEASES.md`), runs Sparkle's `generate_appcast`
    /// against the dist directory, and pushes the result to
    /// `gh-pages`. The DMG itself is uploaded as a GitHub Release
    /// asset; the appcast embeds the asset URL.
    public static var appcastURL: URL {
        URL(string: "https://\(githubOwner).github.io/\(githubRepo)/appcast.xml")!
    }

    // ─── Channel ───────────────────────────────────────────────────

    /// We ship a single stable channel. The appcast generator filters
    /// `<sparkle:channel>` entries to keep beta/nightly artefacts out
    /// of the default feed; if we ever add a beta channel we'd add a
    /// second URL here and let users opt in.
    public static let channel: String = "stable"
}
