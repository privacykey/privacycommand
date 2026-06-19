import Foundation

/// A resolved reference to an `.app` bundle on disk plus the small set of
/// fields we cache from `Info.plist` so we don't reread the plist on every UI tick.
public struct AppBundle: Codable, Hashable, Sendable {
    /// On-disk bundle layout. macOS apps use the `standard` layout
    /// (`Contents/Info.plist`, `Contents/MacOS/<exec>`). iPhone/iPad apps
    /// running on Apple Silicon ship a `flat` bundle (Info.plist + the
    /// executable directly at the bundle root) wrapped inside an outer shell.
    public enum Layout: String, Codable, Sendable {
        case standard
        case flat
    }

    /// The platform the bundle targets. `iOS` covers iPhone/iPad apps made
    /// available on the Mac via the App Store ("Designed for iPad/iPhone").
    public enum Platform: String, Codable, Sendable {
        case macOS
        case iOS

        public var label: String {
            switch self {
            case .macOS: return "macOS"
            case .iOS:   return "iPhone/iPad app"
            }
        }
    }

    public let url: URL
    public let bundleID: String?
    public let bundleName: String?
    public let bundleVersion: String?
    public let executableURL: URL
    public let architectures: [String]   // e.g. ["arm64", "x86_64"]
    public let minimumSystemVersion: String?
    public let layout: Layout
    public let platform: Platform

    public init(
        url: URL,
        bundleID: String?,
        bundleName: String?,
        bundleVersion: String?,
        executableURL: URL,
        architectures: [String],
        minimumSystemVersion: String?,
        layout: Layout = .standard,
        platform: Platform = .macOS
    ) {
        self.url = url
        self.bundleID = bundleID
        self.bundleName = bundleName
        self.bundleVersion = bundleVersion
        self.executableURL = executableURL
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.layout = layout
        self.platform = platform
    }

    // MARK: - Layout-aware locations

    /// Directory that holds the bundle's metadata, resources, and nested code.
    /// `Contents/` for a standard macOS bundle; the bundle root itself for a
    /// flat iOS bundle.
    public var contentsURL: URL {
        layout == .standard
            ? url.appendingPathComponent("Contents", isDirectory: true)
            : url
    }

    /// Location of `Info.plist` for this bundle's layout.
    public var infoPlistURL: URL {
        contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    }

    /// Directory bundled frameworks live in (may not exist).
    public var frameworksURL: URL {
        contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
    }

    /// Directory non-code resources live in. Standard bundles use
    /// `Contents/Resources`; flat iOS bundles keep resources at the root.
    public var resourcesURL: URL {
        layout == .standard
            ? contentsURL.appendingPathComponent("Resources", isDirectory: true)
            : url
    }

    /// Canonical Mac App Store receipt location for this layout.
    public var masReceiptURL: URL {
        contentsURL
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case url, bundleID, bundleName, bundleVersion, executableURL
        case architectures, minimumSystemVersion, layout, platform
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        bundleName = try c.decodeIfPresent(String.self, forKey: .bundleName)
        bundleVersion = try c.decodeIfPresent(String.self, forKey: .bundleVersion)
        executableURL = try c.decode(URL.self, forKey: .executableURL)
        architectures = try c.decodeIfPresent([String].self, forKey: .architectures) ?? []
        minimumSystemVersion = try c.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
        // Older snapshots predate these — default to a standard macOS bundle.
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .standard
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .macOS
    }

    // MARK: - Resolution

    /// Resolve a `.app` on disk into an `AppBundle`, auto-detecting the layout.
    ///
    /// Three shapes are recognised:
    /// 1. **Wrapped iOS/iPad app** — the outer `.app` contains a
    ///    `Wrapper/<App>.app` (a flat iOS bundle) plus a `WrappedBundle`
    ///    symlink. We redirect to and analyse the inner bundle.
    /// 2. **Standard macOS app** — `Contents/Info.plist` exists.
    /// 3. **Flat bundle pointed at directly** — `Info.plist` sits at the root
    ///    (e.g. the user selected the inner iOS bundle).
    public static func resolve(bundleURL: URL) throws -> AppBundle {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleURL.path) else {
            throw AppBundleError.notFound(bundleURL)
        }
        guard bundleURL.pathExtension == "app" else {
            throw AppBundleError.notAnApp(bundleURL)
        }

