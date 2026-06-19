import Foundation

// MARK: - Signing status

/// A flattened code-signing verdict, derived from `CodeSigningInfo` +
/// `NotarizationStatus`, suitable for a single sortable table column.
public enum SigningStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case apple                 // Apple platform binary
    case developerIDNotarized  // Developer ID + notarized (the gold standard for non-MAS)
    case developerID           // Developer ID signed, not notarized
    case appStore              // signed leaf is Apple's, installed from the Mac App Store
    case signed                // signed but status otherwise unclear
    case adHoc                 // ad-hoc signature (no identity / Team ID)
    case unsigned              // not signed at all
    case invalid               // signature present but fails validation

    public var label: String {
        switch self {
        case .apple:                return "Apple"
        case .developerIDNotarized: return "Developer ID · Notarized"
        case .developerID:          return "Developer ID"
        case .appStore:             return "App Store"
        case .signed:               return "Signed"
        case .adHoc:                return "Ad-hoc"
        case .unsigned:             return "Unsigned"
        case .invalid:              return "Invalid signature"
        }
    }

    /// Sort/severity rank — trusted at the top, sketchy at the bottom — so the
    /// "Signing" column sorts in a meaningful order rather than alphabetically.
    public var rank: Int {
        switch self {
        case .apple:                return 0
        case .appStore:             return 1
        case .developerIDNotarized: return 2
        case .developerID:          return 3
        case .signed:               return 4
        case .adHoc:                return 5
        case .unsigned:             return 6
        case .invalid:              return 7
        }
    }

    /// Coarse tone for colouring the cell.
    public var isConcerning: Bool {
        switch self {
        case .adHoc, .unsigned, .invalid: return true
        default: return false
        }
    }
}

// MARK: - Architecture class

/// Coarse CPU-architecture bucket for an app's main executable. The headline
/// use is spotting Intel-only apps that will stop launching once Apple drops
/// Rosetta 2 (slated around the macOS 28 era) — `.intel` is that risk.
public enum ArchClass: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case universal       // ships both arm64 and x86_64 — future-proof
    case appleSilicon    // arm64(e) only — native, no Rosetta needed
    case intel           // x86_64 only — needs Rosetta 2; breaks when it's removed
    case other           // 32-bit / PPC / undetectable

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .universal:    return "Universal"
        case .appleSilicon: return "Apple Silicon"
        case .intel:        return "Intel only"
        case .other:        return "Other"
        }
    }

    /// Classify from the raw arch strings `MachOInspector` emits
    /// (`"arm64"` — which also covers arm64e — `"x86_64"`, `"i386"`, `"ppc"`).
    public static func classify(_ archs: [String]) -> ArchClass {
        let set = Set(archs)
        let hasArm = set.contains("arm64") || set.contains("arm64e")
        let hasIntel = set.contains("x86_64")
        if hasArm && hasIntel { return .universal }
        if hasArm { return .appleSilicon }
        if hasIntel { return .intel }
        return .other
    }
}

/// A categorical filter over update mechanism, including the "no detectable
/// updater" case (which a plain `Kind` can't express).
public enum UpdateFilter: Hashable, Sendable {
    case none                       // no in-app updater detected
    case kind(UpdateMechanism.Kind)
}

/// Coarse minimum-macOS bucket for the "filter by min macOS" facet. Grouped by
/// major version so the boundaries stay stable as Apple ships new releases.
public enum MinOSBucket: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case unknown     // no LSMinimumSystemVersion declared
    case legacy      // <= 10.x (Catalina-era and earlier)
    case v11to15     // 11-15 (Big Sur ... Sequoia)
    case v16plus     // 16+ (the year-based 26+ era and beyond)

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .legacy:  return "≤ 10.x"
        case .v11to15: return "11 – 15"
        case .v16plus: return "16+"
        }
    }

    public static func from(minimumOS: String?) -> MinOSBucket {
        guard let v = minimumOS,
              let majorStr = v.split(separator: ".").first,
              let major = Int(majorStr) else { return .unknown }
        switch major {
        case ..<11:   return .legacy
        case 11...15: return .v11to15
        default:      return .v16plus
        }
    }
}

