import Foundation

/// Reads the bundle's `PrivacyInfo.xcprivacy` file (introduced by Apple in
/// Xcode 15, made mandatory for App Store apps in May 2024) and converts
/// it into a structured `PrivacyManifest`.
///
/// **Why we care.** The privacy manifest is the most authoritative
/// developer-stated record of what data an app collects, what tracking it
/// performs, and which "required-reason" APIs it uses. Apple now polices
/// it at App Store submission time. Outside the App Store nothing checks
/// for it — but well-behaved Mac apps still ship one, and apps that *don't*
/// ship one (or whose manifest contradicts what their binary actually
/// does) are legitimately of more interest.
public enum PrivacyManifestReader {

    /// Scan the bundle's Resources directory for any `PrivacyInfo.xcprivacy`
    /// — the canonical name. Apple allows the same file inside frameworks
    /// (each framework can ship its own), but for the static analyzer's
    /// purposes we only care about the main app's manifest.
    public static func read(for bundle: AppBundle) -> PrivacyManifest? {
        let candidates = candidateLocations(in: bundle)
        for url in candidates {
            if let manifest = parse(at: url) { return manifest }
        }
        return nil
    }

    /// Same as `read(for:)` but also returns nested-framework manifests.
    /// Used for the deep-dive panel that lists all manifests in the bundle.
    public static func readAll(for bundle: AppBundle) -> [PrivacyManifest] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: bundle.url,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [PrivacyManifest] = []
        for case let url as URL in walker {
            guard url.lastPathComponent == "PrivacyInfo.xcprivacy" else { continue }
            if let m = parse(at: url) { out.append(m) }
        }
        return out
    }

    private static func candidateLocations(in bundle: AppBundle) -> [URL] {
        // Standard bundles keep it in Contents/Resources; flat iOS bundles put
        // it at the root (which is also `resourcesURL` for that layout).
        return [
            bundle.resourcesURL.appendingPathComponent("PrivacyInfo.xcprivacy"),
            bundle.url.appendingPathComponent("PrivacyInfo.xcprivacy")
        ]
    }

    // MARK: - Parsing

    private static func parse(at url: URL) -> PrivacyManifest? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let tracking = plist["NSPrivacyTracking"] as? Bool ?? false
        let trackingDomains = (plist["NSPrivacyTrackingDomains"] as? [String]) ?? []
        let collected = parseCollectedDataTypes(plist["NSPrivacyCollectedDataTypes"])
        let accessed = parseAccessedAPITypes(plist["NSPrivacyAccessedAPITypes"])
        return PrivacyManifest(
            url: url,
            isTrackingDeclared: tracking,
            trackingDomains: trackingDomains,
            collectedDataTypes: collected,
            accessedAPITypes: accessed
        )
    }

    private static func parseCollectedDataTypes(_ raw: Any?) -> [PrivacyManifest.CollectedDataType] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let type = dict["NSPrivacyCollectedDataType"] as? String else { return nil }
            let linked = dict["NSPrivacyCollectedDataTypeLinked"] as? Bool ?? false
            let tracking = dict["NSPrivacyCollectedDataTypeTracking"] as? Bool ?? false
            let purposes = (dict["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []
            return PrivacyManifest.CollectedDataType(
                rawType: type,
                displayName: PrivacyManifest.collectedDataTypeNames[type] ?? type,
                linkedToUser: linked,
                usedForTracking: tracking,
                purposes: purposes.map { PrivacyManifest.collectedDataPurposeNames[$0] ?? $0 })
        }
    }

    private static func parseAccessedAPITypes(_ raw: Any?) -> [PrivacyManifest.AccessedAPI] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let type = dict["NSPrivacyAccessedAPIType"] as? String else { return nil }
            let reasons = (dict["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []
            return PrivacyManifest.AccessedAPI(
                rawType: type,
                category: PrivacyManifest.AccessedAPI.Category(raw: type),
                reasons: reasons)
        }
    }

    // MARK: - Cross-check

    /// Compare the manifest's `accessedAPITypes` against the binary's
    /// undefined-external symbols (`MachOInspector.importedSymbols(of:)`),
    /// using the `RequiredReasonAPIs` vocabulary. Returns mismatches in both
    /// directions.
    ///
    /// Matching is exact on nlist spellings — `_stat`, `_stat$INODE64`,
    /// `_OBJC_CLASS_$_NSUserDefaults` — never substring-based. A symbol that
    /// belongs to more than one category (the `getattrlist` family sits in
    /// both FileTimestamp and DiskSpace) counts as evidence for each.
    ///
    /// Categories the manifest declares that Apple doesn't document (they
    /// collapse to `.other`) are excluded from `declaredButUnused`: no symbol
    /// evidence can exist for them, and flagging the unknown value itself is
    /// a validity check, not a cross-check.
    public static func crossCheck(manifest: PrivacyManifest,
                                  importedSymbols: Set<String>) -> PrivacyManifestCrossCheck {
        var evidenceByCategory: [PrivacyManifest.AccessedAPI.Category: Set<String>] = [:]
        for symbol in importedSymbols {
            for category in RequiredReasonAPIs.categories(forNlistSpelling: symbol) {
                evidenceByCategory[category, default: []].insert(symbol)
            }
        }

        let declaredCategories = Set(manifest.accessedAPITypes.map(\.category))
        let observedCategories = Set(evidenceByCategory.keys)

        let declaredButUnused = declaredCategories.subtracting(observedCategories)
            .filter { $0 != .other }
        let usedButUndeclared = observedCategories.subtracting(declaredCategories)

        return PrivacyManifestCrossCheck(
            declaredButUnused: declaredButUnused.sorted(by: { $0.rawValue < $1.rawValue }),
            usedButUndeclared: usedButUndeclared.sorted(by: { $0.rawValue < $1.rawValue })
                .map { PrivacyManifestCrossCheck.Mismatch(
                    category: $0, evidence: (evidenceByCategory[$0] ?? []).sorted()) }
        )
    }

    /// Consistency between the manifest's *stated* tracking and what the binary
    /// actually embeds (tracker SDKs) and contacts (tracker domains). Pure +
    /// testable; the caller supplies the observed signals.
    public static func trackingCrossCheck(manifest: PrivacyManifest,
                                          trackerSDKNames: [String],
                                          observedTrackerDomains: [String]) -> PrivacyManifestTrackingCrossCheck {
        let declaresTracking = manifest.isTrackingDeclared
            || manifest.collectedDataTypes.contains { $0.usedForTracking }
        // Embeds tracker SDKs while declaring no tracking → a real contradiction.
        let sdkContradiction = declaresTracking ? [] : trackerSDKNames.sorted()
        // Tracker domains contacted but not listed under NSPrivacyTrackingDomains
        // (host-boundary match so a sub-domain of a declared domain counts).
        let declared = manifest.trackingDomains.map { $0.lowercased() }
        // A declared domain covers itself and its SUB-domains, never its parent:
        // declaring `analytics.example.com` must not excuse contacting the bare
        // tracker apex `example.com`. (No `$0.hasSuffix("." + dom)` clause.)
        let undeclared = observedTrackerDomains.map { $0.lowercased() }.filter { dom in
            !declared.contains { dom == $0 || dom.hasSuffix("." + $0) }
        }
        return PrivacyManifestTrackingCrossCheck(
            trackerSDKsButTrackingNotDeclared: sdkContradiction,
            undeclaredTrackingDomains: Array(Set(undeclared)).sorted())
    }
}

