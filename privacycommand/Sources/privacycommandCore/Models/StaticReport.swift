import Foundation

public struct StaticReport: Codable, Hashable, Sendable {
    public let bundle: AppBundle
    public let declaredPrivacyKeys: [PrivacyKey]
    public let entitlements: Entitlements
    public let codeSigning: CodeSigningInfo
    public let notarization: NotarizationStatus
    public let urlSchemes: [URLSchemeDecl]
    public let documentTypes: [DocumentTypeDecl]
    public let loginItems: [BundleRef]
    public let xpcServices: [BundleRef]
    public let helpers: [BundleRef]
    public let frameworks: [FrameworkRef]
    public let inferredCapabilities: [InferredCapability]
    public let hardcodedURLs: [String]      // string form to keep URLs that can't round-trip Codable
    public let hardcodedDomains: [String]
    public let hardcodedPaths: [String]
    public let warnings: [Finding]
    public let atsConfig: ATSConfig?
    public let provenance: ProvenanceInfo
    public let updateMechanism: UpdateMechanism?
    /// Third-party SDKs detected in the bundle (analytics, advertising,
    /// crash reporting, …). Backward-compatible Codable: older saved reports
    /// without this field decode as `[]`.
    public let sdkHits: [SDKHit]
    /// Hard-coded credentials / API keys found in the binary's strings.
    public let secrets: [SecretFinding]
    /// Per-Mach-O code-signing audit across the entire bundle (not just the
    /// outer signature) — flags Team-ID mismatches and unsigned components.
    public let bundleSigning: BundleSigningAudit
    /// Anti-analysis / anti-debugging signals.
    public let antiAnalysis: [AntiAnalysisDetector.Result.Finding]
    /// LC_RPATH entries and any user-writable hijacking surface.
    public let rpathAudit: RPathAudit
    /// Embedded scripts and launchd plists shipped inside the bundle.
    public let embeddedAssets: EmbeddedAssets
    /// Apple Privacy Manifest (PrivacyInfo.xcprivacy) if shipped.
    public let privacyManifest: PrivacyManifest?
    /// Deep notarization / Gatekeeper details (stapler, spctl, SHA-256).
    public let notarizationDeepDive: NotarizationDeepDiveReport
    /// Feature flags / trial-state / debug toggles found in binary
    /// strings. Empty for older saved reports (backward-compatible).
    public let flagFindings: [FlagFinding]
    /// Mac App Store metadata + scraped Privacy Nutrition Labels.
    /// Detected synchronously from `Contents/_MASReceipt/receipt`;
    /// the `privacyLabels` field is populated asynchronously by
    /// `AppStorePrivacyLabelFetcher` after the report is built. The
    /// coordinator overwrites the report with an updated copy when
    /// the fetch completes, so the persisted JSON includes whatever
    /// state was current at save time.
    public let appStoreInfo: AppStoreInfo
    public let analyzedAt: Date

    public init(
        bundle: AppBundle,
        declaredPrivacyKeys: [PrivacyKey],
        entitlements: Entitlements,
        codeSigning: CodeSigningInfo,
        notarization: NotarizationStatus,
        urlSchemes: [URLSchemeDecl],
        documentTypes: [DocumentTypeDecl],
        loginItems: [BundleRef],
        xpcServices: [BundleRef],
        helpers: [BundleRef],
        frameworks: [FrameworkRef],
        inferredCapabilities: [InferredCapability],
        hardcodedURLs: [String],
        hardcodedDomains: [String],
        hardcodedPaths: [String],
        warnings: [Finding],
        atsConfig: ATSConfig? = nil,
        provenance: ProvenanceInfo = .empty,
        updateMechanism: UpdateMechanism? = nil,
        sdkHits: [SDKHit] = [],
        secrets: [SecretFinding] = [],
        bundleSigning: BundleSigningAudit = .empty,
        antiAnalysis: [AntiAnalysisDetector.Result.Finding] = [],
        rpathAudit: RPathAudit = .empty,
        embeddedAssets: EmbeddedAssets = .empty,
        privacyManifest: PrivacyManifest? = nil,
        notarizationDeepDive: NotarizationDeepDiveReport = .empty,
        flagFindings: [FlagFinding] = [],
        appStoreInfo: AppStoreInfo = .notMAS,
        analyzedAt: Date = .init()
    ) {
        self.bundle = bundle
        self.declaredPrivacyKeys = declaredPrivacyKeys
        self.entitlements = entitlements
        self.codeSigning = codeSigning
        self.notarization = notarization
        self.urlSchemes = urlSchemes
        self.documentTypes = documentTypes
        self.loginItems = loginItems
        self.xpcServices = xpcServices
        self.helpers = helpers
        self.frameworks = frameworks
        self.inferredCapabilities = inferredCapabilities
        self.hardcodedURLs = hardcodedURLs
        self.hardcodedDomains = hardcodedDomains
        self.hardcodedPaths = hardcodedPaths
        self.warnings = warnings
        self.atsConfig = atsConfig
        self.provenance = provenance
        self.updateMechanism = updateMechanism
        self.sdkHits = sdkHits
        self.secrets = secrets
        self.bundleSigning = bundleSigning
        self.antiAnalysis = antiAnalysis
        self.rpathAudit = rpathAudit
        self.embeddedAssets = embeddedAssets
        self.privacyManifest = privacyManifest
        self.notarizationDeepDive = notarizationDeepDive
        self.flagFindings = flagFindings
        self.appStoreInfo = appStoreInfo
        self.analyzedAt = analyzedAt
    }

