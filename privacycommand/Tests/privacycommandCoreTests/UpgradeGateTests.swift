import XCTest
@testable import privacycommandCore

final class UpgradeGateTests: XCTestCase {

    private func summary(score: Int) -> NoteworthySummary {
        NoteworthySummary(riskScore: score, tier: RiskTier.from(score: score),
                          findings: [], signals: [], isNoteworthy: score >= 20,
                          headline: "test \(score)")
    }

    // MARK: Threshold parsing

    func testTierNamesParseToTheTopOfTheirTier() {
        XCTAssertEqual(UpgradeGate.Threshold.parse("low")?.maxScore, 19)
        XCTAssertEqual(UpgradeGate.Threshold.parse("Medium")?.maxScore, 49)
        XCTAssertEqual(UpgradeGate.Threshold.parse("HIGH")?.maxScore, 79)
        XCTAssertEqual(UpgradeGate.Threshold.parse(" critical ")?.maxScore, 100)
    }

    func testTierUpperBoundsAgreeWithRiskTierBands() {
        for tier in [RiskTier.low, .medium, .high, .critical] {
            let top = UpgradeGate.Threshold.upperBound(of: tier)
            XCTAssertEqual(RiskTier.from(score: top), tier, "\(tier) top")
            if top < 100 {
                XCTAssertNotEqual(RiskTier.from(score: top + 1), tier, "\(tier) top+1 is the next tier")
            }
            XCTAssertEqual(UpgradeGate.Threshold(maxScore: top).tier, tier)
        }
    }

    func testWholeNumbersParseAsScores() {
        XCTAssertEqual(UpgradeGate.Threshold.parse("0")?.maxScore, 0)
        XCTAssertEqual(UpgradeGate.Threshold.parse("35")?.maxScore, 35)
        XCTAssertEqual(UpgradeGate.Threshold.parse(" 42 ")?.maxScore, 42)
        XCTAssertEqual(UpgradeGate.Threshold.parse("100")?.maxScore, 100)
    }

    func testRejectsAnythingElse() {
        for bad in ["101", "-1", "abc", "", "4.5", "med", "low risk"] {
            XCTAssertNil(UpgradeGate.Threshold.parse(bad), "'\(bad)' should not parse")
        }
    }

    func testDescriptionNamesScoreAndTier() {
        XCTAssertEqual(UpgradeGate.Threshold.parse("medium")?.description, "49/100 (medium)")
        XCTAssertEqual(UpgradeGate.Threshold(maxScore: 35).description, "35/100 (medium)")
    }

    // MARK: Decisions

    func testClearedAtOrBelowTheThreshold() {
        let threshold = UpgradeGate.Threshold.parse("medium")!
        let atLimit = UpgradeGate.decide(.incoming(summary(score: 49)), threshold: threshold)
        XCTAssertTrue(atLimit.cleared)
        XCTAssertNil(atLimit.reason)
        XCTAssertEqual(atLimit.score, 49)
        XCTAssertEqual(atLimit.tier, .medium)
        XCTAssertEqual(atLimit.basis, .incoming)

        let low = UpgradeGate.decide(.incoming(summary(score: 0)), threshold: threshold)
        XCTAssertTrue(low.cleared)
    }

    func testHeldAboveTheThresholdWithAReasonThatNamesBothScores() throws {
        let threshold = UpgradeGate.Threshold.parse("medium")!
        let d = UpgradeGate.decide(.incoming(summary(score: 50)), threshold: threshold)
        XCTAssertFalse(d.cleared)
        XCTAssertEqual(d.score, 50)
        XCTAssertEqual(d.tier, .high)
        XCTAssertEqual(d.basis, .incoming)
        let reason = try XCTUnwrap(d.reason)
        XCTAssertTrue(reason.contains("incoming build"), reason)
        XCTAssertTrue(reason.contains("50/100"), reason)
        XCTAssertTrue(reason.contains("49/100 (medium)"), reason)
    }

    func testInstalledOnlyEvidenceIsJudgedOnTheInstalledBuild() {
        let threshold = UpgradeGate.Threshold(maxScore: 10)
        let d = UpgradeGate.decide(.installedOnly(summary(score: 30)), threshold: threshold)
        XCTAssertFalse(d.cleared)
        XCTAssertEqual(d.basis, .installed)
        XCTAssertTrue(d.reason?.contains("installed build") == true, d.reason ?? "nil")

        let ok = UpgradeGate.decide(.installedOnly(summary(score: 10)), threshold: threshold)
        XCTAssertTrue(ok.cleared)
        XCTAssertEqual(ok.basis, .installed)
    }

    func testUnavailableEvidenceIsHeldEvenAtTheLoosestThreshold() {
        let threshold = UpgradeGate.Threshold.parse("critical")!
        let d = UpgradeGate.decide(.unavailable("couldn't fetch the incoming build — timed out"),
                                   threshold: threshold)
        XCTAssertFalse(d.cleared)
        XCTAssertEqual(d.reason, "couldn't fetch the incoming build — timed out")
        XCTAssertNil(d.score)
        XCTAssertNil(d.tier)
        XCTAssertNil(d.basis)
    }

    func testCriticalThresholdClearsEverythingAnalyzable() {
        let threshold = UpgradeGate.Threshold.parse("critical")!
        XCTAssertTrue(UpgradeGate.decide(.incoming(summary(score: 100)), threshold: threshold).cleared)
    }
}