// MARK: - Public types

public struct PrivacyManifest: Sendable, Hashable, Codable {
    public let url: URL
    public let isTrackingDeclared: Bool
    public let trackingDomains: [String]
    public let collectedDataTypes: [CollectedDataType]
    public let accessedAPITypes: [AccessedAPI]

    public init(url: URL,
                isTrackingDeclared: Bool,
                trackingDomains: [String],
                collectedDataTypes: [CollectedDataType],
                accessedAPITypes: [AccessedAPI]) {
        self.url = url
        self.isTrackingDeclared = isTrackingDeclared
        self.trackingDomains = trackingDomains
        self.collectedDataTypes = collectedDataTypes
        self.accessedAPITypes = accessedAPITypes
    }

    public struct CollectedDataType: Sendable, Hashable, Codable, Identifiable {
        public var id: String { rawType }
        public let rawType: String          // e.g. NSPrivacyCollectedDataTypeName
        public let displayName: String      // human form, e.g. "Name"
        public let linkedToUser: Bool
        public let usedForTracking: Bool
        public let purposes: [String]
    }

    public struct AccessedAPI: Sendable, Hashable, Codable, Identifiable {
        public var id: String { rawType }
        public let rawType: String          // e.g. NSPrivacyAccessedAPICategoryFileTimestamp
        public let category: Category
        public let reasons: [String]        // e.g. ["C617.1"]

        public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
            case fileTimestamp     = "File timestamp"
            case systemBootTime    = "System boot time"
            case diskSpace         = "Disk space"
            case activeKeyboards   = "Active keyboards"
            case userDefaults      = "User defaults"
            case other             = "Other"