// MARK: - Flags

/// One "rotten app" signal that's either present or absent for a given app.
/// The whole filter/badge system is built on these: a result carries the
/// `Set<BatchFlag>` it trips, a filter requires a subset be present, and the
/// table renders them as badges. Adding a new signal is a single case here
/// plus one line in `derive`.
public enum BatchFlag: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case unsigned
    case adHoc
    case notNotarized
    case invalidSignature
    case noSandbox
    case noHardenedRuntime
    case trackers
    case secrets
    case antiAnalysis
    case launchItems
    case libraryValidationDisabled
    case jitAllowed
    case dyldEnvAllowed
    case endpointSecurity
    case automationAnyApp
    case intelOnly
    case noDownloadMetadata
    case hardcodedDomains
    case appStore
    case analysisFailed

    public var id: String { rawValue }

    /// Short text for compact badges.
    public var shortLabel: String {
        switch self {
        case .unsigned:                 return "Unsigned"
        case .adHoc:                    return "Ad-hoc"
        case .notNotarized:             return "Not notarized"
        case .invalidSignature:         return "Bad signature"
        case .noSandbox:                return "No sandbox"
        case .noHardenedRuntime:        return "No hardened runtime"
        case .trackers:                 return "Trackers"
        case .secrets:                  return "Secrets"
        case .antiAnalysis:             return "Anti-analysis"
        case .launchItems:              return "Launch items"
        case .libraryValidationDisabled:return "Lib validation off"
        case .jitAllowed:               return "JIT"
        case .dyldEnvAllowed:           return "DYLD env"
        case .endpointSecurity:         return "Endpoint Security"
        case .automationAnyApp:         return "Automates any app"
        case .intelOnly:                return "Intel only"
        case .noDownloadMetadata:       return "No download metadata"
        case .hardcodedDomains:         return "Hardcoded domains"
        case .appStore:                 return "App Store"
        case .analysisFailed:           return "Analysis failed"
        }
    }

    /// Longer description for filter rows / tooltips.
    public var explanation: String {
        switch self {
        case .unsigned:                 return "Not code-signed at all — anyone can have tampered with it."
        case .adHoc:                    return "Ad-hoc signed: no developer identity or Team ID."
        case .notNotarized:             return "Signed but never notarized by Apple."
        case .invalidSignature:         return "Code signature does not validate."
        case .noSandbox:                return "Runs outside the App Sandbox — full user-level access."
        case .noHardenedRuntime:        return "Hardened Runtime is off — wider attack surface."
        case .trackers:                 return "Contains advertising / analytics / attribution SDKs."
        case .secrets:                  return "Hard-coded credentials or API keys found in the binary."
        case .antiAnalysis:             return "Shows anti-debugging / anti-analysis behaviour."
        case .launchItems:              return "Ships launch agents/daemons or login items that run in the background."
        case .libraryValidationDisabled:return "Library validation disabled — can load third-party code."
        case .jitAllowed:               return "Allows JIT-compiled (writable+executable) memory."
        case .dyldEnvAllowed:           return "Permits DYLD environment-variable injection."
        case .endpointSecurity:         return "Holds the Endpoint Security entitlement — can monitor other processes."
        case .automationAnyApp:         return "Can send Apple Events to (automate) any application."
        case .intelOnly:                return "Intel-only (x86_64) — will stop launching when Apple removes Rosetta 2."
        case .noDownloadMetadata:       return "No quarantine / where-from metadata — copied or sideloaded rather than downloaded normally."
        case .hardcodedDomains:         return "Has hard-coded network domains baked into the binary."
        case .appStore:                 return "Installed from the Mac App Store."
        case .analysisFailed:           return "Static analysis could not complete for this bundle."
        }
    }

    public var systemImage: String {
        switch self {
        case .unsigned, .adHoc, .invalidSignature: return "signature"
        case .notNotarized:             return "seal"
        case .noSandbox:                return "shield.slash"
        case .noHardenedRuntime:        return "lock.open"
        case .trackers:                 return "dot.radiowaves.left.and.right"
        case .secrets:                  return "key"
        case .antiAnalysis:             return "eye.slash"
        case .launchItems:              return "play.circle"
        case .libraryValidationDisabled:return "shippingbox"
        case .jitAllowed:               return "memorychip"
        case .dyldEnvAllowed:           return "terminal"
        case .endpointSecurity:         return "binoculars"
        case .automationAnyApp:         return "wand.and.stars"
        case .intelOnly:                return "cpu"
        case .noDownloadMetadata:       return "questionmark.folder"
        case .hardcodedDomains:         return "network"
        case .appStore:                 return "bag"
        case .analysisFailed:           return "exclamationmark.triangle"
        }
    }

    /// Whether this flag is a negative ("rotten") signal — drives badge colour
    /// and which chips appear in the quick-filter bar. `appStore` is purely
    /// informational, not a concern.
    public var isConcern: Bool { self != .appStore }
}

