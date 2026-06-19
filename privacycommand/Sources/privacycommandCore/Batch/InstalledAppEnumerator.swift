import Foundation

/// Discovers `.app` bundles on disk so batch mode can analyse many apps at
/// once. Deliberately dependency-free and AppKit-free so it runs from Core,
/// the CLI, and tests — the GUI just feeds the resulting URLs to
/// `BatchAnalyzer`.
///
/// The walk never descends *into* a bundle once found: an `.app` is a leaf,
/// not a directory to keep recursing through, otherwise we'd pick up every
/// embedded helper app and XPC service as if it were an installed program.
public enum InstalledAppEnumerator {

    /// Bundle-shaped extensions we treat as leaves — once we see one we
    /// record it (if it's an `.app`) and stop descending. Recursing inside a
    /// `.app`/`.framework`/`.bundle` would surface embedded components as
    /// top-level apps.
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "xpc",
        "appex", "kext", "qlgenerator", "mdimporter", "prefpane"
    ]

    /// The default scan locations: user-facing app folders. Apple's own
    /// system apps live under `/System/Applications`; they're all platform
    /// binaries with little signal, so they're opt-in via `includeSystem`.
    public static func defaultRoots(includeSystem: Bool = false) -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        roots.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true))
        if includeSystem {
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
        }
        return roots.filter { isDirectory($0) }
    }

    /// Enumerate `.app` bundles under the given roots, descending at most
    /// `maxDepth` directory levels into non-bundle folders (so we catch
    /// `/Applications/Utilities/…` and vendor sub-folders without walking the
    /// whole disk). Results are de-duplicated by resolved path and sorted by
    /// name for stable display.
    public static func appBundles(in roots: [URL], maxDepth: Int = 2) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for root in roots {
            collect(in: root, depth: 0, maxDepth: maxDepth, seen: &seen, out: &out)
        }
        return sortByName(out)
    }

    /// Enumerate `.app` bundles anywhere beneath a user-chosen folder. This is
    /// the Shift-click "pick a folder" path — fully recursive (no depth cap)
    /// but still treating bundles as leaves.
    public static func appBundles(inFolder folder: URL) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        collect(in: folder, depth: 0, maxDepth: .max, seen: &seen, out: &out)
        return sortByName(out)
    }

    // MARK: - Walk

    private static func collect(in dir: URL,
                                depth: Int,
                                maxDepth: Int,
                                seen: inout Set<String>,
                                out: inout [URL]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if ext == "app" {
                let resolved = entry.resolvingSymlinksInPath().path
                if seen.insert(resolved).inserted {
                    out.append(entry)
                }
                continue   // an .app is a leaf — never descend into it
            }
            // Any other bundle type is a leaf we don't care about; skip it
            // entirely so we don't recurse into framework/plugin internals.
            if bundleExtensions.contains(ext) { continue }

            guard depth < maxDepth else { continue }
            // Resolve symlinks for the directory check but recurse using the
            // original URL so reported app paths stay where the user sees them.
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                collect(in: entry, depth: depth + 1, maxDepth: maxDepth, seen: &seen, out: &out)
            }
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func sortByName(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }
}