        // (1) iPhone/iPad app on Apple Silicon: redirect into the wrapped bundle.
        if let inner = wrappedInnerBundle(of: bundleURL, fm: fm) {
            return try resolveFlat(bundleURL: inner, platform: .iOS, fm: fm)
        }

        // (2) Standard macOS / Catalyst bundle.
        let standardPlist = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: standardPlist.path) {
            return try resolveStandard(bundleURL: bundleURL, fm: fm)
        }

        // (3) Flat bundle pointed at directly.
        let flatPlist = bundleURL.appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: flatPlist.path) {
            return try resolveFlat(bundleURL: bundleURL, platform: .iOS, fm: fm)
        }

        // No readable Info.plist in either layout. Distinguish "we can't read
        // it" (permissions) from "it isn't there".
        if !fm.isReadableFile(atPath: bundleURL.path) {
            throw AppBundleError.permissionDenied(bundleURL)
        }
        throw AppBundleError.unreadablePlist(bundleURL)
    }

    /// Locate the inner iOS bundle of a wrapped app, or nil if `outer` isn't a
    /// wrapped bundle. Prefers the `WrappedBundle` symlink Apple writes, then
    /// falls back to the first `.app` inside `Wrapper/`.
    private static func wrappedInnerBundle(of outer: URL, fm: FileManager) -> URL? {
        let link = outer.appendingPathComponent("WrappedBundle")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = dest.hasPrefix("/")
                ? URL(fileURLWithPath: dest)
                : outer.appendingPathComponent(dest).standardizedFileURL
            if resolved.pathExtension == "app",
               fm.fileExists(atPath: resolved.appendingPathComponent("Info.plist").path) {
                return resolved
            }
        }
        let wrapperDir = outer.appendingPathComponent("Wrapper", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: wrapperDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let entries = (try? fm.contentsOfDirectory(at: wrapperDir, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "app" }
    }

    /// Resolve a standard `Contents/`-layout macOS bundle.
    private static func resolveStandard(bundleURL: URL, fm: FileManager) throws -> AppBundle {
        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let plist = try readPlist(at: infoPlistURL, bundle: bundleURL)

        let macOSDir = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let executableName = (plist["CFBundleExecutable"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let executableURL = try resolveExecutable(
            named: executableName, in: macOSDir, bundle: bundleURL, fm: fm)

        return makeBundle(url: bundleURL, plist: plist,
                          executableURL: executableURL, layout: .standard, platform: .macOS)
    }

    /// Resolve a flat-layout bundle (iOS/iPadOS): `Info.plist` and the
    /// executable sit at the bundle root, with no `Contents/MacOS` directory.
    private static func resolveFlat(bundleURL: URL, platform: Platform, fm: FileManager) throws -> AppBundle {
        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
        let plist = try readPlist(at: infoPlistURL, bundle: bundleURL)

        let executableName = (plist["CFBundleExecutable"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let executableURL = try resolveExecutable(
            named: executableName, in: bundleURL, bundle: bundleURL, fm: fm,
            // For flat bundles the fallback scan must skip the directories and
            // metadata files that share the bundle root with the executable.
            excludingNames: ["Info.plist", "PkgInfo", "_CodeSignature", "Wrapper", "WrappedBundle"])

        return makeBundle(url: bundleURL, plist: plist,
                          executableURL: executableURL, layout: .flat, platform: platform)
    }

    // MARK: - Resolution helpers

    private static func readPlist(at url: URL, bundle: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
                throw AppBundleError.permissionDenied(bundle)
            }
            throw AppBundleError.unreadablePlist(bundle)
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw AppBundleError.unreadablePlist(bundle)
        }
        return plist
    }

    /// Find the named executable in `dir`, falling back to the first plausible
    /// file when `CFBundleExecutable` is missing or stale.
    private static func resolveExecutable(
        named name: String,
        in dir: URL,
        bundle: URL,
        fm: FileManager,
        excludingNames excluded: Set<String> = []
    ) throws -> URL {
        let candidate = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let fallback = contents.first { entry in
            guard !excluded.contains(entry.lastPathComponent) else { return false }
            if excluded.isEmpty { return true }  // Contents/MacOS: anything goes
            let vals = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            return vals?.isRegularFile ?? false
        }
        guard let executableURL = fallback else {
            throw AppBundleError.executableMissing(bundle)
        }
        return executableURL
    }

    private static func makeBundle(url: URL, plist: [String: Any],
                                   executableURL: URL, layout: Layout, platform: Platform) -> AppBundle {
        let bundleID = plist["CFBundleIdentifier"] as? String
        let bundleName = (plist["CFBundleName"] as? String)
            ?? (plist["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleVersion = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
        let minimumSystemVersion = plist["LSMinimumSystemVersion"] as? String
        let archs = (try? MachOInspector.architectures(of: executableURL)) ?? []

        return AppBundle(
            url: url,
            bundleID: bundleID,
            bundleName: bundleName,
            bundleVersion: bundleVersion,
            executableURL: executableURL,
            architectures: archs,
            minimumSystemVersion: minimumSystemVersion,
            layout: layout,
            platform: platform
        )
    }
}

public enum AppBundleError: Error, LocalizedError {
    case notFound(URL)
    case notAnApp(URL)
    case unreadablePlist(URL)
    case executableMissing(URL)
    case permissionDenied(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let u):          return "No such file: \(u.path)"
        case .notAnApp(let u):          return "Not an .app bundle: \(u.path)"
        case .unreadablePlist(let u):   return "Couldn't read Info.plist in \(u.lastPathComponent)."
        case .executableMissing(let u): return "Bundle has no readable executable: \(u.path)"
        case .permissionDenied(let u):  return "Permission denied reading \(u.lastPathComponent)."
        }
    }
}

/// A coarse, exportable reason an app scan didn't complete. Lets batch runs
/// group and explain failures instead of surfacing raw error strings.
public enum ScanFailureKind: String, Codable, Hashable, Sendable, CaseIterable {
    case notFound            // the path no longer exists
    case notAnApp            // not a .app bundle (e.g. a stray file)
    case unreadableMetadata  // Info.plist missing or corrupt
    case executableMissing   // no Mach-O to analyse
    case permissionDenied    // sandbox / SIP / POSIX permissions
    case unknown             // anything we couldn't classify

    /// Short label for a table cell or chip.
    public var label: String {
        switch self {
        case .notFound:           return "Missing"
        case .notAnApp:           return "Not an app"
        case .unreadableMetadata: return "No metadata"
        case .executableMissing:  return "No executable"
        case .permissionDenied:   return "No access"
        case .unknown:            return "Failed"
        }
    }

    /// Longer explanation for a tooltip.
    public var explanation: String {
        switch self {
        case .notFound:           return "The bundle wasn't where we expected — it may have been moved or deleted mid-scan."
        case .notAnApp:           return "This isn't a readable .app bundle."
        case .unreadableMetadata: return "The bundle's Info.plist is missing or corrupt, so it couldn't be parsed."
        case .executableMissing:  return "No Mach-O executable was found inside the bundle to analyse."
        case .permissionDenied:   return "The bundle couldn't be read — likely a permissions, sandbox, or System Integrity Protection restriction."
        case .unknown:            return "Static analysis couldn't complete for this bundle."
        }
    }

    /// Classify an arbitrary thrown error into a coarse reason.
    public static func classify(_ error: Error) -> ScanFailureKind {
        if let e = error as? AppBundleError {
            switch e {
            case .notFound:         return .notFound
            case .notAnApp:         return .notAnApp
            case .unreadablePlist:  return .unreadableMetadata
            case .executableMissing:return .executableMissing
            case .permissionDenied: return .permissionDenied
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return .permissionDenied
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError:                          return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:     return .notFound
            case NSFileReadCorruptFileError, NSPropertyListReadCorruptError:
                return .unreadableMetadata
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            let nested = classify(underlying)
            if nested != .unknown { return nested }
        }
        return .unknown
    }
}
