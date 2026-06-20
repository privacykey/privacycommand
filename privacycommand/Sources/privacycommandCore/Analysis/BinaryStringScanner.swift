import Foundation

/// Inspects a Mach-O executable (or any data blob) for telltale strings that
/// suggest the use of privacy-sensitive frameworks, plus collects URLs,
/// domains, and hard-coded paths.
///
/// We deliberately use a streaming `String(decoding:as:)` over chunks rather
/// than shelling out to `strings(1)` so that this works in a sandboxed test
/// runner. We **do** also support shelling out to `strings(1)` as a fast path
/// for very large binaries when the user is running outside a sandbox.
public enum BinaryStringScanner {

    public struct Result: Hashable, Sendable {
        public var foundFrameworkSymbols: Set<String> = []
        public var urls: Set<String> = []
        public var domains: Set<String> = []
        public var paths: Set<String> = []
    }

    /// Scan a single Mach-O on disk. Caps work at `maxBytes` and `timeoutSeconds`.
    public static func scan(
        executable url: URL,
        symbols: [String] = defaultPrivacySymbols,
        maxBytes: Int = 64 * 1024 * 1024,
        timeoutSeconds: TimeInterval = 5
    ) -> Result {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return Result() }
        return scan(data: data.prefix(maxBytes), symbols: symbols, timeoutSeconds: timeoutSeconds)
    }

    /// Core scan over an arbitrary byte buffer. Extracts ASCII strings (a la
    /// `strings -a`) **and** UTF-16LE wide strings -- Electron / cross-platform
    /// ports and CFString literals store endpoints as wide strings the ASCII
    /// walk skips -- and decodes embedded base64 / hex blobs one level deep so
    /// lightly-obfuscated endpoints still surface.
    public static func scan(data bytes: some DataProtocol,
                            symbols: [String] = defaultPrivacySymbols,
                            timeoutSeconds: TimeInterval = 5) -> Result {
        var result = Result()
        let symbolSet = Set(symbols)
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        // Pass 1 -- ASCII printable runs.
        var current = [UInt8]()
        current.reserveCapacity(256)
        for b in bytes {
            if Date() > deadline { break }
            if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                if current.count >= 4, let s = String(bytes: current, encoding: .ascii) {
                    ingest(s, symbols: symbolSet, into: &result)
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 4, let s = String(bytes: current, encoding: .ascii) {
            ingest(s, symbols: symbolSet, into: &result)
        }

        // Pass 2 -- UTF-16LE wide runs: a printable ASCII byte followed by 0x00.
        // (We only decode the ASCII subset -- sufficient for the endpoints,
        // paths, and symbols we care about, which are all ASCII.)
        var wide = [UInt8]()
        wide.reserveCapacity(256)
        var j = bytes.startIndex
        let hi = bytes.endIndex
        while j < hi {
            if Date() > deadline { break }
            let next = bytes.index(after: j)
            if next < hi, bytes[j] >= 0x20, bytes[j] < 0x7F, bytes[next] == 0 {
                wide.append(bytes[j])
                j = bytes.index(after: next)
            } else {
                if wide.count >= 4, let s = String(bytes: wide, encoding: .ascii) {
                    ingest(s, symbols: symbolSet, into: &result)
                }
                wide.removeAll(keepingCapacity: true)
                j = next
            }
        }
        if wide.count >= 4, let s = String(bytes: wide, encoding: .ascii) {
            ingest(s, symbols: symbolSet, into: &result)
        }
        return result
    }

    /// Scan many Mach-Os and merge their results. Used to cover EMBEDDED code —
    /// frameworks, XPC services, helpers, and `.appex` extensions — whose
    /// network endpoints the main-executable scan misses (an SDK's domains
    /// usually live in its embedded framework binary). Bounded by `maxFiles`
    /// and a smaller per-file cap so a pathological bundle can't stall analysis;
    /// callers get the union of whatever was scanned.
    public static func scan(executables urls: [URL],
                            symbols: [String] = defaultPrivacySymbols,
                            maxBytesPerFile: Int = 16 * 1024 * 1024,
                            timeoutSecondsPerFile: TimeInterval = 3,
                            maxFiles: Int = 600) -> Result {
        var merged = Result()
        for url in urls.prefix(maxFiles) {
            let r = scan(executable: url, symbols: symbols,
                         maxBytes: maxBytesPerFile, timeoutSeconds: timeoutSecondsPerFile)
            merged.foundFrameworkSymbols.formUnion(r.foundFrameworkSymbols)
            merged.urls.formUnion(r.urls)
            merged.domains.formUnion(r.domains)
            merged.paths.formUnion(r.paths)
        }
        return merged
    }

    /// Token (word-boundary) containment: `token` must not be flanked by
    /// identifier characters, so "AVCaptureDevice" matches the bare symbol or
    /// "_OBJC_CLASS_$_AVCaptureDevice" but NOT "AVCaptureDeviceInput" or
    /// "CGDisplayStreamUpdate" — killing substring-collision false positives.
    // NOTE: only letters/digits break the boundary. Underscores must NOT — the
    // dominant Mach-O symbol forms are _OBJC_CLASS_$_AVCaptureDevice and _ptrace,
    // where the token is preceded by "_"; counting "_" as identifier silently
    // missed nearly every symbol (camera/mic/location/bluetooth/ptrace/...).
    private static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    private static func containsToken(_ s: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var from = s.startIndex
        while let r = s.range(of: token, range: from..<s.endIndex) {
            let beforeOK = r.lowerBound == s.startIndex || !isIdentChar(s[s.index(before: r.lowerBound)])
            let afterOK = r.upperBound == s.endIndex || !isIdentChar(s[r.upperBound])
            if beforeOK && afterOK { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }

    private static func ingest(_ s: String, symbols: Set<String>, into r: inout Result, depth: Int = 0) {
        // Symbol hits.
        for sym in symbols where Self.containsToken(s, sym) {
            r.foundFrameworkSymbols.insert(sym)
        }
        // URLs (very simple: starts with http(s):// or file:// up to whitespace)
        if let m = s.range(of: #"https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+"#, options: .regularExpression) {
            r.urls.insert(String(s[m]))
        }
        // Bare domains. `DomainValidator` rejects the look-alikes that used to
        // leak in here — reverse-DNS bundle IDs, cert fields, file names — by
        // requiring a real IANA TLD and a non-reverse-DNS first label.
        if !s.contains("/") && !s.contains(" "), DomainValidator.isLikelyDomain(s) {
            r.domains.insert(s.lowercased())
        }
        // Hard-coded paths
        if s.hasPrefix("/") || s.hasPrefix("~/") {
            if isInterestingPath(s) {
                r.paths.insert(s)
            }
        }
        // Lightly-obfuscated endpoints: decode an embedded base64/hex blob one
        // level deep and re-ingest if it's mostly-printable ASCII.
        if depth == 0 { decodeBlobs(in: s, symbols: symbols, into: &r) }
    }

    /// Decode a base64 or hex run embedded in `s`; if it decodes to
    /// overwhelmingly printable ASCII, re-ingest it (depth 1 -- recursion-
    /// guarded so a decoded blob can't trigger another decode pass).
    private static func decodeBlobs(in s: String, symbols: Set<String>, into r: inout Result) {
        guard s.utf8.count >= 24 else { return }
        if let m = s.range(of: #"[A-Za-z0-9+/]{24,}={0,2}"#, options: .regularExpression),
           let data = Data(base64Encoded: String(s[m])),
           let decoded = printableASCII(data) {
            ingest(decoded, symbols: symbols, into: &r, depth: 1)
        }
        if let m = s.range(of: #"(?:[0-9a-fA-F]{2}){20,}"#, options: .regularExpression),
           let data = hexDecode(String(s[m])),
           let decoded = printableASCII(data) {
            ingest(decoded, symbols: symbols, into: &r, depth: 1)
        }
    }

    /// Bytes as a String only when they're overwhelmingly printable ASCII /
    /// whitespace -- so we never re-ingest decoded binary noise (keys, images).
    private static func printableASCII(_ data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        var printable = 0
        for b in data where (b >= 0x20 && b < 0x7F) || b == 0x09 || b == 0x0A || b == 0x0D {
            printable += 1
        }
        guard Double(printable) / Double(data.count) >= 0.9 else { return nil }
        return String(bytes: data.filter { $0 != 0 }, encoding: .utf8)
    }

    private static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let h = nib(chars[i]), let l = nib(chars[i + 1]) else { return nil }
            out.append(h << 4 | l)
            i += 2
        }
        return out
    }

    private static func isInterestingPath(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("/system/") { return false }
        if lower.hasPrefix("/usr/lib/") { return false }
        if lower.hasPrefix("/usr/share/") { return false }
        if lower == "/" { return false }
        // We want paths that are at least three components deep — these are
        // much more likely to be deliberate references than e.g. "/Users".
        let comps = s.split(separator: "/")
        return comps.count >= 2 && s.count <= 240
    }

    /// The default symbol set we look for. Hits are evidence — not proof — that
    /// the app uses a particular sensitive API.
    public static let defaultPrivacySymbols: [String] = [
        // Camera / Mic
        "AVCaptureDevice", "AVCaptureSession",
        // Screen capture
        "ScreenCaptureKit", "CGDisplayStream", "CGWindowListCreateImage",
        // Photos
        "PHPhotoLibrary", "PHAsset",
        // Contacts
        "CNContactStore", "CNContact",
        // Calendar / Reminders
        "EKEventStore", "EKEvent", "EKReminder",
        // Location
        "CLLocationManager", "CLAuthorizationStatus",
        // Bluetooth
        "CBCentralManager", "CBPeripheral",
        // Speech
        "SFSpeechRecognizer",
        // Accessibility
        "AXIsProcessTrusted", "AXUIElementCopyAttributeValue",
        // Apple Events / Automation
        "OSAScript", "NSAppleScript", "AESendMessage",
        // HomeKit
        "HMHome", "HMAccessory",
        // Local network
        "NSNetService", "NWConnection",
        // Keychain
        "SecKeychainItem", "kSecClassGenericPassword",
        // System Events (UI scripting)
        "com.apple.systemevents",
        // Login items
        "SMLoginItemSetEnabled",
        // Code-injection style
        "DYLD_INSERT_LIBRARIES",
        // Endpoint Security (target itself is an ES client?)
        "es_new_client"
    ]
}
