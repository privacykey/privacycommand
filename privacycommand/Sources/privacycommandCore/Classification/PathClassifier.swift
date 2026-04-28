import Foundation

/// Classifies a filesystem path into a `PathCategory`. Rules are kept in a
/// JSON resource so they can be tweaked without recompiling, but a built-in
/// table is provided as the default.
public struct PathClassifier: Sendable {

    public struct Rule: Codable, Hashable, Sendable {
        public let prefix: String          // e.g. "~/Documents", "/Users/", "/Volumes/"
        public let category: PathCategory
        public let isHomeRelative: Bool    // expand `~/` per-user

        public init(prefix: String, category: PathCategory, isHomeRelative: Bool) {
            self.prefix = prefix
            self.category = category
            self.isHomeRelative = isHomeRelative
        }
    }

    private let homeURL: URL
    private let rules: [Rule]

    public init(rules: [Rule] = PathClassifier.builtinRules,
                homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rules = rules
        self.homeURL = homeURL
    }

    public static func load(fromResource url: URL?,
                            homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> PathClassifier {
        if let url,
           let data = try? Data(contentsOf: url),
           let rules = try? JSONDecoder().decode([Rule].self, from: data) {
            return PathClassifier(rules: rules, homeURL: homeURL)
        }
        return PathClassifier(rules: builtinRules, homeURL: homeURL)
    }

    /// True when `path` is touched by the inspected app at a location
    /// that *isn't* normally part of an app's own legitimate scope —
    /// other apps' containers, other users' home directories, sensitive
    /// dotfiles like `~/.ssh` / `~/.aws`, or other apps' Application
    /// Support / Caches / Preferences. Read-only system directories
    /// (`/System`, `/usr/lib`, framework caches) and the app's own
    /// in-scope locations (sandbox container, `~/Library/Application
    /// Support/<bundle-id>/`, etc.) are *in* scope.
    ///
    /// Used by `FileAccessView` to highlight out-of-scope reads/writes
    /// in orange. Distinct from `Risk.surprising`, which is the static
    /// risk classifier's verdict — this is a per-event check that's
    /// cheap to compute on the view side.
    public func isOutsideScope(path: String,
                               ownerBundleURL: URL?,
                               bundleID: String?) -> Bool {
        let normalized = (path as NSString).standardizingPath

        // Inside the bundle itself — always in scope.
        if let owner = ownerBundleURL {
            let bundlePath = owner.standardizedFileURL.path
            if normalized == bundlePath || normalized.hasPrefix(bundlePath + "/") {
                return false
            }
        }

        // System read-only roots.
        let systemRoots = [
            "/System/", "/usr/lib/", "/usr/share/", "/usr/libexec/",
            "/Library/Frameworks/",
            "/private/var/db/dyld/", "/private/var/db/timezone/",
            "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom"
        ]
        for root in systemRoots {
            if normalized.hasPrefix(root) || normalized == String(root.dropLast()) {
                return false
            }
        }

        // Temporary / cache roots used by every app.
        let tempRoots = [
            "/tmp/", "/private/tmp/",
            "/private/var/folders/",   // NSTemporaryDirectory
            "/Library/Caches/com.apple."
        ]
        for root in tempRoots {
            if normalized.hasPrefix(root) { return false }
        }

        // App's own scoped locations: sandbox container, application
        // support, caches, preferences, logs, all keyed by bundle ID.
        if let bid = bundleID, !bid.isEmpty {
            let scoped: [String] = [
                homeURL.path + "/Library/Containers/\(bid)/",
                homeURL.path + "/Library/Group Containers/group.\(bid)/",
                homeURL.path + "/Library/Application Support/\(bid)/",
                homeURL.path + "/Library/Caches/\(bid)/",
                homeURL.path + "/Library/Logs/\(bid)/",
                homeURL.path + "/Library/Preferences/\(bid).plist",
                homeURL.path + "/Library/Saved Application State/\(bid).savedState/",
                "/Library/Application Support/\(bid)/",
                "/Library/Caches/\(bid)/",
                "/Library/Logs/\(bid)/",
                "/Library/Preferences/\(bid).plist"
            ]
            for s in scoped {
                if normalized == s || normalized.hasPrefix(s) { return false }
            }
        }

        // Anything user-home related that isn't the bundle's own scope
        // counts as out-of-scope. Sensitive subdirectories (`.ssh`,
        // `.aws`, `.gnupg`, `.config/gh`) are always out of scope.
        let homePath = homeURL.path
        if normalized.hasPrefix(homePath + "/") {
            // Sensitive dotfiles get flagged regardless of bundle ID.
            let sensitive = ["/.ssh/", "/.aws/", "/.gnupg/", "/.config/gh/",
                             "/.config/op/", "/.kube/", "/.netrc",
                             "/.pgpass", "/.ssh", "/.aws", "/.gnupg"]
            for s in sensitive {
                if normalized.hasPrefix(homePath + s) { return true }
            }
            // Falling through: a user-home access we couldn't explain
            // by the bundle's own scope rules.
            return true
        }

        // Other Mach root-level paths (e.g. `/Applications/Other.app/`)
        // are out of scope unless they're the bundle itself.
        if normalized.hasPrefix("/Applications/")
            || normalized.hasPrefix("/Library/")
            || normalized.hasPrefix("/Volumes/") {
            return true
        }

        return false
    }

    public func classify(_ path: String, ownerBundleURL: URL? = nil) -> PathCategory {
        let normalized = (path as NSString).standardizingPath

        // Inside the bundle's own resources is a special case.
        if let owner = ownerBundleURL {
            let bundlePath = owner.standardizedFileURL.path
            if normalized == bundlePath || normalized.hasPrefix(bundlePath + "/") {
                return .bundleInternal
            }
        }

        // Removable / network volumes
        if normalized.hasPrefix("/Volumes/") {
            return classifyVolume(normalized)
        }
        // iCloud Drive
        if normalized.hasPrefix(homeURL.path + "/Library/Mobile Documents/com~apple~CloudDocs") {
            return .iCloudDrive
        }

        for rule in rules {
            let absolutePrefix: String
            if rule.isHomeRelative {
                let withoutLeading = rule.prefix.hasPrefix("~/") ? String(rule.prefix.dropFirst(2)) : rule.prefix
                absolutePrefix = homeURL.appendingPathComponent(withoutLeading).path
            } else {
                absolutePrefix = rule.prefix
            }
            if normalized == absolutePrefix || normalized.hasPrefix(absolutePrefix + "/") {
                return rule.category
            }
        }
        return .unknown
    }

    private func classifyVolume(_ path: String) -> PathCategory {
        // /Volumes/<volname> — use URL resourceValues for an authoritative answer.
        let url = URL(fileURLWithPath: path)
        if let r = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey]) {
            if r.volumeIsRemovable == true { return .removableVolume }
            if r.volumeIsLocal == false    { return .networkVolume }
        }
        // Fall back to "removable" — it's the safer guess on /Volumes/ paths.
        return .removableVolume
    }

    public static let builtinRules: [Rule] = [
        // Home subfolders, ordered most specific → least specific.
        Rule(prefix: "~/Library/Cookies",                                  category: .userLibraryCookies,      isHomeRelative: true),
        Rule(prefix: "~/Library/Keychains",                                category: .userLibraryKeychains,    isHomeRelative: true),
        Rule(prefix: "~/Library/Containers",                               category: .userLibraryContainers,   isHomeRelative: true),
        Rule(prefix: "~/Library/Group Containers",                         category: .userLibraryContainers,   isHomeRelative: true),
        Rule(prefix: "~/Library/Application Support",                      category: .userLibraryAppSupport,   isHomeRelative: true),
        Rule(prefix: "~/Library/Caches",                                   category: .userLibraryCaches,       isHomeRelative: true),
        Rule(prefix: "~/Library/Preferences",                              category: .userLibraryPreferences,  isHomeRelative: true),
        Rule(prefix: "~/Library/Messages",                                 category: .userLibraryMessages,     isHomeRelative: true),
        Rule(prefix: "~/Library/Mail",                                     category: .userLibraryMail,         isHomeRelative: true),
        Rule(prefix: "~/Library/Calendars",                                category: .userLibraryCalendar,     isHomeRelative: true),
        Rule(prefix: "~/Library/Application Support/AddressBook",          category: .userLibraryContacts,     isHomeRelative: true),
        Rule(prefix: "~/Library/Photos",                                   category: .userLibraryPhotos,       isHomeRelative: true),
        Rule(prefix: "~/Pictures/Photos Library.photoslibrary",            category: .userLibraryPhotos,       isHomeRelative: true),
        Rule(prefix: "~/Library/Safari",                                   category: .userLibrarySafari,       isHomeRelative: true),
        Rule(prefix: "~/.ssh",                                             category: .userLibrarySSH,          isHomeRelative: true),
        Rule(prefix: "~/Library",                                          category: .userHomeOther,           isHomeRelative: true),
        Rule(prefix: "~/Documents",                                        category: .userDocuments,           isHomeRelative: true),
        Rule(prefix: "~/Desktop",                                          category: .userDesktop,             isHomeRelative: true),
        Rule(prefix: "~/Downloads",                                        category: .userDownloads,           isHomeRelative: true),
        Rule(prefix: "~/Movies",                                           category: .userMovies,              isHomeRelative: true),
        Rule(prefix: "~/Music",                                            category: .userMusic,               isHomeRelative: true),
        Rule(prefix: "~/Pictures",                                         category: .userPictures,            isHomeRelative: true),
        Rule(prefix: "~",                                                  category: .userHomeOther,           isHomeRelative: true),

        // System
        Rule(prefix: "/Applications",                                      category: .applications,            isHomeRelative: false),
        Rule(prefix: "/private/var/folders",                               category: .temporary,               isHomeRelative: false),
        Rule(prefix: "/private/tmp",                                       category: .temporary,               isHomeRelative: false),
        Rule(prefix: "/tmp",                                               category: .temporary,               isHomeRelative: false),
        Rule(prefix: "/var/folders",                                       category: .temporary,               isHomeRelative: false),
        Rule(prefix: "/System",                                            category: .systemReadOnly,          isHomeRelative: false),
        Rule(prefix: "/usr",                                               category: .systemReadOnly,          isHomeRelative: false),
        Rule(prefix: "/Library",                                           category: .systemReadOnly,          isHomeRelative: false)
    ]
}
