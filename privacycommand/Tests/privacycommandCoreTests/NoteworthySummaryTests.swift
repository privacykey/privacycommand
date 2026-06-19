import XCTest
@testable import privacycommandCore

/// Covers the `NoteworthySummary` distillation — the "is there anything worth a
/// second look here?" layer the CLI `preview` command renders. Pure over a
/// `StaticReport`, so it's driven entirely by the `Fix` fixture builder.
final class NoteworthySummaryTests: XCTestCase {

    func testCleanAppIsNotNoteworthy() {
        // Default fixture: notarized, hardened, validates, no trackers/secrets/caps.
        let summary = NoteworthySummary.summarize(Fix.report())

        XCTAssertFalse(summary.isNoteworthy)
        XCTAssertTrue(summary.signals.isEmpty)
        XCTAssertTrue(summary.findings.isEmpty)
        XCTAssertEqual(summary.tier, .low)
        XCTAssertTrue(summary.headline.lowercased().contains("nothing noteworthy"))
    }

    func testRiskyAppSurfacesSignals() {
        let weakened = Entitlements(
            raw: [:], isSandboxed: false, appGroups: [], appleEvents: nil,
            networkClient: true, networkServer: true, allowsJIT: true,
            allowsDyldEnvironmentVariables: true, disablesLibraryValidation: true,
            endpointSecurityClient: true, networkExtension: [])

        let report = Fix.report(
            entitlements: weakened,
            codeSigning: Fix.signing(hardened: false),
            notarization: .unsigned,
            inferredCapabilities: [Fix.undeclaredCapability(.location)],
            sdkHits: [Fix.tracker("Firebase"), Fix.tracker("Amplitude")],
            secrets: [Fix.secret(.githubToken)])

        let summary = NoteworthySummary.summarize(report)

        XCTAssertTrue(summary.isNoteworthy)
        XCTAssertNotEqual(summary.tier, .low, "weakened hardening + unsigned should clear the low tier")

        let blob = summary.signals.joined(separator: "\n")
        XCTAssertTrue(blob.contains("Unsigned"), "expected an unsigned signal in:\n\(blob)")
        XCTAssertTrue(blob.contains("library validation"))
        XCTAssertTrue(blob.contains("DYLD"))
        XCTAssertTrue(blob.contains("Endpoint Security"))
        XCTAssertTrue(blob.contains("network server"))
        XCTAssertTrue(blob.contains("location"), "undeclared capability should be named")
        XCTAssertTrue(blob.contains("Firebase") && blob.contains("Amplitude"), "trackers should be listed")
        XCTAssertTrue(blob.contains("hard-coded secret"))
    }

    func testTrackerSdkAloneIsNoteworthyEvenAtLowScore() {
        // A well-signed, notarized app whose only flag is an analytics SDK:
        // the risk score may stay low, but the tracker is still worth surfacing.
        let report = Fix.report(sdkHits: [Fix.tracker("Mixpanel", category: .analytics)])
        let summary = NoteworthySummary.summarize(report)

        XCTAssertTrue(summary.isNoteworthy)
        XCTAssertTrue(summary.signals.contains { $0.contains("Mixpanel") })
    }
}