    private enum CodingKeys: String, CodingKey {
        case bundle, declaredPrivacyKeys, entitlements, codeSigning, notarization
        case urlSchemes, documentTypes, loginItems, xpcServices, helpers, frameworks
        case inferredCapabilities, hardcodedURLs, hardcodedDomains, hardcodedPaths, warnings
        case atsConfig, provenance, updateMechanism, sdkHits
        case secrets, bundleSigning, antiAnalysis, rpathAudit, embeddedAssets
        case privacyManifest, notarizationDeepDive, flagFindings
        case appStoreInfo
        case analyzedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bundle = try c.decode(AppBundle.self, forKey: .bundle)
        self.declaredPrivacyKeys = try c.decode([PrivacyKey].self, forKey: .declaredPrivacyKeys)
        self.entitlements = try c.decode(Entitlements.self, forKey: .entitlements)
        self.codeSigning = try c.decode(CodeSigningInfo.self, forKey: .codeSigning)
        self.notarization = try c.decode(NotarizationStatus.self, forKey: .notarization)
        self.urlSchemes = try c.decode([URLSchemeDecl].self, forKey: .urlSchemes)
        self.documentTypes = try c.decode([DocumentTypeDecl].self, forKey: .documentTypes)
        self.loginItems = try c.decode([BundleRef].self, forKey: .loginItems)
        self.xpcServices = try c.decode([BundleRef].self, forKey: .xpcServices)
        self.helpers = try c.decode([BundleRef].self, forKey: .helpers)
        self.frameworks = try c.decode([FrameworkRef].self, forKey: .frameworks)
        self.inferredCapabilities = try c.decode([InferredCapability].self, forKey: .inferredCapabilities)
        self.hardcodedURLs = try c.decode([String].self, forKey: .hardcodedURLs)
        self.hardcodedDomains = try c.decode([String].self, forKey: .hardcodedDomains)
        self.hardcodedPaths = try c.decode([String].self, forKey: .hardcodedPaths)
        self.warnings = try c.decode([Finding].self, forKey: .warnings)
        self.atsConfig = try c.decodeIfPresent(ATSConfig.self, forKey: .atsConfig)
        self.provenance = try c.decodeIfPresent(ProvenanceInfo.self, forKey: .provenance) ?? .empty
        self.updateMechanism = try c.decodeIfPresent(UpdateMechanism.self, forKey: .updateMechanism)
        self.sdkHits = try c.decodeIfPresent([SDKHit].self, forKey: .sdkHits) ?? []
        self.secrets = try c.decodeIfPresent([SecretFinding].self, forKey: .secrets) ?? []
        self.bundleSigning = try c.decodeIfPresent(BundleSigningAudit.self, forKey: .bundleSigning) ?? .empty
        self.antiAnalysis = try c.decodeIfPresent([AntiAnalysisDetector.Result.Finding].self, forKey: .antiAnalysis) ?? []
        self.rpathAudit = try c.decodeIfPresent(RPathAudit.self, forKey: .rpathAudit) ?? .empty
        self.embeddedAssets = try c.decodeIfPresent(EmbeddedAssets.self, forKey: .embeddedAssets) ?? .empty
        self.privacyManifest = try c.decodeIfPresent(PrivacyManifest.self, forKey: .privacyManifest)
        self.notarizationDeepDive = try c.decodeIfPresent(NotarizationDeepDiveReport.self, forKey: .notarizationDeepDive) ?? .empty
        self.flagFindings = try c.decodeIfPresent([FlagFinding].self, forKey: .flagFindings) ?? []
        self.appStoreInfo = try c.decodeIfPresent(AppStoreInfo.self, forKey: .appStoreInfo) ?? .notMAS
        self.analyzedAt = try c.decode(Date.self, forKey: .analyzedAt)
    }
}

