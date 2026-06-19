import Foundation

/// Decides whether a string lifted from a binary is plausibly a real,
/// registrable **hostname** versus a compiled fragment that merely *looks*
/// domain-shaped.
///
/// **Why this exists.** The binary-string scanner used to accept anything of
/// the form `label.label…[a-z]{2,}` as a "hard-coded domain". That structure
/// matches a lot of things that aren't hostnames:
///   • reverse-DNS identifiers — `com.apple.security.device.usb`, `com.google.chrome.beta`
///   • X.509 / ASN.1 field fragments — `subject.ou`, `issuer.cn`
///   • file names — `config.plist`, `image.png`, `index.html`
///   • random dotted fragments — `jq.oje`, `g.sa`
/// All of these polluted the "hard-coded domains" list and the compare-runs
/// diff with false positives.
///
/// **The two checks that remove the bulk of them:**
///   1. The last label must be a real IANA TLD (`KnownTLDs`). Kills `.ou`,
///      `.usb`, `.png`, `.plist`, `.oje`, and the long tail of file-extension /
///      symbol noise.
///   2. The first label must not be a reverse-DNS root (`com`, `org`, `io`, …).
///      Kills bundle IDs / entitlement keys even when they happen to end in a
///      word that *is* a TLD (`com.example.app`, `org.foo.dev`).
///
/// **Known residual.** A short fragment that coincidentally ends in a real
/// ccTLD — e.g. `g.sa` — is *structurally identical* to a legitimate short
/// domain like `g.co`, `x.ai`, or `t.co`. No structural rule separates them,
/// so we deliberately keep them rather than risk dropping real domains. This
/// is a conscious precision/recall trade-off, not an oversight.
public enum DomainValidator {

    /// Reverse-DNS roots. A "domain" whose *first* label is one of these is
    /// almost certainly a reverse-DNS identifier (`com.apple.…`), not a host.
    /// Kept deliberately small — these are the roots that actually start
    /// Apple-ecosystem bundle IDs and entitlement keys.
    static let reverseDNSRoots: Set<String> = [
        "com", "org", "net", "io", "edu", "gov", "mil", "int"
    ]

    /// Structural shape of a hostname: one or more dotted labels ending in an
    /// alphabetic TLD of two or more characters. Mirrors the scanner's original
    /// regex so behaviour is identical up to the new TLD / reverse-DNS checks.
    private static let shapeRegex =
        #"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$"#

    /// True when `host` is plausibly a real registrable domain.
    public static func isLikelyDomain(_ host: String) -> Bool {
        let h = host.lowercased()
        guard h.range(of: shapeRegex, options: .regularExpression) != nil else { return false }
        if h.hasSuffix(".local") { return false }

        let labels = h.split(separator: ".").map(String.init)
        guard let tld = labels.last, KnownTLDs.set.contains(tld) else { return false }
        if let first = labels.first, reverseDNSRoots.contains(first) { return false }
        return true
    }
}
