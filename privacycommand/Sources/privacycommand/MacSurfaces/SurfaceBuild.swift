#if os(macOS)
import Foundation

/// The version line and build provenance for About, read from the Info.plist
/// keys that the versioning standard stamps at build time.
public struct SurfaceBuild: Sendable, Equatable {
    public let marketingVersion: String
    public let buildNumber: String
    public let sha: String?
    public let branch: String?
    public let channel: String
    public let isDirty: Bool
    public let dirtyFiles: Int
    public let isTagged: Bool
    public let copyright: String?

    public init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String, !text.isEmpty, text != "unknown" else { return nil }
            return text
        }
        marketingVersion = value("CFBundleShortVersionString") ?? "0.0.0"
        buildNumber = value("CFBundleVersion") ?? "0"
        sha = value("BuildSHA")
        branch = value("BuildBranch")
        channel = value("BuildChannel") ?? "unknown"
        isDirty = value("BuildDirty") == "YES"
        dirtyFiles = Int(value("BuildDirtyFiles") ?? "") ?? 0
        isTagged = value("BuildTagged") == "YES"
        copyright = value("NSHumanReadableCopyright")
    }

    public static let current = SurfaceBuild(info: Bundle.main.infoDictionary ?? [:])

    /// A clean tree on a release tag, built for release.
    public var isRelease: Bool { channel == "release" && isTagged && !isDirty }

    public var versionLine: String { "Version \(marketingVersion) (\(buildNumber))" }

    /// Commit, branch and dirty state. Nil on a release build, which shows
    /// nothing about the repository.
    public var provenanceLine: String? {
        guard !isRelease else { return nil }
        var parts = [sha, branch].compactMap { $0 }
        if isDirty {
            parts.append("\(dirtyFiles) uncommitted change\(dirtyFiles == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "built from Xcode, no commit recorded" : parts.joined(separator: " · ")
    }
}
#endif
