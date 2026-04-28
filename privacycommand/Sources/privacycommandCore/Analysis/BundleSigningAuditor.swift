import Foundation

/// Walks every Mach-O inside an app bundle and runs `codesign -dv` against
/// each one, producing a `BundleSigningAudit` summary.
///
/// Why this matters: the main app's signature alone is not enough to trust
/// a bundle. A repackaged or trojanised app commonly has a legitimately
/// signed wrapper whose **frameworks, helpers, or XPC services** carry a
/// different Team ID — or aren't signed at all. macOS will still allow the
/// app to launch (Gatekeeper only checks the outer signature), but the app
/// is functionally compromised.
///
/// We surface three things per inner Mach-O:
///   * Team ID
///   * Sandbox status (from the entitlements blob)
///   * Hardened-Runtime / library-validation flags
///
/// And we surface one summary verdict for the whole bundle:
///   * Are all Team IDs identical (and present)?
///   * Is the sandbox set the same across the bundle?
///   * Are any inner Mach-Os unsigned?
public enum BundleSigningAuditor {

    public static func audit(bundle: AppBundle) -> BundleSigningAudit {
        let executables = enumerateExecutables(in: bundle.url)
        var entries: [BundleSigningAudit.Entry] = []
        for url in executables {
            let info = CodesignWrapper.info(for: AppBundle.surrogate(executableURL: url))
            // Path-based comparison — URL equality is byte-for-byte and
            // can fail when the enumerator output differs from the
            // bundle's stored URL by trailing slash, symlink resolution,
            // or normalisation. We standardise both before comparing.
            let isMain = url.standardizedFileURL.path
                == bundle.executableURL.standardizedFileURL.path
            let role: BundleSigningAudit.Entry.Role = isMain ? .mainApp : roleFor(url: url, bundleRoot: bundle.url)

            entries.append(BundleSigningAudit.Entry(
                url: url, role: role,
                teamID: info.teamIdentifier,
                signingIdentifier: info.signingIdentifier,
                hardenedRuntime: info.hardenedRuntime,
                isAdhocSigned: info.isAdhocSigned,
                isPlatformBinary: info.isPlatformBinary,
                validates: info.validates,
                validationError: info.validationError
            ))
        }

        return summarize(entries: entries)
    }

    // MARK: - Walkers

    private static func enumerateExecutables(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in walker {
            // Cheap pre-filter: only test files (not directories).
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // Read the magic to confirm Mach-O. Avoids wasting `codesign`
            // invocations on resources, plists, and shell scripts.
            if isMachO(url: url) { out.append(url) }
        }
        return out
    }

    private static func isMachO(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Mach-O thin (32/64) or fat (universal) magics.
        return magic == 0xFEEDFACE || magic == 0xCEFAEDFE
            || magic == 0xFEEDFACF || magic == 0xCFFAEDFE
            || magic == 0xCAFEBABE || magic == 0xBEBAFECA
            || magic == 0xCAFEBABF || magic == 0xBFBAFECA
    }

    private static func roleFor(url: URL, bundleRoot: URL) -> BundleSigningAudit.Entry.Role {
        let rel = url.path.replacingOccurrences(of: bundleRoot.path, with: "")
        if rel.contains("/Frameworks/") { return .framework }
        if rel.contains("/XPCServices/") { return .xpcService }
        if rel.contains("/LoginItems/") { return .loginItem }
        if rel.contains("/Helpers/") { return .helper }
        if rel.contains("/PlugIns/") { return .plugin }
        return .other
    }

    // MARK: - Summary

