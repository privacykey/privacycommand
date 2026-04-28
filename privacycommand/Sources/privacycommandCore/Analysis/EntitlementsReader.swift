import Foundation
#if canImport(Security)
import Security
#endif

/// Pulls entitlements out of a bundle. We try the Security.framework path first
/// (`SecCodeCopySigningInformation` returns `kSecCodeInfoEntitlementsDict` for
/// embedded entitlements). When that fails (older bundles, ad-hoc signed,
/// store-receipt-stripped), we fall back to `codesign -d --entitlements :- <app>`.
public enum EntitlementsReader {

    public static func read(for bundle: AppBundle) -> Entitlements {
        let raw = readRawDict(for: bundle)
        return parse(raw)
    }

    // MARK: - Raw dict

    public static func readRawDict(for bundle: AppBundle) -> [String: Any] {
        if let dict = readViaSecurity(for: bundle) {
            return dict
        }
        return readViaCodesignCLI(for: bundle)
    }

    private static func readViaSecurity(for bundle: AppBundle) -> [String: Any]? {
        #if canImport(Security)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        ) == errSecSuccess, let info = infoCF as? [String: Any] else { return nil }
        if let entitlementsDict = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            return entitlementsDict
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func readViaCodesignCLI(for bundle: AppBundle) -> [String: Any] {
        let result = ProcessRunner.runSync(
            launchPath: "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", ":-", bundle.url.path],
            timeout: 15
        )
        guard !result.stdout.isEmpty,
              let data = result.stdout.data(using: .utf8) else { return [:] }
        // Output is an XML plist on stdout
        if let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            return plist
        }
        // Some versions of codesign prepend a header line; strip leading bytes
        // until we hit a `<?xml`.
        if let idx = result.stdout.range(of: "<?xml")?.lowerBound,
           let xmlData = result.stdout[idx...].data(using: .utf8),
           let plist = (try? PropertyListSerialization.propertyList(from: xmlData, format: nil)) as? [String: Any] {
            return plist
        }
        return [:]
    }

    // MARK: - Parsing

    public static func parse(_ raw: [String: Any]) -> Entitlements {
        let plistRaw = raw.mapValues(PlistValue.from)
        let isSandboxed = (raw["com.apple.security.app-sandbox"] as? Bool) ?? false
        let appGroups = (raw["com.apple.security.application-groups"] as? [String]) ?? []
        let networkClient = (raw["com.apple.security.network.client"] as? Bool) ?? false
        let networkServer = (raw["com.apple.security.network.server"] as? Bool) ?? false
        let allowsJIT = (raw["com.apple.security.cs.allow-jit"] as? Bool) ?? false
        let allowsDyld = (raw["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool) ?? false
        let disablesLib = (raw["com.apple.security.cs.disable-library-validation"] as? Bool) ?? false
        let esClient = (raw["com.apple.developer.endpoint-security.client"] as? Bool) ?? false
        let netExt = (raw["com.apple.developer.networking.networkextension"] as? [String]) ?? []

        // AppleEvents access: either a Bool (any app) or array of bundle IDs in
        // `com.apple.security.temporary-exception.apple-events` and modern
        // `com.apple.security.automation.apple-events`.
        var appleEventsEnt: AppleEventsEntitlement?
        if (raw["com.apple.security.automation.apple-events"] as? Bool) == true {
            appleEventsEnt = .anyApp
        }
        if let bundleIDs = raw["com.apple.security.temporary-exception.apple-events"] as? [String],
           !bundleIDs.isEmpty {
            appleEventsEnt = .bundleIDs(bundleIDs)
        }

        return Entitlements(
            raw: plistRaw,
            isSandboxed: isSandboxed,
            appGroups: appGroups,
            appleEvents: appleEventsEnt,
            networkClient: networkClient,
            networkServer: networkServer,
            allowsJIT: allowsJIT,
            allowsDyldEnvironmentVariables: allowsDyld,
            disablesLibraryValidation: disablesLib,
            endpointSecurityClient: esClient,
            networkExtension: netExt
        )
    }
}
