import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 7 — signing / RPATH false positives.
final class SigningRPathFPTests: XCTestCase {

    // MARK: - RPath classification

    func testInBundleRPathNotHijackableEvenIfOwnerWritable() {
        let bundle = URL(fileURLWithPath: "/Users/me/Applications/My.app")
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        // Owner-writable, but inside the app's own bundle → not a hijack vector.
        XCTAssertEqual(RPathAuditor.classify(raw: "@executable_path/../Frameworks",
                                             resolved: frameworks, writable: true, bundleRoot: bundle),
                       .relative)
    }

    func testHomebrewAndUsrLocalTreatedConsistentlyAsExternal() {
        for p in ["/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"] {
            XCTAssertEqual(RPathAuditor.classify(raw: p, resolved: URL(fileURLWithPath: p),
                                                 writable: true, bundleRoot: nil),
                           .absolute, "\(p) is a standard package prefix, not a per-app hijack alarm")
        }
    }

    func testGenuinelyWritableExternalPathIsHijackable() {
        let evil = URL(fileURLWithPath: "/Users/Shared/evil")
        XCTAssertEqual(RPathAuditor.classify(raw: "/Users/Shared/evil", resolved: evil,
                                             writable: true, bundleRoot: URL(fileURLWithPath: "/Applications/X.app")),
                       .hijackable)
    }

    func testSystemPathIsSystem() {
        XCTAssertEqual(RPathAuditor.classify(raw: "/usr/lib", resolved: URL(fileURLWithPath: "/usr/lib"),
                                             writable: false, bundleRoot: nil), .system)
    }

    // MARK: - Stapler verdict by exit code, not substring

    func testStaplerVerdictUsesExitCodeNotSubstring() {
        // A "65" in the path/version with exit 0 must read as OK, not no-ticket.
        XCTAssertEqual(NotarizationDeepDive.staplerVerdict(
            combined: "processing: /users/me/app65.app\nthe validate action worked", exitCode: 0), .ok)
        XCTAssertEqual(NotarizationDeepDive.staplerVerdict(
            combined: "version 1.65 build 6500", exitCode: 0), .ok)
        // Real no-ticket: exit code 65.
        XCTAssertEqual(NotarizationDeepDive.staplerVerdict(
            combined: "app does not have a ticket stapled", exitCode: 65), .noTicket)
        XCTAssertEqual(NotarizationDeepDive.staplerVerdict(combined: "some other error", exitCode: 1), .failed)
    }

    // MARK: - Ad-hoc component verdict

    private func entry(_ name: String, role: BundleSigningAudit.Entry.Role, adhoc: Bool, team: String?) -> BundleSigningAudit.Entry {
        BundleSigningAudit.Entry(url: URL(fileURLWithPath: "/x/\(name)"), role: role, teamID: team,
                                 signingIdentifier: name, hardenedRuntime: true, isAdhocSigned: adhoc,
                                 isPlatformBinary: false, validates: true, validationError: nil)
    }

    func testAdhocFrameworksAndToolsNotFlagged() {
        let audit = BundleSigningAuditor.summarize(entries: [
            entry("My", role: .mainApp, adhoc: false, team: "ABCDE12345"),
            entry("libvk_swiftshader.dylib", role: .framework, adhoc: true, team: nil),  // benign
            entry("swiftpm-tool", role: .other, adhoc: true, team: nil),                 // benign
        ])
        XCTAssertFalse(audit.verdicts.contains { $0.summary.contains("ad-hoc") },
                       "ad-hoc frameworks/dylibs/tools are routine and must not be flagged")
    }

    func testAdhocHelperProcessStillNotedInSignedApp() {
        let audit = BundleSigningAuditor.summarize(entries: [
            entry("My", role: .mainApp, adhoc: false, team: "ABCDE12345"),
            entry("com.x.helper", role: .xpcService, adhoc: true, team: nil),
        ])
        XCTAssertTrue(audit.verdicts.contains { $0.summary.contains("ad-hoc") },
                      "an ad-hoc XPC service in a distributed app is still worth a note")
    }
}
