import Foundation

/// Inspects an app's sandbox container at `~/Library/Containers/<bundle-id>/`.
///
/// Only sandboxed apps get a container, and the container is the **only**
/// place a sandboxed app may write outside of explicitly-granted user paths.
/// Walking it gives a precise answer to "what does this app actually keep
/// on my machine, right now?" — distinct from anything the static or
/// dynamic analyses report.
public enum SandboxContainerInspector {

    public static func inspect(bundle: AppBundle) -> SandboxContainerInfo {
        guard let bid = bundle.bundleID, !bid.isEmpty else {
            return SandboxContainerInfo(state: .noBundleID)
        }
        let fm = FileManager.default
        let containerURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bid)", isDirectory: true)

        guard fm.fileExists(atPath: containerURL.path) else {
            return SandboxContainerInfo(state: .notSandboxed, container: containerURL)
        }

        let dataURL = containerURL.appendingPathComponent("Data", isDirectory: true)
        let documentsURL = dataURL.appendingPathComponent("Documents", isDirectory: true)
        let cachesURL = dataURL.appendingPathComponent("Library/Caches", isDirectory: true)
        let appSupportURL = dataURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        let prefsURL = dataURL.appendingPathComponent("Library/Preferences", isDirectory: true)
        let tmpURL = dataURL.appendingPathComponent("tmp", isDirectory: true)

        let dirs = [
            (SandboxContainerInfo.Subdir.documents, documentsURL),
            (.caches, cachesURL),
            (.applicationSupport, appSupportURL),
            (.preferences, prefsURL),
            (.tmp, tmpURL)
        ].compactMap { (kind, url) -> SandboxContainerInfo.Directory? in
            guard fm.fileExists(atPath: url.path) else { return nil }
            let (size, count) = totalSize(of: url)
            return SandboxContainerInfo.Directory(
                kind: kind, url: url,
                totalBytes: size, fileCount: count)
        }

        let totalBytes = dirs.reduce(0) { $0 + $1.totalBytes }
        let totalFiles = dirs.reduce(0) { $0 + $1.fileCount }

        return SandboxContainerInfo(
            state: .sandboxed,
            container: containerURL,
            directories: dirs,
            totalBytes: totalBytes,
            totalFileCount: totalFiles)
    }

    private static func totalSize(of url: URL) -> (Int64, Int) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
                                         options: []) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var count = 0
        for case let f as URL in walker {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? 0)
                count += 1
            }
        }
        return (total, count)
    }
}

// MARK: - Public types

public struct SandboxContainerInfo: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case sandboxed
        case notSandboxed   // bundleID known, no container — app isn't sandboxed (or isn't installed)
        case noBundleID
    }

    public let state: State
    public let container: URL?
    public let directories: [Directory]
    public let totalBytes: Int64
    public let totalFileCount: Int

    public init(state: State,
                container: URL? = nil,
                directories: [Directory] = [],
                totalBytes: Int64 = 0,
                totalFileCount: Int = 0) {
        self.state = state
        self.container = container
        self.directories = directories
        self.totalBytes = totalBytes
        self.totalFileCount = totalFileCount
    }

    public enum Subdir: String, Sendable, Hashable, Codable, CaseIterable {
        case documents          = "Documents"
        case caches             = "Library/Caches"
        case applicationSupport = "Library/Application Support"
        case preferences        = "Library/Preferences"
        case tmp                = "tmp"

        public var icon: String {
            switch self {
            case .documents:          return "doc.text"
            case .caches:             return "externaldrive.badge.timemachine"
            case .applicationSupport: return "shippingbox"
            case .preferences:        return "switch.2"
            case .tmp:                return "clock.badge.exclamationmark"
            }
        }

        public var description: String {
            switch self {
            case .documents:          return "User-created content. The 'real' data the app holds for the user."
            case .caches:             return "Disposable cache files. Safe to delete; will be re-fetched."
            case .applicationSupport: return "App-managed data files (databases, downloaded resources)."
            case .preferences:        return "Per-user defaults plist."
            case .tmp:                return "Temporary files. Cleared by macOS periodically."
            }
        }
    }

    public struct Directory: Sendable, Hashable, Identifiable {
        public var id: URL { url }
        public let kind: Subdir
        public let url: URL
        public let totalBytes: Int64
        public let fileCount: Int
    }

    public var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}