public struct Entitlements: Codable, Hashable, Sendable {
    /// Raw plist as a string-keyed dictionary, for full fidelity round-trip.
    public let raw: [String: PlistValue]
    public let isSandboxed: Bool
    public let appGroups: [String]
    public let appleEvents: AppleEventsEntitlement?
    public let networkClient: Bool
    public let networkServer: Bool
    public let allowsJIT: Bool
    public let allowsDyldEnvironmentVariables: Bool
    public let disablesLibraryValidation: Bool
    public let endpointSecurityClient: Bool
    public let networkExtension: [String]   // values of com.apple.developer.networking.networkextension

    public init(
        raw: [String: PlistValue],
        isSandboxed: Bool,
        appGroups: [String],
        appleEvents: AppleEventsEntitlement?,
        networkClient: Bool,
        networkServer: Bool,
        allowsJIT: Bool,
        allowsDyldEnvironmentVariables: Bool,
        disablesLibraryValidation: Bool,
        endpointSecurityClient: Bool,
        networkExtension: [String]
    ) {
        self.raw = raw
        self.isSandboxed = isSandboxed
        self.appGroups = appGroups
        self.appleEvents = appleEvents
        self.networkClient = networkClient
        self.networkServer = networkServer
        self.allowsJIT = allowsJIT
        self.allowsDyldEnvironmentVariables = allowsDyldEnvironmentVariables
        self.disablesLibraryValidation = disablesLibraryValidation
        self.endpointSecurityClient = endpointSecurityClient
        self.networkExtension = networkExtension
    }
}

public enum AppleEventsEntitlement: Codable, Hashable, Sendable {
    case anyApp
    case bundleIDs([String])
}

public struct CodeSigningInfo: Codable, Hashable, Sendable {
    public let teamIdentifier: String?
    public let signingIdentifier: String?       // CFBundleIdentifier-ish from CodeDirectory
    public let designatedRequirement: String?   // textual form
    public let hardenedRuntime: Bool
    public let isAdhocSigned: Bool
    public let isPlatformBinary: Bool           // Apple-platform binary (signed by Apple)
    public let validates: Bool                  // SecStaticCodeCheckValidityWithErrors == errSecSuccess
    public let validationError: String?

    public init(
        teamIdentifier: String?,
        signingIdentifier: String?,
        designatedRequirement: String?,
        hardenedRuntime: Bool,
        isAdhocSigned: Bool,
        isPlatformBinary: Bool,
        validates: Bool,
        validationError: String?
    ) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.designatedRequirement = designatedRequirement
        self.hardenedRuntime = hardenedRuntime
        self.isAdhocSigned = isAdhocSigned
        self.isPlatformBinary = isPlatformBinary
        self.validates = validates
        self.validationError = validationError
    }
}

public enum NotarizationStatus: Codable, Hashable, Sendable {
    case notarized           // spctl: source=Notarized Developer ID
    case developerIDOnly     // signed but not notarized (legacy or pre-notarization)
    case unsigned
    case rejected(String)    // spctl rejected, payload is its message
    case unknown(String)     // we couldn't run spctl, etc.
}

public struct URLSchemeDecl: Codable, Hashable, Sendable {
    public let name: String?
    public let role: String?       // Editor / Viewer / None
    public let schemes: [String]
}

public struct ATSException: Codable, Hashable, Sendable, Identifiable {
    public var id: String { domain }
    public let domain: String
    public let allowsInsecureHTTPLoads: Bool
    public let allowsArbitraryLoads: Bool
    public let includesSubdomains: Bool
    public let minimumTLSVersion: String?
    public let requiresForwardSecrecy: Bool

    public init(domain: String, allowsInsecureHTTPLoads: Bool,
                allowsArbitraryLoads: Bool, includesSubdomains: Bool,
                minimumTLSVersion: String?, requiresForwardSecrecy: Bool) {
        self.domain = domain
        self.allowsInsecureHTTPLoads = allowsInsecureHTTPLoads
        self.allowsArbitraryLoads = allowsArbitraryLoads
        self.includesSubdomains = includesSubdomains
        self.minimumTLSVersion = minimumTLSVersion
        self.requiresForwardSecrecy = requiresForwardSecrecy
    }
}

