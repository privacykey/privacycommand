import Foundation

/// Enumerates an app's bundled **app extensions** (`.appex` in `PlugIns/`) as
/// first-class extension-points, reading each one's `NSExtensionPointIdentifier`
/// and flagging the high-privilege kinds.
///
/// **Why this is its own scanner.** The endpoint/secret scans already reach
/// *into* `.appex` binaries (they're part of the embedded-Mach-O sweep), but
/// the extensions themselves were never listed with what they actually *are*.
/// That matters: a Network Extension sees and can filter all of the device's
/// traffic; an Endpoint Security client sees every process/file event; a File
/// Provider sees the user's files. Those run with elevated system access and
/// persist independently of the host app, so surfacing them — by extension
/// point — is core to being a "source of truth".
public enum AppExtensionScanner {

    public static func scan(bundle: AppBundle) -> [AppExtensionRef] {
        // Standard macOS bundles: Contents/PlugIns. Flat iOS bundles: PlugIns
        // at the root. Scan both and de-duplicate by path.
        let dirs = [
            bundle.contentsURL.appendingPathComponent("PlugIns", isDirectory: true),
            bundle.url.appendingPathComponent("PlugIns", isDirectory: true)
        ]
        var byPath: [String: AppExtensionRef] = [:]
        for dir in dirs {
            for ref in scan(pluginsDir: dir) { byPath[ref.url.path] = ref }
        }
        return byPath.values.sorted { $0.url.path < $1.url.path }
    }

    /// Directory-rooted core (testable without an `AppBundle`).
    static func scan(pluginsDir: URL) -> [AppExtensionRef] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginsDir.path) else { return [] }
        let appexes = ((try? fm.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "appex" }
        return appexes
            .map { parse(infoPlist: readInfoPlist(at: $0) ?? [:], url: $0) }
            .sorted { $0.url.path < $1.url.path }
    }

    static func readInfoPlist(at appex: URL) -> [String: Any]? {
        let primary = appex.appendingPathComponent("Contents/Info.plist")
        let flat = appex.appendingPathComponent("Info.plist")
        let candidate = FileManager.default.fileExists(atPath: primary.path) ? primary : flat
        guard let data = try? Data(contentsOf: candidate),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist
    }

    static func parse(infoPlist: [String: Any], url: URL) -> AppExtensionRef {
        let bundleID = infoPlist["CFBundleIdentifier"] as? String
        let version = (infoPlist["CFBundleShortVersionString"] as? String)
            ?? (infoPlist["CFBundleVersion"] as? String)
        let nsext = infoPlist["NSExtension"] as? [String: Any]
        let pointID = nsext?["NSExtensionPointIdentifier"] as? String
        let (display, high) = classify(pointID)
        return AppExtensionRef(
            url: url, bundleID: bundleID, version: version,
            extensionPointID: pointID, extensionPointDisplay: display,
            isHighPrivilege: high)
    }

    /// Map an extension-point identifier to a friendly name + whether it's a
    /// high-privilege kind (elevated system access).
    static func classify(_ pointID: String?) -> (display: String, highPrivilege: Bool) {
        guard let p = pointID else { return ("Unknown extension", false) }
        let high = highPrivilegePrefixes.contains { p == $0 || p.hasPrefix($0 + ".") || p.hasPrefix($0) }
        return (displayNames[p] ?? p, high)
    }

    /// Extension-point families that run with elevated, system-wide access.
    private static let highPrivilegePrefixes: [String] = [
        "com.apple.networkextension",     // VPN / proxy / content filter — sees all traffic
        "com.apple.endpoint-security",    // ES client — sees all process/file events
        "com.apple.system-extension",     // system extension host
        "com.apple.content-filter",       // network content filter
        "com.apple.fileprovider"          // File Provider — sees user files
    ]

    private static let displayNames: [String: String] = [
        "com.apple.share-services":                         "Share extension",
        "com.apple.widgetkit-extension":                    "Widget",
        "com.apple.widget-extension":                       "Widget (legacy Today)",
        "com.apple.fileprovider-nonui":                     "File Provider",
        "com.apple.fileprovider-actionsui":                 "File Provider action",
        "com.apple.FinderSync":                             "Finder Sync",
        "com.apple.Safari.web-extension":                   "Safari web extension",
        "com.apple.Safari.extension":                       "Safari App Extension",
        "com.apple.Safari.content-blocker":                 "Safari content blocker",
        "com.apple.quicklook.preview":                      "Quick Look preview",
        "com.apple.quicklook.thumbnail":                    "Quick Look thumbnail",
        "com.apple.spotlight.import":                       "Spotlight importer",
        "com.apple.usernotifications.content-extension":    "Notification content",
        "com.apple.usernotifications.service":              "Notification service",
        "com.apple.intents-service":                        "Siri / Shortcuts (Intents)",
        "com.apple.intents-ui-service":                     "Siri / Shortcuts UI",
        "com.apple.AudioUnit-UI":                           "Audio Unit UI",
        "com.apple.AudioUnit":                              "Audio Unit",
        "com.apple.networkextension.packet-tunnel":         "Network Extension (VPN packet tunnel)",
        "com.apple.networkextension.app-proxy":             "Network Extension (app proxy)",
        "com.apple.networkextension.filter-data":           "Network Extension (content filter)",
        "com.apple.networkextension.filter-control":        "Network Extension (filter control)",
        "com.apple.networkextension.dns-proxy":             "Network Extension (DNS proxy)",
        "com.apple.endpoint-security.client":               "Endpoint Security client"
    ]
}

public struct AppExtensionRef: Sendable, Hashable, Codable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let bundleID: String?
    public let version: String?
    public let extensionPointID: String?
    public let extensionPointDisplay: String
    public let isHighPrivilege: Bool

    public init(url: URL, bundleID: String?, version: String?,
                extensionPointID: String?, extensionPointDisplay: String,
                isHighPrivilege: Bool) {
        self.url = url; self.bundleID = bundleID; self.version = version
        self.extensionPointID = extensionPointID
        self.extensionPointDisplay = extensionPointDisplay
        self.isHighPrivilege = isHighPrivilege
    }
}
