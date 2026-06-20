import Foundation

/// Extracts network endpoints from a bundle's **resource files** — plist,
/// JSON, `.strings`, and other text configs — not just its Mach-O binaries.
///
/// Apps routinely keep their API base URLs, analytics endpoints, and
/// feature-config hosts in a bundled config file (a `Settings.bundle` plist,
/// a `config.json`, an SDK's `*-Info.plist`) rather than hard-coded in the
/// executable. The binary-string scan misses those entirely, so this closes
/// a real coverage gap for "what does this app talk to".
public enum EmbeddedResourceScanner {

    public struct Result: Hashable, Sendable {
        public var urls: Set<String> = []
        public var domains: Set<String> = []
        public init(urls: Set<String> = [], domains: Set<String> = []) {
            self.urls = urls; self.domains = domains
        }
    }

    /// A small, text-config-oriented extension set. We deliberately don't read
    /// every asset — images, fonts, and `.car` archives aren't text configs.
    private static let scannableExtensions: Set<String> = [
        "plist", "json", "strings", "xml", "cfg", "conf",
        "yaml", "yml", "txt", "config", "ini", "env"
    ]

    public static func scan(bundle: AppBundle,
                            maxFiles: Int = 400,
                            maxBytesPerFile: Int = 4 * 1024 * 1024) -> Result {
        scan(root: bundle.url, maxFiles: maxFiles, maxBytesPerFile: maxBytesPerFile)
    }

    /// Directory-rooted core (testable without constructing an `AppBundle`).
    static func scan(root: URL,
                     maxFiles: Int = 400,
                     maxBytesPerFile: Int = 4 * 1024 * 1024) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return result }
        var scanned = 0
        for case let url as URL in walker {
            if scanned >= maxFiles { break }
            let ext = url.pathExtension.lowercased()
            guard scannableExtensions.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            scanned += 1
            ingest(data: data.prefix(maxBytesPerFile), ext: ext, into: &result)
        }
        return result
    }

    private static func ingest(data: some DataProtocol, ext: String, into r: inout Result) {
        let bytes = Data(data)
        // Binary plists (and binary `.strings`) won't reveal their strings as
        // UTF-8 text, so deserialize and walk the value tree first.
        if ext == "plist" || ext == "strings" {
            if let obj = try? PropertyListSerialization.propertyList(
                from: bytes, options: [], format: nil) {
                walkPlist(obj, into: &r)
            }
        }
        // Then a plain-text pass — covers XML plists, JSON, text `.strings`,
        // and everything else. Lossy UTF-8 so odd bytes don't abort the scan.
        extractText(String(decoding: bytes, as: UTF8.self), into: &r)
    }

    private static func walkPlist(_ obj: Any, into r: inout Result) {
        switch obj {
        case let s as String: extractText(s, into: &r)
        case let arr as [Any]: for v in arr { walkPlist(v, into: &r) }
        case let dict as [String: Any]:
            for (k, v) in dict { extractText(k, into: &r); walkPlist(v, into: &r) }
        default: break
        }
    }

    /// Pull every http(s) URL (and its host) out of arbitrary text, plus bare
    /// host-like tokens that pass `DomainValidator` (which already rejects the
    /// reverse-DNS / cert-field / filename look-alikes).
    static func extractText(_ text: String, into r: inout Result) {
        // URLs — find ALL matches, not just the first.
        let urlPattern = #"https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+"#
        var search = text.startIndex
        while let m = text.range(of: urlPattern, options: .regularExpression,
                                 range: search..<text.endIndex) {
            let url = String(text[m])
            r.urls.insert(url)
            // Gate the URL's host through DomainValidator too: a URL followed by
            // in-charclass punctuation (",", ";", ")") yields a polluted host
            // like "a.example.com)" that must not leak into the domain list.
            if let host = URLComponents(string: url)?.host?.lowercased(),
               DomainValidator.isLikelyDomain(host) { r.domains.insert(host) }
            search = m.upperBound
        }
        // Bare domains — tokenize on non-host characters, validate strictly.
        // Bounded to smaller files: the split is the only expensive step and
        // large resource files are usually data, not config.
        guard text.utf8.count <= 256 * 1024 else { return }
        let tokens = text.split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        for t in tokens {
            let tok = String(t)
            if DomainValidator.isLikelyDomain(tok) { r.domains.insert(tok.lowercased()) }
        }
    }
}