// MARK: - Result

/// One row in the batch table: a lightweight, `Codable` summary of a single
/// app's static analysis. Deliberately does **not** carry the full
/// `StaticReport` — drilling into an app re-runs the single-app pipeline — so
/// a scan of hundreds of apps stays small in memory and trivially exportable.
public struct BatchAppResult: Identifiable, Hashable, Sendable, Codable {
    public var id: String { url.path }

    public let url: URL
    public let displayName: String
    public let bundleID: String?
    public let version: String?

    public let risk: RiskScore
    public let signing: SigningStatus
    public let flags: Set<BatchFlag>

    public let isSandboxed: Bool
    public let hardenedRuntime: Bool
    public let isAppStore: Bool

    public let architectures: [String]
    public let archClass: ArchClass
    public let minimumOS: String?
    /// `nil` when no in-app update mechanism was detected.
    public let updateKind: UpdateMechanism.Kind?
    public let hasDownloadMetadata: Bool
    /// Host of the download URL, or the quarantine agent name — a short hint
    /// at where the app came from. `nil` when there's no provenance metadata.
    public let downloadSource: String?

    public let trackerCount: Int
    public let trackerNames: [String]
    public let sdkCount: Int
    public let secretCount: Int
    public let antiAnalysisCount: Int
    public let launchItemCount: Int
    public let hardcodedDomainCount: Int

    /// Non-nil when the analyzer threw for this bundle.
    public let analysisError: String?

    public init(url: URL, displayName: String, bundleID: String?, version: String?,
                risk: RiskScore, signing: SigningStatus, flags: Set<BatchFlag>,
                isSandboxed: Bool, hardenedRuntime: Bool, isAppStore: Bool,
                architectures: [String], archClass: ArchClass, minimumOS: String?,
                updateKind: UpdateMechanism.Kind?, hasDownloadMetadata: Bool,
                downloadSource: String?,
                trackerCount: Int, trackerNames: [String], sdkCount: Int,
                secretCount: Int, antiAnalysisCount: Int, launchItemCount: Int,
                hardcodedDomainCount: Int, analysisError: String?) {
        self.url = url
        self.displayName = displayName
        self.bundleID = bundleID
        self.version = version
        self.risk = risk
        self.signing = signing
        self.flags = flags
        self.isSandboxed = isSandboxed
        self.hardenedRuntime = hardenedRuntime
        self.isAppStore = isAppStore
        self.architectures = architectures
        self.archClass = archClass
        self.minimumOS = minimumOS
        self.updateKind = updateKind
        self.hasDownloadMetadata = hasDownloadMetadata
        self.downloadSource = downloadSource
        self.trackerCount = trackerCount
        self.trackerNames = trackerNames
        self.sdkCount = sdkCount
        self.secretCount = secretCount
        self.antiAnalysisCount = antiAnalysisCount
        self.launchItemCount = launchItemCount
        self.hardcodedDomainCount = hardcodedDomainCount
        self.analysisError = analysisError
    }

