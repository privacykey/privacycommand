import Foundation

/// Scans an executable's printable strings for hard-coded credentials,
/// API keys, and other secrets.
///
/// Each rule encodes the well-known prefix or shape of a particular kind of
/// credential. Rules that hit are reported as `SecretFinding` objects with
/// the matched string truncated and partially masked, so a screenshot of
/// the report doesn't leak the raw secret to the world. The full match is
/// kept *only* in evidence so power-users can still verify on demand —
/// the UI is responsible for showing the masked form by default.
///
/// **False-positive policy.** We bias toward precision over recall. A rule
/// has to look unmistakably like the thing it's claiming to be, otherwise
/// we omit it. JWTs, for instance, must have three base64 segments
/// separated by dots *and* the middle segment must decode as JSON. AWS
/// keys use the `(AKIA|ASIA)[0-9A-Z]{16}` form. We'd rather miss a few
/// real secrets than alarm the user about every long base64 string in a
/// binary.
public enum SecretsScanner {

    public struct Result: Sendable, Hashable, Codable {
        public var findings: [SecretFinding]
        public init(findings: [SecretFinding] = []) { self.findings = findings }
    }

    /// Scan a Mach-O on disk. Bytes are streamed by the caller in chunks
    /// (or pre-extracted as the printable-string set) — we accept both.
    public static func scan(executable url: URL,
                            maxBytes: Int = 64 * 1024 * 1024,
                            timeoutSeconds: TimeInterval = 5) -> Result {
        var findings: [SecretFinding] = []
        var seen: Set<String> = []
        scanFile(url, label: url.lastPathComponent, maxBytes: maxBytes,
                 deadline: Date().addingTimeInterval(timeoutSeconds),
                 into: &findings, seen: &seen)
        return Result(findings: findings)
    }

    /// Scan several Mach-O files in one pass — the main executable plus
    /// embedded frameworks / helpers / XPC services — attributing each finding
    /// to the file (`label`) it came from. A secret that appears in more than
    /// one file is reported once, against the **first** file in `files`, so
    /// pass the main executable first for it to win attribution. `timeoutSeconds`
    /// is a *total* budget shared across all the files.
    public static func scan(files: [(url: URL, label: String)],
                            maxBytes: Int = 64 * 1024 * 1024,
                            timeoutSeconds: TimeInterval = 15) -> Result {
        var findings: [SecretFinding] = []
        var seen: Set<String> = []
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        for f in files {
            if Date() > deadline { break }
            scanFile(f.url, label: f.label, maxBytes: maxBytes,
                     deadline: deadline, into: &findings, seen: &seen)
        }
        return Result(findings: findings)
    }

