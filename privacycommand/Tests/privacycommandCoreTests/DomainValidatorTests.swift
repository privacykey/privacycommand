import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Covers the domain false-positive fix: hard-coded "domains" extracted from a
/// binary must be real hostnames, not reverse-DNS bundle IDs, cert fields, or
/// file names.
final class DomainValidatorTests: XCTestCase {

    func testAcceptsRealDomains() {
        for host in ["zoom.us", "google-analytics.com", "api.mixpanel.com",
                     "sub.example.co.uk", "example.io", "g.co", "x.ai"] {
            XCTAssertTrue(DomainValidator.isLikelyDomain(host), "should accept \(host)")
        }
    }

    func testRejectsInvalidTLDs() {
        // Cert fields, file names, and random fragments ending in a non-TLD.
        for junk in ["subject.ou", "jq.oje", "config.plist",
                     "image.png", "index.html", "data.bin"] {
            XCTAssertFalse(DomainValidator.isLikelyDomain(junk), "should reject \(junk)")
        }
    }

    func testRejectsReverseDNSIdentifiers() {
        // Bundle IDs / entitlement keys — rejected even when the final label is
        // itself a real TLD word (.app, .dev), because the first label is a
        // reverse-DNS root.
        for id in ["com.apple.security.device.usb", "com.google.chrome.beta",
                   "org.sparkle-project.Sparkle", "io.tailscale.ipn.macsys",
                   "com.example.app", "net.foo.dev"] {
            XCTAssertFalse(DomainValidator.isLikelyDomain(id), "should reject \(id)")
        }
    }

    func testRejectsDotLocal() {
        XCTAssertFalse(DomainValidator.isLikelyDomain("printer.local"))
    }

    /// Documents the deliberate residual: a short fragment ending in a real
    /// ccTLD (`g.sa`) is structurally identical to a legitimate short domain
    /// (`g.co`), so the "TLD + reverse-DNS" policy keeps it. If this ever flips,
    /// it's a policy change worth noticing — hence the explicit assertion.
    func testKnownResidualRealCCTLDFragmentsAreKept() {
        // `g.sa` (short fragment) and `issuer.cn` (cert field) both end in a
        // real ccTLD, so they're indistinguishable from `g.co` / `mail.cn` and
        // are kept by design. If this flips, it's a policy change worth noticing.
        for residual in ["g.sa", "issuer.cn"] {
            XCTAssertTrue(DomainValidator.isLikelyDomain(residual),
                          "\(residual) is a known residual under the TLD+reverse-DNS policy")
        }
    }
}
