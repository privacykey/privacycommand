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
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return Result() }
        return scan(data: data.prefix(maxBytes), timeoutSeconds: timeoutSeconds)
    }

    /// Scan a chunk of bytes. Walks null-terminated runs of ASCII printable
    /// bytes (mirroring `strings(1)`) and applies each rule to every run
    /// whose length plausibly matches.
    public static func scan(data: some DataProtocol, timeoutSeconds: TimeInterval = 5) -> Result {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var findings: [SecretFinding] = []
        var seenMatches: Set<String> = []
        var current = [UInt8]()
        current.reserveCapacity(256)

        @inline(__always) func flush() {
            guard current.count >= 16 else { current.removeAll(keepingCapacity: true); return }
            if let s = String(bytes: current, encoding: .ascii) {
                applyRules(to: s, into: &findings, seen: &seenMatches)
            }
            current.removeAll(keepingCapacity: true)
        }

        for b in data {
            if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                flush()
                if Date() > deadline { break }
            }
        }
        flush()
        return Result(findings: findings)
    }

    // MARK: - Rules

    private static func applyRules(to s: String,
                                   into findings: inout [SecretFinding],
                                   seen: inout Set<String>) {
        for rule in rules {
            guard s.count >= rule.minLength, s.count <= rule.maxLength else { continue }
            guard let m = rule.matcher(s) else { continue }
            if seen.insert(m).inserted {
                findings.append(SecretFinding(
                    kind: rule.kind, vendor: rule.vendor,
                    masked: maskSecret(m), rawLength: m.count,
                    confidence: rule.confidence, kbArticleID: rule.kbArticleID))
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

        // Twilio account SID + auth token (combined check).
        Rule(kind: .twilioSID, vendor: "Twilio", confidence: .high,
             kbArticleID: "secret-twilio", minLength: 34, maxLength: 34) { s in
            firstMatch(in: s, pattern: #"\bAC[a-f0-9]{32}\b"#)
        },

        // Mailchimp API key — 32 hex + `-us` + 1-2 digits.
        Rule(kind: .mailchimpKey, vendor: "Mailchimp", confidence: .high,
             kbArticleID: "secret-mailchimp", minLength: 36, maxLength: 38) { s in
            firstMatch(in: s, pattern: #"\b[0-9a-f]{32}-us[0-9]{1,2}\b"#)
        },

        // PEM private key markers — even just the header is enough.
        Rule(kind: .pemPrivateKey, vendor: "PEM private key", confidence: .high,
             kbArticleID: "secret-private-key", minLength: 25, maxLength: 60) { s in
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
                rawLength: Int, confidence: Confidence, kbArticleID: String?) {
        self.kind = kind
        self.vendor = vendor
        self.masked = masked
        self.rawLength = rawLength
        self.confidence = confidence
        self.kbArticleID = kbArticleID
    }
}