    /// Concern flags only, sorted for stable badge order.
    public var concernFlags: [BatchFlag] {
        flags.filter { $0.isConcern }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Number of "rotten" signals tripped — a sortable single-glance severity
    /// count for the table's Issues column.
    public var concernCount: Int { flags.reduce(0) { $0 + ($1.isConcern ? 1 : 0) } }

    /// Human label for the update mechanism, or "None".
    public var updateLabel: String { updateKind?.label ?? "None" }

    /// A monotonic key for sorting the Min-OS column by actual version order
    /// rather than string order (so "9.0" sorts below "10.0"). Unknown → 0.
    public var minOSSortKey: Int {
        guard let v = minimumOS else { return 0 }
        let parts = v.split(separator: ".").map { Int($0) ?? 0 }
        // Clamp each segment so a hostile/garbage LSMinimumSystemVersion (e.g. a
        // 16-digit number in a malformed Info.plist) can't overflow Int and
        // crash the table, and so a minor/patch >= 100 can't carry into the next
        // place and break monotonic ordering.
        let major = parts.count > 0 ? min(max(parts[0], 0), 9_999) : 0
        let minor = parts.count > 1 ? min(max(parts[1], 0), 99) : 0
        let patch = parts.count > 2 ? min(max(parts[2], 0), 99) : 0
        return major * 10_000 + minor * 100 + patch
    }

    /// Coarse minimum-macOS bucket for the "filter by min macOS" facet.
    public var minOSBucket: MinOSBucket { MinOSBucket.from(minimumOS: minimumOS) }

    // MARK: Derivation

    /// Build a result from a completed analysis. This is the single place
    /// where `StaticReport` + `RiskScore` collapse into the flat signals the
    /// table sorts and filters on.
    public static func derive(url: URL, report: StaticReport, risk: RiskScore) -> BatchAppResult {
        let cs = report.codeSigning
        let isApple = cs.isPlatformBinary
        let ent = report.entitlements

        let trackers = report.sdkHits.filter { $0.isTrackerLike }
        let launchItems = report.embeddedAssets.launchPlists.count + report.loginItems.count
        let archClass = ArchClass.classify(report.bundle.architectures)
        let prov = report.provenance
        let hasDownloadMetadata = !prov.whereFromURLs.isEmpty || prov.isQuarantined
        let downloadSource = Self.downloadSource(whereFromURLs: prov.whereFromURLs,
                                                 agentName: prov.quarantineAgentName)

        var flags: Set<BatchFlag> = []
        switch report.notarization {
        case .unsigned:                         flags.insert(.unsigned)
        case .developerIDOnly, .rejected, .unknown:
            if !isApple { flags.insert(.notNotarized) }
        case .notarized:                        break
        }
        if cs.isAdhocSigned && !isApple { flags.insert(.adHoc) }
        if !cs.validates && !isApple { flags.insert(.invalidSignature) }
        if !ent.isSandboxed && !isApple { flags.insert(.noSandbox) }
        if !cs.hardenedRuntime && !isApple { flags.insert(.noHardenedRuntime) }
        if !trackers.isEmpty { flags.insert(.trackers) }
        if !report.secrets.isEmpty { flags.insert(.secrets) }
        if !report.antiAnalysis.isEmpty { flags.insert(.antiAnalysis) }
        if launchItems > 0 { flags.insert(.launchItems) }
        if ent.disablesLibraryValidation && !isApple { flags.insert(.libraryValidationDisabled) }
        if ent.allowsJIT { flags.insert(.jitAllowed) }
        if ent.allowsDyldEnvironmentVariables && !isApple { flags.insert(.dyldEnvAllowed) }
        if ent.endpointSecurityClient { flags.insert(.endpointSecurity) }
        if case .anyApp = ent.appleEvents { flags.insert(.automationAnyApp) }
        if archClass == .intel { flags.insert(.intelOnly) }
        // "No download metadata" only matters for third-party, non-App-Store
        // apps — Apple's own binaries and MAS installs legitimately carry no
        // quarantine/where-from xattrs.
        if !isApple && !report.appStoreInfo.isMASApp && !hasDownloadMetadata {
            flags.insert(.noDownloadMetadata)
        }
        if !report.hardcodedDomains.isEmpty { flags.insert(.hardcodedDomains) }
        if report.appStoreInfo.isMASApp { flags.insert(.appStore) }

        return BatchAppResult(
            url: url,
            displayName: report.bundle.bundleName ?? url.deletingPathExtension().lastPathComponent,
            bundleID: report.bundle.bundleID,
            version: report.bundle.bundleVersion,
            risk: risk,
            signing: signingStatus(report: report),
            flags: flags,
            isSandboxed: ent.isSandboxed,
            hardenedRuntime: cs.hardenedRuntime,
            isAppStore: report.appStoreInfo.isMASApp,
            architectures: report.bundle.architectures,
            archClass: archClass,
            minimumOS: report.bundle.minimumSystemVersion,
            updateKind: report.updateMechanism?.kind,
            hasDownloadMetadata: hasDownloadMetadata,
            downloadSource: downloadSource,
            trackerCount: trackers.count,
            trackerNames: trackers.map { $0.fingerprint.displayName },
            sdkCount: report.sdkHits.count,
            secretCount: report.secrets.count,
            antiAnalysisCount: report.antiAnalysis.count,
            launchItemCount: launchItems,
            hardcodedDomainCount: report.hardcodedDomains.count,
            analysisError: nil
        )
    }

    /// A placeholder row for a bundle the analyzer couldn't process. Marked
    /// `.critical`-free (score 0) but surfaced via the `.analysisFailed` flag
    /// so it's filterable rather than silently dropped.
    public static func failed(url: URL, name: String?, error: String) -> BatchAppResult {
        BatchAppResult(
            url: url,
            displayName: name ?? url.deletingPathExtension().lastPathComponent,
            bundleID: nil, version: nil,
            risk: .zero, signing: .unsigned, flags: [.analysisFailed],
            isSandboxed: false, hardenedRuntime: false, isAppStore: false,
            architectures: [], archClass: .other, minimumOS: nil,
            updateKind: nil, hasDownloadMetadata: false, downloadSource: nil,
            trackerCount: 0, trackerNames: [], sdkCount: 0,
            secretCount: 0, antiAnalysisCount: 0, launchItemCount: 0,
            hardcodedDomainCount: 0, analysisError: error
        )
    }

    private static func signingStatus(report: StaticReport) -> SigningStatus {
        let cs = report.codeSigning
        if cs.isPlatformBinary { return .apple }
        if report.appStoreInfo.isMASApp { return .appStore }
        switch report.notarization {
        case .unsigned:        return .unsigned
        case .rejected:        return .invalid
        default:               break
        }
        if cs.isAdhocSigned { return .adHoc }
        if !cs.validates { return .invalid }
        switch report.notarization {
        case .notarized:       return .developerIDNotarized
        case .developerIDOnly: return .developerID
        default:               return .signed
        }
    }

    /// Extract a human "where from" hint: host of the first download URL, else
    /// the quarantine agent. Uses `URL(string:)?.host` and rejects empty hosts
    /// so `file://` / local-copy where-froms fall through to the agent name
    /// (AirDrop, etc.) instead of returning an empty string.
    static func downloadSource(whereFromURLs: [String], agentName: String?) -> String? {
        if let first = whereFromURLs.first,
           let host = URL(string: first)?.host, !host.isEmpty {
            return host
        }
        return agentName
    }
}

// MARK: - RiskTier ordering

public extension RiskTier {
    /// Severity ordinal so tiers can be compared / used as a minimum filter.
    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }
}