            init(raw: String) {
                switch raw {
                case "NSPrivacyAccessedAPICategoryFileTimestamp":   self = .fileTimestamp
                case "NSPrivacyAccessedAPICategorySystemBootTime":  self = .systemBootTime
                case "NSPrivacyAccessedAPICategoryDiskSpace":       self = .diskSpace
                case "NSPrivacyAccessedAPICategoryActiveKeyboards": self = .activeKeyboards
                case "NSPrivacyAccessedAPICategoryUserDefaults":    self = .userDefaults
                default: self = .other
                }
            }
        }
    }

    // MARK: - Display name maps

    fileprivate static let collectedDataTypeNames: [String: String] = [
        "NSPrivacyCollectedDataTypeName":               "Name",
        "NSPrivacyCollectedDataTypeEmailAddress":       "Email address",
        "NSPrivacyCollectedDataTypePhoneNumber":        "Phone number",
        "NSPrivacyCollectedDataTypePhysicalAddress":    "Physical address",
        "NSPrivacyCollectedDataTypeOtherUserContactInfo": "Other contact info",
        "NSPrivacyCollectedDataTypeHealth":              "Health",
        "NSPrivacyCollectedDataTypeFitness":             "Fitness",
        "NSPrivacyCollectedDataTypePaymentInfo":         "Payment info",
        "NSPrivacyCollectedDataTypeCreditInfo":          "Credit info",
        "NSPrivacyCollectedDataTypeOtherFinancialInfo":  "Other financial info",
        "NSPrivacyCollectedDataTypePreciseLocation":    "Precise location",
        "NSPrivacyCollectedDataTypeCoarseLocation":     "Coarse location",
        "NSPrivacyCollectedDataTypeSensitiveInfo":      "Sensitive info",
        "NSPrivacyCollectedDataTypeContacts":           "Contacts",
        "NSPrivacyCollectedDataTypeEmailsOrTextMessages": "Emails or text messages",
        "NSPrivacyCollectedDataTypePhotosOrVideos":     "Photos or videos",
        "NSPrivacyCollectedDataTypeAudioData":          "Audio data",
        "NSPrivacyCollectedDataTypeGameplayContent":    "Gameplay content",
        "NSPrivacyCollectedDataTypeCustomerSupport":    "Customer-support data",
        "NSPrivacyCollectedDataTypeOtherUserContent":   "Other user content",
        "NSPrivacyCollectedDataTypeBrowsingHistory":    "Browsing history",
        "NSPrivacyCollectedDataTypeSearchHistory":      "Search history",
        "NSPrivacyCollectedDataTypeUserID":             "User ID",
        "NSPrivacyCollectedDataTypeDeviceID":           "Device ID",
        "NSPrivacyCollectedDataTypePurchaseHistory":    "Purchase history",
        "NSPrivacyCollectedDataTypeProductInteraction": "Product interaction",
        "NSPrivacyCollectedDataTypeAdvertisingData":    "Advertising data",
        "NSPrivacyCollectedDataTypeOtherUsageData":     "Other usage data",
        "NSPrivacyCollectedDataTypeCrashData":          "Crash data",
        "NSPrivacyCollectedDataTypePerformanceData":    "Performance data",
        "NSPrivacyCollectedDataTypeOtherDiagnosticData": "Other diagnostic data",
        "NSPrivacyCollectedDataTypeEnvironmentScanning": "Environment scanning",
        "NSPrivacyCollectedDataTypeHands":              "Hand structure data",
        "NSPrivacyCollectedDataTypeHead":               "Head movement",
        "NSPrivacyCollectedDataTypeOtherDataTypes":     "Other data types"
    ]

    fileprivate static let collectedDataPurposeNames: [String: String] = [
        "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising": "Third-party advertising",
        "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising":  "Developer's own advertising",
        "NSPrivacyCollectedDataTypePurposeAnalytics":             "Analytics",
        "NSPrivacyCollectedDataTypePurposeProductPersonalization": "Product personalization",
        "NSPrivacyCollectedDataTypePurposeAppFunctionality":      "App functionality",
        "NSPrivacyCollectedDataTypePurposeOther":                 "Other"
    ]
}

public struct PrivacyManifestCrossCheck: Sendable, Hashable {
    public let declaredButUnused: [PrivacyManifest.AccessedAPI.Category]
    public let usedButUndeclared: [Mismatch]

    public struct Mismatch: Sendable, Hashable, Identifiable {
        public var id: String { category.rawValue }
        public let category: PrivacyManifest.AccessedAPI.Category
        public let evidence: [String]
    }

    public var isClean: Bool {
        declaredButUnused.isEmpty && usedButUndeclared.isEmpty
    }
}

/// Result of comparing the manifest's stated tracking against observed signals.
public struct PrivacyManifestTrackingCrossCheck: Sendable, Hashable {
    /// Tracker SDK display names embedded while the manifest declares no tracking.
    public let trackerSDKsButTrackingNotDeclared: [String]
    /// Tracker domains the binary contacts that aren't in NSPrivacyTrackingDomains.
    public let undeclaredTrackingDomains: [String]
    public var isClean: Bool { trackerSDKsButTrackingNotDeclared.isEmpty && undeclaredTrackingDomains.isEmpty }
    public init(trackerSDKsButTrackingNotDeclared: [String], undeclaredTrackingDomains: [String]) {
        self.trackerSDKsButTrackingNotDeclared = trackerSDKsButTrackingNotDeclared
        self.undeclaredTrackingDomains = undeclaredTrackingDomains
    }
}
