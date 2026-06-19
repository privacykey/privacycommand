import XCTest
@testable import privacycommandCore

/// Covers the pure installed→incoming comparison that backs `auditctl preview
/// --fetch`. No brew/network/mount — both sides are hand-built `StaticReport`s.
final class IncomingCaskComparisonTests: XCTestCase {

    func testUpgradeIntroducingEntitlementAndDomainShowsAsAdded() {
        let installed = Fix.report()   // notarized, clean, no entitlements/domains

        let weakerEntitlements = Entitlements(
            raw: ["com.apple.security.cs.allow-jit": .bool(true)],
            isSandboxed: false, appGroups: [], appleEvents: nil,
            networkClient: false, networkServer: false, allowsJIT: true,
            allowsDyldEnvironmentVariables: false, disablesLibraryValidation: false,
            endpointSecurityClient: false, networkExtension: [])

        let incoming = Fix.report(
            entitlements: weakerEntitlements,
            notarization: .unsigned,                     // pushes the incoming risk up
            hardcodedDomains: ["telemetry.example.com"])

        let result = IncomingCaskComparison.compare(installed: installed, incoming: incoming)

        XCTAssertTrue(result.diff.hasAnyChange)

        let sections = Dictionary(uniqueKeysWithValues: result.diff.changedSections.map { ($0.title, $0) })
        XCTAssertTrue(sections["Entitlements"]?.added.contains("com.apple.security.cs.allow-jit") ?? false,
                      "the new entitlement should show as added by the upgrade")
        XCTAssertTrue(sections["Hard-coded domains"]?.added.contains("telemetry.example.com") ?? false,
                      "the new domain should show as added by the upgrade")

        // Unsigned incoming scores higher than the notarized installed build.
        XCTAssertGreaterThan(result.incomingRiskScore, result.installedRiskScore)
        XCTAssertGreaterThan(result.riskScoreDelta, 0)

        // The incoming build's own summary is populated and flags the unsigned state.
        XCTAssertTrue(result.incomingSummary.isNoteworthy)
        XCTAssertEqual(result.incomingVersion, incoming.bundle.bundleVersion)
    }

    func testIdenticalBuildsHaveNoChange() {
        let result = IncomingCaskComparison.compare(installed: Fix.report(), incoming: Fix.report())
        XCTAssertFalse(result.diff.hasAnyChange)
        XCTAssertEqual(result.riskScoreDelta, 0)
        XCTAssertTrue(result.diff.changedSections.isEmpty)
    }
}
