import Foundation

/// User-controllable knobs for the auto-update system. Backed by
/// `UserDefaults` so they survive across launches and can be edited
/// from the Settings UI without touching Sparkle directly. The
/// `UpdateController` (in the app target) reads these values when
/// initialising Sparkle and writes them back when the toggles change.
///
/// **Defaults.** Auto-checks ship **off**. Privacycommand is a
/// privacy/security tool, and a fresh install making background HTTP
/// calls to a third-party host before the user has explicitly opted
/// in would be inconsistent with how the rest of the app behaves
/// (e.g. App Store privacy-label fetch is gated behind detected MAS
/// receipt; Top remote hosts polling is opt-in). Users opt in via
/// the Settings → Updates tab; the same tab exposes a manual
/// "Check for updates" button that works regardless.
public enum UpdatePreferences {

    /// `UserDefaults` keys, namespaced with `update.` to keep them
    /// distinct from the rest of the app's preferences.
    public enum Key {
        public static let autoCheckEnabled = "update.autoCheckEnabled"
        public static let checkInterval    = "update.checkInterval"
        public static let lastCheckedAt    = "update.lastCheckedAt"
        /// Sparkle writes the appcast version the user chose to
        /// skip into its own keys; we mirror it here so the
        /// Settings UI can show "Currently skipping vX.Y.Z" with a
        /// one-click "Stop skipping" button.
        public static let skippedVersion   = "update.skippedVersion"
    }

    /// How often Sparkle checks for updates when auto-checking is
    /// on. Values are in seconds, matching Sparkle's
    /// `updateCheckInterval` API.
    public enum CheckInterval: TimeInterval, CaseIterable, Sendable, Hashable {
        case daily   = 86_400      // 1 day
        case weekly  = 604_800     // 7 days
        case monthly = 2_592_000   // 30 days

        public var displayName: String {
            switch self {
            case .daily:   return "Daily"
            case .weekly:  return "Weekly"
            case .monthly: return "Monthly"
            }
        }

        public var sparkleSeconds: TimeInterval { rawValue }
    }

    // MARK: - Read

    public static var autoCheckEnabled: Bool {
        // Default false — opt-in.
        UserDefaults.standard.object(forKey: Key.autoCheckEnabled) as? Bool ?? false
    }

    public static var checkInterval: CheckInterval {
        let raw = UserDefaults.standard.object(forKey: Key.checkInterval) as? TimeInterval
        return raw.flatMap(CheckInterval.init(rawValue:)) ?? .weekly
    }

    public static var lastCheckedAt: Date? {
        UserDefaults.standard.object(forKey: Key.lastCheckedAt) as? Date
    }

    // MARK: - Write

    public static func setAutoCheckEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Key.autoCheckEnabled)
    }

    public static func setCheckInterval(_ interval: CheckInterval) {
        UserDefaults.standard.set(interval.rawValue, forKey: Key.checkInterval)
    }

    public static func recordCheckCompleted(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: Key.lastCheckedAt)
    }
}
