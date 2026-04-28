import Foundation

/// Audits a Mach-O's `LC_RPATH` load commands for dylib-hijacking surface.
///
/// **The attack.** When the dynamic loader resolves an `@rpath/...` install
/// name, it walks every directory listed in `LC_RPATH` until it finds a
/// matching dylib. If any of those directories is **user-writable** (or
/// has `@executable_path` resolving to a user-writable location), an
/// attacker can drop a malicious dylib there and the loader will load it
/// in preference to the legitimate one.
///
/// **What we report.**
///   * The list of rpath entries.
///   * Whether each one resolves to a user-writable path on the *current*
///     system (we do this dynamically, not at static-analysis time).
///   * A verdict: hijackable / suspicious / fine.
public enum RPathAuditor {

    public static func audit(executable url: URL) -> RPathAudit {
        let machO = MachOInspector.loadCommands(of: url)
        let bundleRoot = bundleRootFromExecutable(url)
        var entries: [RPathAudit.Entry] = []
        for raw in machO.rpaths {
            let resolved = resolveRPath(raw, executableURL: url, bundleRoot: bundleRoot)
            let writable = resolved.flatMap { isUserWritable(at: $0) } ?? false
            entries.append(RPathAudit.Entry(
                raw: raw, resolvedPath: resolved?.path,
                isUserWritable: writable,
                kind: classify(raw: raw, resolved: resolved, writable: writable)
            ))
        }
        return RPathAudit(entries: entries, dylibs: machO.dylibs)
    }

    // MARK: - Resolution

    private static func resolveRPath(_ raw: String,
                                     executableURL: URL,
                                     bundleRoot: URL?) -> URL? {
        // Substitute the dyld-recognised tokens.
        var s = raw
        if s.hasPrefix("@executable_path") {
            s = s.replacingOccurrences(of: "@executable_path",
                                       with: executableURL.deletingLastPathComponent().path)
        }
        if s.hasPrefix("@loader_path") {
            // For the main executable, @loader_path == @executable_path.
            s = s.replacingOccurrences(of: "@loader_path",
                                       with: executableURL.deletingLastPathComponent().path)
        }
        // @rpath is recursive — dyld replaces @rpath with each LC_RPATH and
        // tries again. We don't follow that loop here; just report the raw.
        guard !s.contains("@rpath") else { return nil }
        return URL(fileURLWithPath: s).standardizedFileURL
    }

    private static func isUserWritable(at url: URL) -> Bool {
        let path = url.path
        // FileManager.isWritableFile checks current process's effective UID;
        // for our purposes, "writable by the current user" is what we want
        // to flag — that's exactly the threat model.
        return FileManager.default.isWritableFile(atPath: path)
            && !path.hasPrefix("/System/")
            && !path.hasPrefix("/usr/lib/")
    }

    private static func classify(raw: String, resolved: URL?, writable: Bool) -> RPathAudit.Entry.Kind {
        if writable { return .hijackable }
        if raw.hasPrefix("/Users/") || raw.contains("$HOME") { return .hijackable }
        if raw.hasPrefix("@executable_path/") || raw.hasPrefix("@loader_path/") { return .relative }
        if raw.hasPrefix("/usr/lib") || raw.hasPrefix("/System/") { return .system }
        return .absolute
    }

    private static func bundleRootFromExecutable(_ url: URL) -> URL? {
        // Heuristic: walk up until we find a directory ending in ".app".
        var current = url
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            if parent.pathExtension == "app" { return parent }
            current = parent
        }
        return nil
    }
}

// MARK: - Public types

public struct RPathAudit: Sendable, Hashable, Codable {
    public let entries: [Entry]
    /// All linked dylib install names — useful for telling the user "here's
    /// what this binary links against" without shelling out to `otool -L`.
    public let dylibs: [String]

    public init(entries: [Entry] = [], dylibs: [String] = []) {
        self.entries = entries
        self.dylibs = dylibs
    }

    public static let empty = RPathAudit()

    public var hijackableCount: Int { entries.filter { $0.kind == .hijackable }.count }

    public struct Entry: Sendable, Hashable, Codable, Identifiable {
        public var id: String { raw }
        public let raw: String
        public let resolvedPath: String?
        public let isUserWritable: Bool
        public let kind: Kind

        public enum Kind: String, Sendable, Hashable, Codable {
            case relative      // @executable_path / @loader_path - resolves inside the bundle
            case system        // under /usr/lib or /System
            case absolute      // any other absolute path that's not user-writable
            case hijackable    // user-writable - dylib hijacking surface
        }
    }
}