// MARK: - Filter

/// A pure, testable predicate over `BatchAppResult`. The UI binds its chips
/// and search box to this; `matches` is the whole filtering rule.
public struct BatchFilter: Sendable, Equatable {
    public var searchText: String
    public var requiredFlags: Set<BatchFlag>
    public var minTier: RiskTier?

    // Categorical facets — each nil means "any".
    public var archClass: ArchClass?
    public var updateFilter: UpdateFilter?
    /// true = sandboxed only, false = unsandboxed only, nil = any.
    public var sandboxed: Bool?
    /// true = has download metadata, false = missing it, nil = any.
    public var hasDownloadMetadata: Bool?
    /// Minimum-macOS bucket, nil = any.
    public var minOSBucket: MinOSBucket?

    public init(searchText: String = "", requiredFlags: Set<BatchFlag> = [], minTier: RiskTier? = nil,
                archClass: ArchClass? = nil, updateFilter: UpdateFilter? = nil,
                sandboxed: Bool? = nil, hasDownloadMetadata: Bool? = nil,
                minOSBucket: MinOSBucket? = nil) {
        self.searchText = searchText
        self.requiredFlags = requiredFlags
        self.minTier = minTier
        self.archClass = archClass
        self.updateFilter = updateFilter
        self.sandboxed = sandboxed
        self.hasDownloadMetadata = hasDownloadMetadata
        self.minOSBucket = minOSBucket
    }

    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !requiredFlags.isEmpty
            || minTier != nil
            || archClass != nil
            || updateFilter != nil
            || sandboxed != nil
            || hasDownloadMetadata != nil
            || minOSBucket != nil
    }

    public func matches(_ r: BatchAppResult) -> Bool {
        if let minTier, r.risk.tier.rank < minTier.rank { return false }
        if !requiredFlags.isSubset(of: r.flags) { return false }
        if let archClass, r.archClass != archClass { return false }
        if let updateFilter {
            switch updateFilter {
            case .none:          if r.updateKind != nil { return false }
            case .kind(let k):   if r.updateKind != k { return false }
            }
        }
        if let sandboxed, r.isSandboxed != sandboxed { return false }
        if let hasDownloadMetadata, r.hasDownloadMetadata != hasDownloadMetadata { return false }
        if let minOSBucket, r.minOSBucket != minOSBucket { return false }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hay = [r.displayName, r.bundleID ?? "", r.url.path].joined(separator: " ")
            if !hay.localizedCaseInsensitiveContains(q) { return false }
        }
        return true
    }
}

