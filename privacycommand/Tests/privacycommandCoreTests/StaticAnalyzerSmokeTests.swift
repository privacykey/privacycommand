import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Smoke test for the static analyzer against a system-supplied app.
/// Skipped automatically on CI hosts that don't have the test app installed
/// (e.g. some Linux runners — though we ultimately require macOS).
final class StaticAnalyzerSmokeTests: XCTestCase {

    func testCalculatorReportIsCoherent() throws {
        #if !os(macOS)
        throw XCTSkip("macOS-only smoke test")
        #else
        let path = "/System/Applications/Calculator.app"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Calculator.app not present on this runner")
        }
        let analyzer = StaticAnalyzer()
        let report = try analyzer.analyze(bundleAt: URL(fileURLWithPath: path))

        XCTAssertEqual(report.bundle.bundleID, "com.apple.calculator",
                       "Bundle ID should be com.apple.calculator")
        XCTAssertTrue(report.codeSigning.isPlatformBinary,
                      "Calculator is a platform binary")
        XCTAssertTrue(report.codeSigning.validates,
                      "Calculator's signature should validate")

        // Round-trip through JSON.
        let runReport = RunReport(
            auditorVersion: "test",
            startedAt: .init(),
            endedAt: .init(),
            bundle: report.bundle,
            staticReport: report,
            events: [],
            summary: RunSummary(processCount: 0, fileEventCount: 0, networkEventCount: 0,
                                topRemoteHosts: [], topPathCategories: [], surprisingEventCount: 0),
            fidelityNotes: ["test"]
        )
        let data = try JSONExporter.encode(runReport)
        let decoded = try JSONExporter.decode(data)
        XCTAssertEqual(decoded.bundle.bundleID, runReport.bundle.bundleID)
        #endif
    }

    func testLSOFLineParserHandlesIPv4AndIPv6() {
        let v4 = "Slack 41212 alice 27u IPv4 0x123 0t0 TCP 192.168.1.5:51212->17.253.144.10:443 (ESTABLISHED)"
        let v6 = "Slack 41212 alice 28u IPv6 0xdef 0t0 TCP [fe80::1]:51213->[2606:4700:10::6816:30]:443 (ESTABLISHED)"

        let a = NetworkMonitor.parseLSOFLine(v4)
        XCTAssertEqual(a?.pid, 41212)
        XCTAssertEqual(a?.remoteAddress, "17.253.144.10")
        XCTAssertEqual(a?.remotePort, 443)
        XCTAssertEqual(a?.proto, .tcp)

        let b = NetworkMonitor.parseLSOFLine(v6)
        XCTAssertEqual(b?.remoteAddress, "2606:4700:10::6816:30")
        XCTAssertEqual(b?.remotePort, 443)
    }
}