public struct ATSConfig: Codable, Hashable, Sendable {
    public let allowsArbitraryLoads: Bool
    public let allowsArbitraryLoadsForMedia: Bool
    public let allowsArbitraryLoadsInWebContent: Bool
    public let allowsLocalNetworking: Bool
    public let exceptionDomains: [ATSException]

    public init(allowsArbitraryLoads: Bool = false,
                allowsArbitraryLoadsForMedia: Bool = false,
                allowsArbitraryLoadsInWebContent: Bool = false,
                allowsLocalNetworking: Bool = false,
                exceptionDomains: [ATSException] = []) {
        self.allowsArbitraryLoads = allowsArbitraryLoads
        self.allowsArbitraryLoadsForMedia = allowsArbitraryLoadsForMedia
        self.allowsArbitraryLoadsInWebContent = allowsArbitraryLoadsInWebContent
        self.allowsLocalNetworking = allowsLocalNetworking
        self.exceptionDomains = exceptionDomains
    }

    public var hasAnyException: Bool {
        allowsArbitraryLoads || allowsArbitraryLoadsForMedia ||
        allowsArbitraryLoadsInWebContent || allowsLocalNetworking ||
        !exceptionDomains.isEmpty
    }
}

public struct DocumentTypeDecl: Codable, Hashable, Sendable {
    public let name: String?
    public let role: String?
    public let contentTypes: [String]      // UTType identifiers
    public let extensions: [String]        // legacy CFBundleTypeExtensions
}

public struct BundleRef: Codable, Hashable, Sendable {
    public let url: URL
    public let bundleID: String?
    public let teamID: String?
    public let isHelperApp: Bool
    public let isXPCService: Bool
    public let isLoginItem: Bool
}

public struct FrameworkRef: Codable, Hashable, Sendable {
    public let url: URL
    public let bundleID: String?
    public let version: String?
    public let teamID: String?
    public let isAppleSigned: Bool
}

public struct InferredCapability: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(category.rawValue):\(evidence.first ?? "")" }
    public let category: PrivacyCategory
    public let confidence: Confidence
    public let evidence: [String]    // e.g. "Imports CoreLocation.framework", "strings: ContactsUI"
    public let declaredButNotJustified: Bool   // if entitlement/usage-key was declared but binary doesn't reference the API
    public let inferredButNotDeclared: Bool    // if binary references the API but no usage-key/entitlement
}

public enum Confidence: String, Codable, Hashable, Sendable {
    case low, medium, high
}

public struct Finding: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(severity.rawValue):\(message.prefix(80))" }
    public enum Severity: String, Codable, Hashable, Sendable { case info, warn, error }
    public let severity: Severity
    public let message: String
    public let evidence: [String]
    /// Optional `KnowledgeBase` article identifier so the UI can show a
    /// detailed explainer next to the finding. Backward-compatible Codable.
    public let kbArticleID: String?

    public init(severity: Severity, message: String, evidence: [String], kbArticleID: String? = nil) {
        self.severity = severity
        self.message = message
        self.evidence = evidence
        self.kbArticleID = kbArticleID
    }

    private enum CodingKeys: String, CodingKey {
        case severity, message, evidence, kbArticleID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.severity = try c.decode(Severity.self, forKey: .severity)
        self.message = try c.decode(String.self, forKey: .message)
        self.evidence = try c.decode([String].self, forKey: .evidence)
        self.kbArticleID = try c.decodeIfPresent(String.self, forKey: .kbArticleID)
    }
}

/// Loose-typed plist value. Mirrors the Foundation plist subset.
public enum PlistValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dict([String: PlistValue])

    public static func from(_ any: Any) -> PlistValue {
        switch any {
        case let v as String: return .string(v)
        case let v as NSNumber:
            // Foundation gives us NSNumber for Bool/Int/Double; disambiguate.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            if CFNumberIsFloatType(v as CFNumber) { return .double(v.doubleValue) }
            return .int(v.int64Value)
        case let v as Date:   return .date(v)
        case let v as Data:   return .data(v)
        case let v as [Any]:  return .array(v.map(PlistValue.from))
        case let v as [String: Any]:
            return .dict(v.mapValues(PlistValue.from))
        default: return .string(String(describing: any))
        }
    }

    public var asString: String? { if case .string(let s) = self { return s } else { return nil } }
    public var asBool:   Bool?   { if case .bool(let b)   = self { return b } else { return nil } }
    public var asArray:  [PlistValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var asDict:   [String: PlistValue]? { if case .dict(let d) = self { return d } else { return nil } }
}
