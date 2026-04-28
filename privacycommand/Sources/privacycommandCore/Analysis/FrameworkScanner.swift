import Foundation

public enum FrameworkScanner {

    public static func scan(bundle: AppBundle) -> (frameworks: [FrameworkRef],
                                                   loginItems: [BundleRef],
                                                   xpcServices: [BundleRef],
                                                   helpers: [BundleRef]) {
        let fm = FileManager.default
        let contents = bundle.url.appendingPathComponent("Contents", isDirectory: true)

        let frameworksDir = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let xpcDir = contents.appendingPathComponent("XPCServices", isDirectory: true)
        let loginDir = contents.appendingPathComponent("Library/LoginItems", isDirectory: true)
        let helpersDir = contents.appendingPathComponent("Helpers", isDirectory: true)

        let frameworks = listBundles(at: frameworksDir, ext: "framework").map { url -> FrameworkRef in
            let info = readBundleInfo(at: url)
            let cs = csTeamID(at: url)
            return FrameworkRef(
                url: url,
                bundleID: info.bundleID,
                version: info.version,
                teamID: cs.teamID,
                isAppleSigned: cs.isApple
            )
        }

        let xpcServices = listBundles(at: xpcDir, ext: "xpc").map { url in
            let info = readBundleInfo(at: url)
            let cs = csTeamID(at: url)
            return BundleRef(
                url: url, bundleID: info.bundleID, teamID: cs.teamID,
                isHelperApp: false, isXPCService: true, isLoginItem: false
            )
        }
        let loginItems = listBundles(at: loginDir, ext: "app").map { url in
            let info = readBundleInfo(at: url)
            let cs = csTeamID(at: url)
            return BundleRef(
                url: url, bundleID: info.bundleID, teamID: cs.teamID,
                isHelperApp: false, isXPCService: false, isLoginItem: true
            )
        }
        // Helpers may be apps or plain Mach-O binaries
        let helpers = ((try? fm.contentsOfDirectory(at: helpersDir, includingPropertiesForKeys: nil)) ?? [])
            .map { url -> BundleRef in
                let info = url.pathExtension == "app" ? readBundleInfo(at: url) : (bundleID: nil, version: nil)
                let cs = csTeamID(at: url)
                return BundleRef(
                    url: url, bundleID: info.bundleID, teamID: cs.teamID,
                    isHelperApp: true, isXPCService: false, isLoginItem: false
                )
            }

        return (frameworks, loginItems, xpcServices, helpers)
    }

    private static func listBundles(at dir: URL, ext: String) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readBundleInfo(at url: URL) -> (bundleID: String?, version: String?) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        let altPlistURL = url.appendingPathComponent("Resources/Info.plist") // frameworks
        let candidate = FileManager.default.fileExists(atPath: plistURL.path) ? plistURL : altPlistURL
        guard let data = try? Data(contentsOf: candidate),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return (nil, nil)
        }
        return (plist["CFBundleIdentifier"] as? String,
                (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String))
    }

    private static func csTeamID(at url: URL) -> (teamID: String?, isApple: Bool) {
        // Each nested bundle has its own signature; we read it via codesign for
        // simplicity (calling Security.framework on every framework would be
        // ideal but is more code than this is worth).
        let result = ProcessRunner.runSync(
            launchPath: "/usr/bin/codesign",
            arguments: ["-dvv", url.path],
            timeout: 8
        )
        let combined = result.stdout + "\n" + result.stderr
        var teamID: String?
        for line in combined.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                teamID = String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        let isApple = combined.contains("Authority=Software Signing")
                   || combined.contains("Authority=Apple Code Signing Certification Authority")
                   || combined.contains("Authority=Apple Mac OS Application Signing")
        return (teamID, isApple)
    }
}
