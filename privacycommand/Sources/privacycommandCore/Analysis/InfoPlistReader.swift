import Foundation

public enum InfoPlistReader {

    public struct Result {
        public var declaredPrivacyKeys: [PrivacyKey]
        public var urlSchemes: [URLSchemeDecl]
        public var documentTypes: [DocumentTypeDecl]
        public var atsConfig: ATSConfig?
        public var raw: [String: Any]
    }

    public static func read(for bundle: AppBundle, db: PrivacyKeyDatabase) -> Result {
        let infoPlistURL = bundle.url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return Result(declaredPrivacyKeys: [], urlSchemes: [], documentTypes: [], raw: [:])
        }

        var keys: [PrivacyKey] = []
        for (k, v) in plist where k.hasPrefix("NS") && k.hasSuffix("UsageDescription") {
            let entry = db.entry(forKey: k)
            keys.append(PrivacyKey(
                rawKey: k,
                category: entry?.category ?? .unknown,
                humanLabel: entry?.label ?? k,
                purposeString: (v as? String) ?? ""
            ))
        }
        // Sort deterministically for reproducible reports.
        keys.sort { $0.rawKey < $1.rawKey }

        let urlSchemes = parseURLSchemes(plist: plist)
        let docTypes = parseDocumentTypes(plist: plist)
        let ats = parseATS(plist: plist)

        return Result(declaredPrivacyKeys: keys,
                      urlSchemes: urlSchemes,
                      documentTypes: docTypes,
                      atsConfig: ats,
                      raw: plist)
    }

    /// Parse `NSAppTransportSecurity`. Returns nil when ATS is at default
    /// (not declared). When declared, returns the flag set + per-domain
    /// exception list.
    private static func parseATS(plist: [String: Any]) -> ATSConfig? {
        guard let ats = plist["NSAppTransportSecurity"] as? [String: Any] else { return nil }
        let arbitrary = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        let media     = (ats["NSAllowsArbitraryLoadsForMedia"] as? Bool) ?? false
        let web       = (ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool) ?? false
        let local     = (ats["NSAllowsLocalNetworking"] as? Bool) ?? false

        var exceptions: [ATSException] = []
        if let domains = ats["NSExceptionDomains"] as? [String: Any] {
            for (domain, raw) in domains {
                guard let d = raw as? [String: Any] else { continue }
                exceptions.append(ATSException(
                    domain: domain,
                    allowsInsecureHTTPLoads: (d["NSExceptionAllowsInsecureHTTPLoads"] as? Bool) ?? false,
                    allowsArbitraryLoads:    (d["NSExceptionAllowsArbitraryLoads"]    as? Bool) ?? false,
                    includesSubdomains:      (d["NSIncludesSubdomains"]               as? Bool) ?? false,
                    minimumTLSVersion:       d["NSExceptionMinimumTLSVersion"]        as? String,
                    requiresForwardSecrecy:  (d["NSExceptionRequiresForwardSecrecy"]  as? Bool) ?? true
                ))
            }
        }
        return ATSConfig(
            allowsArbitraryLoads: arbitrary,
            allowsArbitraryLoadsForMedia: media,
            allowsArbitraryLoadsInWebContent: web,
            allowsLocalNetworking: local,
            exceptionDomains: exceptions.sorted { $0.domain < $1.domain }
        )
    }

    private static func parseURLSchemes(plist: [String: Any]) -> [URLSchemeDecl] {
        guard let array = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return array.map { entry in
            URLSchemeDecl(
                name: entry["CFBundleURLName"] as? String,
                role: entry["CFBundleTypeRole"] as? String,
                schemes: (entry["CFBundleURLSchemes"] as? [String]) ?? []
            )
        }
    }

    private static func parseDocumentTypes(plist: [String: Any]) -> [DocumentTypeDecl] {
        guard let array = plist["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        return array.map { entry in
            DocumentTypeDecl(
                name: entry["CFBundleTypeName"] as? String,
                role: entry["CFBundleTypeRole"] as? String,
                contentTypes: (entry["LSItemContentTypes"] as? [String]) ?? [],
                extensions: (entry["CFBundleTypeExtensions"] as? [String]) ?? []
            )
        }
    }
}
