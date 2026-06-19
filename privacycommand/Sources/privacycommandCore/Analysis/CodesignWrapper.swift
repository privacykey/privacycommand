import Foundation
#if canImport(Security)
import Security
#endif

/// Reads code-signing information for an `.app` bundle.
///
/// Prefers `Security.framework` (`SecStaticCodeCreateWithPath`,
/// `SecCodeCopySigningInformation`) and falls back to shelling out to
/// `codesign(1)` and `spctl(8)` for fields the API doesn't expose cleanly.
public enum CodesignWrapper {

    public static func info(for bundle: AppBundle) -> CodeSigningInfo {
        #if canImport(Security)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundle.url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return CodeSigningInfo(
                teamIdentifier: nil,
                signingIdentifier: nil,
                designatedRequirement: nil,
                hardenedRuntime: false,
                isAdhocSigned: false,
                isPlatformBinary: false,
                validates: false,
                validationError: "SecStaticCodeCreateWithPath failed: \(createStatus)"
            )
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
            &infoCF
        )
        let dict = (infoCF as? [String: Any]) ?? [:]

        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let teamName = developerName(from: dict)
        let signingID = dict[kSecCodeInfoIdentifier as String] as? String
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0

        // Bits documented in <Security/SecCode.h>
        // 0x00010000 kSecCodeSignatureHardenedRuntime
        // 0x00000002 kSecCodeSignatureAdhoc
        let hardened = (flags & 0x00010000) != 0
        let adhoc    = (flags & 0x00000002) != 0
        let platform = (dict[kSecCodeInfoPlatformIdentifier as String] != nil)

        var requirement: SecRequirement?
        var requirementText: String?
        if SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
           let req = requirement {
            var cfText: CFString?
            if SecRequirementCopyString(req, [], &cfText) == errSecSuccess, let text = cfText as String? {
                requirementText = text
            }
        }

        var validateError: Unmanaged<CFError>?
        let validateStatus = SecStaticCodeCheckValidityWithErrors(code, [], nil, &validateError)
        let validates = validateStatus == errSecSuccess
        let validateMessage: String? = validates ? nil : (validateError?.takeRetainedValue() as Error?)?.localizedDescription
            ?? "SecStaticCodeCheckValidityWithErrors=\(validateStatus)"
        _ = infoStatus

        return CodeSigningInfo(
            teamIdentifier: teamID,
            teamName: teamName,
            signingIdentifier: signingID,
            designatedRequirement: requirementText,
            hardenedRuntime: hardened,
            isAdhocSigned: adhoc,
            isPlatformBinary: platform,
            validates: validates,
            validationError: validateMessage
        )
        #else
        return CodeSigningInfo(
            teamIdentifier: nil, signingIdentifier: nil, designatedRequirement: nil,
            hardenedRuntime: false, isAdhocSigned: false, isPlatformBinary: false,
            validates: false, validationError: "Security.framework unavailable on this build")
        #endif
    }

    #if canImport(Security)
    /// Expand the Team ID into the developer / organization name by
    /// reading the leaf signing certificate's common name. For a
    /// developer-identity cert this is shaped like
    /// "Developer ID Application: ACME Inc. (AB12CD34EF)" — we return
    /// the "ACME Inc." in the middle. Returns `nil` when the signature
    /// carries no developer-identity cert (ad-hoc, unsigned, or an
    /// App-Store-resigned leaf such as "Apple Mac OS Application
    /// Signing", which has no developer name and no Team-ID suffix).
    private static func developerName(from dict: [String: Any]) -> String? {
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        var cn: CFString?
        guard SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess,
              let commonName = cn as String? else { return nil }
        return developerName(fromCommonName: commonName)
    }

    /// Pull the org name out of a signing-cert common name. The
    /// trailing "(<10-char Team ID>)" is the discriminator: only
    /// developer-identity certs carry it, so requiring it keeps us from
    /// mistaking Apple's re-signing identity for the developer.
    /// Exposed `internal` so it can be unit-tested without a real cert.
    static func developerName(fromCommonName commonName: String) -> String? {
        guard let teamSuffix = commonName.range(
            of: #"\s*\([A-Z0-9]{10}\)\s*$"#, options: .regularExpression)
        else { return nil }
        var name = String(commonName[..<teamSuffix.lowerBound])
        // Drop the leading role prefix ("Developer ID Application: ",
        // "Apple Distribution: ", "Apple Development: ", …).
        if let colon = name.range(of: ": ") {
            name = String(name[colon.upperBound...])
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif

    public static func notarization(for bundle: AppBundle) -> NotarizationStatus {
        // `spctl --assess -vvv <app>` is the documented way to query Gatekeeper assessment.
        // Output is parsed conservatively; spctl can require network on first lookup.
        let result = ProcessRunner.runSync(
            launchPath: "/usr/sbin/spctl",
            arguments: ["--assess", "-vvv", bundle.url.path],
            timeout: 15
        )
        let combined = (result.stdout + "\n" + result.stderr).lowercased()
        if combined.contains("source=notarized developer id") {
            return .notarized
        }
        if combined.contains("source=developer id") {
            return .developerIDOnly
        }
        if combined.contains("source=apple system") || combined.contains("source=apple") {
            return .notarized
        }
        if combined.contains("rejected") {
            return .rejected(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        if combined.contains("unsigned") || combined.contains("not signed") {
            return .unsigned
        }
        if !result.success {
            return .unknown("spctl exit=\(result.exitCode) stderr=\(result.stderr.prefix(160))")
        }
        return .unknown(result.stdout.prefix(160).description)
    }
}