    /// mmap a file and scan its bytes into the shared accumulator/dedup set.
    private static func scanFile(_ url: URL, label: String?, maxBytes: Int,
                                 deadline: Date,
                                 into findings: inout [SecretFinding],
                                 seen: inout Set<String>) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        scan(data: data.prefix(maxBytes), label: label, deadline: deadline,
             into: &findings, seen: &seen)
    }

    /// Scan a chunk of bytes. Walks null-terminated runs of ASCII printable
    /// bytes (mirroring `strings(1)`) and applies each rule to every run
    /// whose length plausibly matches.
    public static func scan(data: some DataProtocol, timeoutSeconds: TimeInterval = 5) -> Result {
        var findings: [SecretFinding] = []
        var seen: Set<String> = []
        scan(data: data, label: nil, deadline: Date().addingTimeInterval(timeoutSeconds),
             into: &findings, seen: &seen)
        return Result(findings: findings)
    }

    /// Workhorse: walk null-terminated printable runs, apply the rules, and
    /// accumulate into a shared `findings` / `seen` pair so multiple files can
    /// be deduplicated together. `label` becomes each finding's `sourceFile`.
    private static func scan(data: some DataProtocol, label: String?, deadline: Date,
                             into findings: inout [SecretFinding],
                             seen: inout Set<String>) {
        var current = [UInt8]()
        current.reserveCapacity(256)
        // `absOffset` is the byte position from the start of `data`; `runStart`
        // is where the current printable-string run began. We record runStart
        // on each finding so the UI can say *where* in the binary it was found.
        var absOffset = 0
        var runStart = 0

        @inline(__always) func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 16 else { return }
            if let s = String(bytes: current, encoding: .ascii) {
                applyRules(to: s, offset: runStart, label: label, into: &findings, seen: &seen)
            }
        }

        for b in data {
            if b >= 0x20 && b < 0x7F {
                if current.isEmpty { runStart = absOffset }
                current.append(b)
            } else {
                flush()
                if Date() > deadline { break }
            }
            absOffset += 1
        }
        flush()
    }

    // MARK: - Rules

    private static func applyRules(to s: String, offset: Int, label: String?,
                                   into findings: inout [SecretFinding],
                                   seen: inout Set<String>) {
        for rule in rules {
            guard s.count >= rule.minLength, s.count <= rule.maxLength else { continue }
            guard let m = rule.matcher(s) else { continue }
            if rule.gated, !isPlausibleSecret(m) { continue }
            if seen.insert(m).inserted {
                findings.append(SecretFinding(
                    kind: rule.kind, vendor: rule.vendor,
                    masked: maskSecret(m), rawLength: m.count,
                    confidence: rule.confidence, kbArticleID: rule.kbArticleID,
                    sourceFile: label, byteOffset: offset))
            }
        }
    }

    private struct Rule {
        let kind: SecretFinding.Kind
        let vendor: String
        let confidence: SecretFinding.Confidence
        let kbArticleID: String?
        let minLength: Int
        let maxLength: Int
        /// When true (default), a match is dropped unless it passes the
        /// placeholder / low-entropy gate. Structural markers (PEM headers)
        /// set this false.
        var gated = true
        /// Returns the matched substring, or nil if no match. Allows rules
        /// to do extra validation beyond regex (JWT json-decode, etc).
        let matcher: @Sendable (String) -> String?
    }

    /// Mask a secret for display: keep the first 4 and last 4 chars, replace
    /// the middle with `…`. Empty / very short secrets show as `[REDACTED]`.
    public static func maskSecret(_ s: String) -> String {
        if s.count <= 8 { return "[REDACTED]" }
        return String(s.prefix(4)) + "…" + String(s.suffix(4))
    }

    /// Reject matches that are obviously example/placeholder tokens or have
    /// implausibly low character variety for a real high-entropy credential —
    /// e.g. `sk_live_xxxx…`, `ghp_0000…`, `AIza…YOUR_KEY_HERE`.
    static func isPlausibleSecret(_ s: String) -> Bool {
        let lower = s.lowercased()
        let placeholders = ["your", "example", "placeholder", "redacted", "changeme",
                            "notreal", "insertkey", "apikeyhere", "yourtoken", "xxxxx"]
        if placeholders.contains(where: { lower.contains($0) }) { return false }
        if hasRun(s, of: 6) { return false }
        return shannonEntropyBits(of: s) >= 2.5
    }
    private static func hasRun(_ s: String, of n: Int) -> Bool {
        var last: Character? = nil, count = 0
        for c in s {
            if c == last { count += 1; if count >= n { return true } }
            else { last = c; count = 1 }
        }
        return false
    }
    private static func shannonEntropyBits(of s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0.0) { acc, c in let p = Double(c)/n; return acc - p * log2(p) }
    }

    // MARK: - Rule table

    private static let rules: [Rule] = [
        // AWS access key — AKIA / ASIA / AGPA / AROA / AIDA / ANPA / ANVA / ASCA prefix + 16 uppercase alphanumeric.
        Rule(kind: .awsAccessKey, vendor: "Amazon Web Services", confidence: .high,
             kbArticleID: "secret-aws-key", minLength: 20, maxLength: 20) { s in
            firstMatch(in: s, pattern: #"\b(?:AKIA|ASIA|AGPA|AROA|AIDA|ANPA|ANVA|ASCA)[0-9A-Z]{16}\b"#)
        },
        // AWS secret access key — 40 base64 chars right after `aws_secret_access_key=` is too noisy;
        // we intentionally don't ship a regex for the secret half (too prone to FP).

        // GitHub PAT — ghp_/gho_/ghu_/ghs_/ghr_ + 36+ alphanumerics.
        Rule(kind: .githubToken, vendor: "GitHub", confidence: .high,
             kbArticleID: "secret-github-token", minLength: 36, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#)
        },

        // Stripe live secret key.
        Rule(kind: .stripeKey, vendor: "Stripe", confidence: .high,
             kbArticleID: "secret-stripe-key", minLength: 20, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"\bsk_live_[0-9a-zA-Z]{16,}\b"#)
        },

        // Stripe restricted key.
        Rule(kind: .stripeKey, vendor: "Stripe (restricted)", confidence: .high,
             kbArticleID: "secret-stripe-key", minLength: 20, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"\brk_live_[0-9a-zA-Z]{16,}\b"#)
        },

        // Slack token.
        Rule(kind: .slackToken, vendor: "Slack", confidence: .high,
             kbArticleID: "secret-slack-token", minLength: 20, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#)
        },

        // Slack incoming webhook URL.
        Rule(kind: .slackWebhook, vendor: "Slack", confidence: .high,
             kbArticleID: "secret-slack-webhook", minLength: 60, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"https://hooks\.slack\.com/services/[A-Z0-9]+/[A-Z0-9]+/[A-Za-z0-9]{20,}"#)
        },

        // Discord webhook URL.
        Rule(kind: .discordWebhook, vendor: "Discord", confidence: .high,
             kbArticleID: "secret-discord-webhook", minLength: 60, maxLength: 255) { s in
            firstMatch(in: s, pattern: #"https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_\-]{40,}"#)
        },

        // Google API key — AIza + 35 alphanumerics. Frequent in Firebase apps.
        Rule(kind: .googleAPIKey, vendor: "Google", confidence: .high,
             kbArticleID: "secret-google-api-key", minLength: 39, maxLength: 39) { s in
            firstMatch(in: s, pattern: #"\bAIza[0-9A-Za-z\-_]{35}\b"#)
        },

        // SendGrid API key.
        Rule(kind: .sendgridKey, vendor: "SendGrid", confidence: .high,
             kbArticleID: "secret-sendgrid-key", minLength: 60, maxLength: 100) { s in
            firstMatch(in: s, pattern: #"\bSG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b"#)
        },

        // (Removed) Twilio account SID `AC<32 hex>`: an Account SID is a public
        // identifier, not a secret, and the pattern matched any "AC"+MD5/hex
        // blob. The Auth Token (the real secret) is 32 hex with no distinctive
        // prefix, so it can't be detected without false alarms.

        // Mailchimp API key — 32 hex + `-us` + 1-2 digits.
        Rule(kind: .mailchimpKey, vendor: "Mailchimp", confidence: .high,
             kbArticleID: "secret-mailchimp", minLength: 36, maxLength: 38) { s in
            firstMatch(in: s, pattern: #"\b[0-9a-f]{32}-us[0-9]{1,2}\b"#)
        },

        // PEM private key markers — even just the header is enough.
        Rule(kind: .pemPrivateKey, vendor: "PEM private key", confidence: .high,
             kbArticleID: "secret-private-key", minLength: 25, maxLength: 60, gated: false) { s in
            firstMatch(in: s, pattern: #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED |PGP )?PRIVATE KEY-----"#)
        },

        // Generic JWT — three base64url segments. We additionally require the
        // header to start with `{"alg":` (after base64-decoding) to keep
        // false-positives down.
        Rule(kind: .jwt, vendor: "JSON Web Token", confidence: .medium,
             kbArticleID: "secret-jwt", minLength: 30, maxLength: 8192) { s in
            // First-pass cheap regex.
            guard let candidate = firstMatch(in: s,
                                             pattern: #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\b"#) else {
                return nil
            }
            // Verify it actually decodes as a JWT header.
            let parts = candidate.split(separator: ".")
            guard parts.count == 3 else { return nil }
            let header = String(parts[0])
            // Pad to base64.
            let padded = header.padding(toLength: ((header.count + 3) / 4) * 4,
                                        withPad: "=", startingAt: 0)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard let bytes = Data(base64Encoded: padded),
                  let json = String(data: bytes, encoding: .utf8),
                  json.contains("\"alg\"") else { return nil }
            // Payload must ALSO decode to JSON — not just random base64 that
            // happens to start with eyJ and carry two dots.
            let payload = String(parts[1])
            let pPad = payload.padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            guard let pBytes = Data(base64Encoded: pPad),
                  let pJson = String(data: pBytes, encoding: .utf8),
                  pJson.contains("{") else { return nil }
            return candidate
        }
    ]

    /// First regex match (whole match) in `s`.
    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[r])
    }
}

// MARK: - Public types

public struct SecretFinding: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(kind.rawValue):\(masked)" }
    public let kind: Kind
    public let vendor: String
    /// Masked form, safe to show in screenshots — e.g. "AKIA…GHIJ".
    public let masked: String
    /// Length of the unmasked secret. Useful sanity-check.
    public let rawLength: Int
    public let confidence: Confidence
    public let kbArticleID: String?
    /// Where the secret was found: the Mach-O it was extracted from, as a path
    /// relative to the .app bundle when known (e.g. "Contents/MacOS/AppName").
    /// Today only the main executable is scanned. `nil` for findings produced
    /// before location tracking (old persisted reports decode it as nil).
    public var sourceFile: String?
    /// Byte offset, within `sourceFile`, of the start of the printable string
    /// the secret was matched in — enough to locate it in a hex/disassembly
    /// view. `nil` when unknown.
    public var byteOffset: Int?

    public enum Kind: String, Sendable, Hashable, Codable {
        case awsAccessKey      = "AWS access key"
        case githubToken       = "GitHub personal access token"
        case stripeKey         = "Stripe API key"
        case slackToken        = "Slack token"
        case slackWebhook      = "Slack incoming webhook"
        case discordWebhook    = "Discord webhook"
        case googleAPIKey      = "Google API key"
        case sendgridKey       = "SendGrid API key"
        case twilioSID         = "Twilio account SID"
        case mailchimpKey      = "Mailchimp API key"
        case pemPrivateKey     = "PEM private key"
        case jwt               = "JSON Web Token"
    }

    public enum Confidence: String, Sendable, Hashable, Codable {
        case high, medium, low
    }

    public init(kind: Kind, vendor: String, masked: String,
                rawLength: Int, confidence: Confidence, kbArticleID: String?,
                sourceFile: String? = nil, byteOffset: Int? = nil) {
        self.kind = kind
        self.vendor = vendor
        self.masked = masked
        self.rawLength = rawLength
        self.confidence = confidence
        self.kbArticleID = kbArticleID
        self.sourceFile = sourceFile
        self.byteOffset = byteOffset
    }
}
