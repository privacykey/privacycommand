import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 6 — false positives in secret detection and domain classification.
///
/// Secret-shaped fixtures are assembled from fragments at runtime so the literal
/// credential patterns never appear in this source file (otherwise GitHub push
/// protection blocks the commit). The scanner sees the fully assembled value.
final class SecretsAndDomainFPTests: XCTestCase {

    private func secretKinds(_ s: String) -> Set<SecretFinding.Kind> {
        Set(SecretsScanner.scan(data: Data(s.utf8)).findings.map(\.kind))
    }
    private func sk(_ body: String) -> String { "sk_" + "live_" + body }   // Stripe live-key shape
    private func gh(_ body: String) -> String { "ghp" + "_" + body }       // GitHub PAT shape
    private func aws(_ body: String) -> String { "AKI" + "A" + body }      // AWS access-key shape
    private func ac(_ hex: String) -> String { "A" + "C" + hex }           // Twilio SID shape

    // MARK: - Secret placeholder / entropy gate

    func testPlaceholderTokensAreNotReportedAsSecrets() {
        XCTAssertFalse(secretKinds(sk("YOURsecretkeygoeshereabcd")).contains(.stripeKey))
        XCTAssertFalse(secretKinds(gh(String(repeating: "0", count: 40))).contains(.githubToken))
        XCTAssertFalse(secretKinds(sk(String(repeating: "x", count: 24))).contains(.stripeKey))
    }

    func testRealHighEntropySecretsStillDetected() {
        XCTAssertTrue(secretKinds(gh("aB3xK9mZ2qWvL7pR4tY1nC8sD6fG0hJ5kE2Q")).contains(.githubToken))
        XCTAssertTrue(secretKinds(aws("3X7QPL9ZK2WMN4VT")).contains(.awsAccessKey))
        XCTAssertTrue(secretKinds(sk("9zT2mK7pQ4wR1nB8xL5vC3dF")).contains(.stripeKey))
    }

    func testTwilioAccountSIDProducesNoFindingAtAll() {
        // Non-vacuous: assert zero findings of ANY kind (guards re-introduction
        // under any kind, not just the now-unreachable .twilioSID).
        XCTAssertTrue(SecretsScanner.scan(data: Data(ac("0123456789abcdef0123456789abcdef").utf8)).findings.isEmpty)
    }

    func testRealPrefixedTokenWithRepeatedRunStillDetected() {
        // A genuine high-entropy GitHub PAT that happens to contain a 6-char run
        // must NOT be suppressed (the old hasRun gate wrongly dropped these).
        XCTAssertTrue(secretKinds(gh("aaaaaaK9mZ2qWvL7pR4tY1nC8sD6fG0hJ5kE2QpT9w")).contains(.githubToken))
    }

    func testJWTRequiresValidJSONPayload() {
        // header {"alg":"HS256","typ":"JWT"} payload {"sub":"1234567890"} sig
        let jwt = "eyJ" + "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" + "."
            + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "."
            + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertTrue(secretKinds(jwt).contains(.jwt))
    }

    func testPEMHeaderStillReportedDespiteGate() {
        XCTAssertTrue(secretKinds("-----BEGIN RSA PRIVATE KEY-----").contains(.pemPrivateKey))
    }

    // MARK: - Domain reclassification

    func testDomainReclassifications() {
        let c = DomainClassifier()
        XCTAssertEqual(c.classify("myaccount.blob.core.windows.net").category, .cdn,
                       "An Azure customer backend is infra/hosting, not Microsoft tracking")
        XCTAssertEqual(c.classify("www.googletagmanager.com").category, .analytics,
                       "GTM is tag/analytics tooling, not definitively ad-tech")
    }
}
