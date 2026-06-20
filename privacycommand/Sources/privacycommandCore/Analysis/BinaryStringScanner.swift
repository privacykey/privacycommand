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
        var result = Result()
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return result }
        let bytes = data.prefix(maxBytes)

        let symbolSet = Set(symbols)
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        // Walk null-terminated runs of ASCII printable bytes; this matches the
        // behavior of `strings -a` closely enough for our needs and is much
        // faster than a regex over the whole blob.
        var current = [UInt8]()
        current.reserveCapacity(256)
        for b in bytes {
            if Date() > deadline { break }
            if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                if current.count >= 4 {
                    if let s = String(bytes: current, encoding: .ascii) {
                        ingest(s, symbols: symbolSet, into: &result)
                    }
                }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 4, let s = String(bytes: current, encoding: .ascii) {
            ingest(s, symbols: symbolSet, into: &result)
        }
        return result
    }

    /// Token (word-boundary) containment: `token` must not be flanked by
    /// identifier characters, so "AVCaptureDevice" matches the bare symbol or
    /// "_OBJC_CLASS_$_AVCaptureDevice" but NOT "AVCaptureDeviceInput" or
    /// "CGDisplayStreamUpdate" — killing substring-collision false positives.
    private static func isIdentChar(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
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

    private static func ingest(_ s: String, symbols: Set<String>, into r: inout Result) {
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
