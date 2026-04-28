import Foundation

/// A resolved reference to an `.app` bundle on disk plus the small set of
/// fields we cache from `Info.plist` so we don't reread the plist on every UI tick.
public struct AppBundle: Codable, Hashable, Sendable {
    public let url: URL
    public let bundleID: String?
    public let bundleName: String?
    public let bundleVersion: String?
    public let executableURL: URL
    public let architectures: [String]   // e.g. ["arm64", "x86_64"]
    public let minimumSystemVersion: String?

    public init(
        url: URL,
        bundleID: String?,
        bundleName: String?,
        bundleVersion: String?,
        executableURL: URL,
        architectures: [String],
        minimumSystemVersion: String?
    ) {
        self.url = url
        self.bundleID = bundleID
        self.bundleName = bundleName
        self.bundleVersion = bundleVersion
        self.executableURL = executableURL
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// Resolve the executable URL from the bundle. Falls back to "Contents/MacOS/<bundleName>"
    /// when CFBundleExecutable is missing or the file pointed to by it doesn't exist.
    public static func resolve(bundleURL: URL) throws -> AppBundle {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleURL.path) else {
            throw AppBundleError.notFound(bundleURL)
        }
        guard bundleURL.pathExtension == "app" else {
            throw AppBundleError.notAnApp(bundleURL)
        }

        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let plistData = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] ?? [:]

        let bundleID = plist["CFBundleIdentifier"] as? String
        let bundleName = (plist["CFBundleName"] as? String)
            ?? (plist["CFBundleDisplayName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let bundleVersion = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
        let minimumSystemVersion = plist["LSMinimumSystemVersion"] as? String

        let macOSDir = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let executableName = (plist["CFBundleExecutable"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let candidate = macOSDir.appendingPathComponent(executableName)
        let executableURL: URL
        if fm.fileExists(atPath: candidate.path) {
            executableURL = candidate
        } else {
            // Fallback: pick the first executable Mach-O in Contents/MacOS.
            let contents = (try? fm.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil)) ?? []
            guard let any = contents.first else {
                throw AppBundleError.executableMissing(bundleURL)
            }
            executableURL = any
        }

        let archs = (try? MachOInspector.architectures(of: executableURL)) ?? []

        return AppBundle(
            url: bundleURL,
            bundleID: bundleID,
            bundleName: bundleName,
            bundleVersion: bundleVersion,
            executableURL: executableURL,
            architectures: archs,
            minimumSystemVersion: minimumSystemVersion
        )
    }
}

public enum AppBundleError: Error, LocalizedError {
    case notFound(URL)
    case notAnApp(URL)
    case executableMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let u):         return "No such file: \(u.path)"
        case .notAnApp(let u):         return "Not an .app bundle: \(u.path)"
        case .executableMissing(let u):return "Bundle is missing Contents/MacOS/<exec>: \(u.path)"
        }
    }
}