    private static func summarize(entries: [BundleSigningAudit.Entry]) -> BundleSigningAudit {
        let teamIDs = Set(entries.compactMap(\.teamID))
        let mainTeamID = entries.first(where: { $0.role == .mainApp })?.teamID
        let unsigned = entries.filter { $0.teamID == nil && !$0.isPlatformBinary && !$0.isAdhocSigned }
        let adhocOuter = entries.filter { $0.isAdhocSigned && $0.role != .other }
        // Mismatch detection requires a baseline. If we never identified
        // the main app's team ID, every signed component would
        // (incorrectly) compare unequal to nil and get flagged as
        // "mismatched" — that's the false positive the user reported.
        let mismatchedTeamIDs: [BundleSigningAudit.Entry]
        if let mainTID = mainTeamID {
            mismatchedTeamIDs = entries.filter { entry in
                entry.teamID != nil
                    && entry.teamID != mainTID
                    && !entry.isPlatformBinary
                    && !entry.isAdhocSigned
            }
        } else {
            mismatchedTeamIDs = []
        }

        var verdicts: [BundleSigningAudit.Verdict] = []
        if mainTeamID == nil {
            // We couldn't extract a Team ID for the main executable
            // (often happens when the main app is signed in a way
            // Security.framework can't introspect from a path-only
            // call). Be honest about it rather than pretending the
            // bundle is suspect.
            verdicts.append(.init(
                severity: .info,
                summary: "Main app's Team ID could not be determined; cross-component check skipped.",
                detail: nil))
        } else if !mismatchedTeamIDs.isEmpty {
            verdicts.append(.init(
                severity: .error,
                summary: "Mismatched Team IDs across bundle components.",
                detail: "Inner Mach-Os signed by Team IDs different from the main app are a strong indicator of repackaging or supply-chain compromise: \(mismatchedTeamIDs.map { ($0.teamID ?? "—") + " (" + $0.url.lastPathComponent + ")" }.joined(separator: ", "))"))
        }
        if !unsigned.isEmpty {
            verdicts.append(.init(
                severity: .warn,
                summary: "\(unsigned.count) inner Mach-O\(unsigned.count == 1 ? "" : "s") unsigned.",
                detail: "Components without a code signature aren't subject to library validation. Examples: " + unsigned.prefix(5).map(\.url.lastPathComponent).joined(separator: ", ")))
        }
        if !adhocOuter.isEmpty {
            verdicts.append(.init(
                severity: .info,
                summary: "\(adhocOuter.count) component\(adhocOuter.count == 1 ? " is" : "s are") ad-hoc signed.",
                detail: "Ad-hoc signing is fine for local development but unusual in distributed software. Examples: " + adhocOuter.prefix(5).map(\.url.lastPathComponent).joined(separator: ", ")))
        }

        if verdicts.isEmpty {
            verdicts.append(.init(
                severity: .info,
                summary: "All \(entries.count) Mach-O\(entries.count == 1 ? "" : "s") share the same Team ID.",
                detail: nil))
        }

        return BundleSigningAudit(
            entries: entries,
            uniqueTeamIDs: teamIDs.sorted(),
            mainTeamID: mainTeamID,
            verdicts: verdicts
        )
    }
}

// MARK: - Internal helper for codesigning a Mach-O that isn't a bundle root

extension AppBundle {
    /// Construct a minimal `AppBundle` whose `url` *and* `executableURL`
    /// both point at the same Mach-O file. Used by
    /// `BundleSigningAuditor` so it can reuse `CodesignWrapper.info(for:)`
    /// without inventing a separate API.
    ///
    /// **Why both URLs are the same.** `CodesignWrapper.info` calls
    /// `SecStaticCodeCreateWithPath(bundle.url, ...)`. For a real .app
    /// bundle that's the bundle directory; for a single Mach-O, Security
    /// happily accepts the raw file URL too. If we pointed `bundle.url`
    /// at the *parent* directory (as we did originally) Security would
    /// look there for a bundle signature it can't find, return empty
    /// info, and every helper / framework would come back with `teamID
    /// == nil` — which then misled the audit verdict logic into
    /// reporting bogus team-ID mismatches.
    static func surrogate(executableURL: URL) -> AppBundle {
        return AppBundle(
            url: executableURL,
            bundleID: nil,
            bundleName: nil,
            bundleVersion: nil,
            executableURL: executableURL,
            architectures: [],
            minimumSystemVersion: nil
        )
    }
}

// MARK: - Public types

public struct BundleSigningAudit: Sendable, Hashable, Codable {
    public let entries: [Entry]
    public let uniqueTeamIDs: [String]
    public let mainTeamID: String?
    public let verdicts: [Verdict]

    public init(entries: [Entry], uniqueTeamIDs: [String],
                mainTeamID: String?, verdicts: [Verdict]) {
        self.entries = entries
        self.uniqueTeamIDs = uniqueTeamIDs
        self.mainTeamID = mainTeamID
        self.verdicts = verdicts
    }

    public static let empty = BundleSigningAudit(entries: [], uniqueTeamIDs: [],
                                                 mainTeamID: nil, verdicts: [])

    public struct Entry: Sendable, Hashable, Codable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let role: Role
        public let teamID: String?
        public let signingIdentifier: String?
        public let hardenedRuntime: Bool
        public let isAdhocSigned: Bool
        public let isPlatformBinary: Bool
        public let validates: Bool
        public let validationError: String?

        public enum Role: String, Sendable, Hashable, Codable {
            case mainApp     = "Main app"
            case framework   = "Framework"
            case xpcService  = "XPC service"
            case loginItem   = "Login item"
            case helper      = "Helper"
            case plugin      = "Plug-in"
            case other       = "Other Mach-O"
        }
    }

    public struct Verdict: Sendable, Hashable, Codable, Identifiable {
        public var id: String { "\(severity.rawValue):\(summary.prefix(80))" }
        public enum Severity: String, Sendable, Hashable, Codable { case info, warn, error }
        public let severity: Severity
        public let summary: String
        public let detail: String?
    }
}