// MARK: - Export

/// A serialisable wrapper for a whole batch scan plus CSV/JSON renderers.
/// Pure string/Data output so it's testable and AppKit-free; the GUI just
/// drops the result into a save panel.
public struct BatchReport: Codable, Sendable {
    public let generatedAt: Date
    public let scope: String
    public let results: [BatchAppResult]

    public init(generatedAt: Date = .init(), scope: String, results: [BatchAppResult]) {
        self.generatedAt = generatedAt
        self.scope = scope
        self.results = results
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    private static let csvColumns = [
        "App", "Bundle ID", "Version", "Risk Tier", "Risk Score", "Signing",
        "Sandbox", "Hardened Runtime", "App Store", "Architecture", "Min macOS",
        "Update Mechanism", "Download Source", "Trackers", "SDKs",
        "Secrets", "Anti-Analysis", "Launch Items", "Hardcoded Domains",
        "Flags", "Path", "Error"
    ]

    public static func csv(_ results: [BatchAppResult]) -> String {
        var lines = [csvColumns.map(escape).joined(separator: ",")]
        for r in results {
            let row: [String] = [
                r.displayName,
                r.bundleID ?? "",
                r.version ?? "",
                r.risk.tier.label,
                String(r.risk.score),
                r.signing.label,
                r.isSandboxed ? "yes" : "no",
                r.hardenedRuntime ? "yes" : "no",
                r.isAppStore ? "yes" : "no",
                r.archClass.label,
                r.minimumOS ?? "",
                r.updateLabel,
                r.downloadSource ?? "",
                String(r.trackerCount),
                String(r.sdkCount),
                String(r.secretCount),
                String(r.antiAnalysisCount),
                String(r.launchItemCount),
                String(r.hardcodedDomainCount),
                r.concernFlags.map(\.shortLabel).joined(separator: "; "),
                r.url.path,
                r.analysisError ?? ""
            ]
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
