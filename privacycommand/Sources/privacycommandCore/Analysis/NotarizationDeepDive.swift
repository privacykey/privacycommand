import Foundation
import CryptoKit

/// Deeper notarization / Gatekeeper checks that complement the basic
/// `NotarizationStatus` already captured in the `StaticReport`.
///
/// What we add over the basic check:
///   * **Stapled ticket validation.** `xcrun stapler validate` reports
///     whether a notarization ticket is **stapled** to the bundle (i.e.
///     embedded so Gatekeeper can verify it offline) versus only available
///     online. Apps shipped via Sparkle frequently lose their stapled
///     ticket if the developer forgets to staple after notarizing.
///   * **Full Gatekeeper verdict.** The text output of `spctl --assess
///     -vvv` for the user to read directly — sometimes the most useful
///     thing.
///   * **SHA-256 of the main executable.** Not a verdict by itself, but
///     the input for any external reputation lookup (VirusTotal, Apple
///     Notary lookup, internal threat-intel).
public enum NotarizationDeepDive {

    public static func analyse(bundle: AppBundle) -> NotarizationDeepDiveReport {
        let stapler = staplerValidate(bundleURL: bundle.url)
        let spctl   = spctlAssess(bundleURL: bundle.url)
        let sha     = sha256OfExecutable(bundle.executableURL)
        return NotarizationDeepDiveReport(
            staplerOutput: stapler,
            spctlOutput: spctl,
            executableSHA256: sha,
            executableURL: bundle.executableURL)
    }

    private static func staplerValidate(bundleURL: URL) -> NotarizationDeepDiveReport.ToolOutput {
        let path = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .init(rawText: "(xcrun unavailable)", verdict: .unknown)
        }
        let result = ProcessRunner.runSync(
            launchPath: path,
            arguments: ["stapler", "validate", "-q", bundleURL.path],
            timeout: 10)
        let combined = (result.stdout + "\n" + result.stderr).lowercased()
        let verdict: NotarizationDeepDiveReport.Verdict
        if combined.contains("the validate action worked") || result.exitCode == 0 {
            verdict = .ok
        } else if combined.contains("does not have a ticket")
                  || combined.contains("could not validate")
                  || combined.contains("65") {  // stapler's "no ticket" exit code
            verdict = .noTicket
        } else {
            verdict = .failed
        }
        let raw = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(rawText: raw.isEmpty ? "(no output)" : raw, verdict: verdict)
    }

    private static func spctlAssess(bundleURL: URL) -> NotarizationDeepDiveReport.ToolOutput {
        let result = ProcessRunner.runSync(
            launchPath: "/usr/sbin/spctl",
            arguments: ["--assess", "-vvv", bundleURL.path],
            timeout: 15)
        let combined = (result.stdout + "\n" + result.stderr).lowercased()
        let verdict: NotarizationDeepDiveReport.Verdict
        if combined.contains("accepted") { verdict = .ok }
        else if combined.contains("rejected") || combined.contains("unsigned") { verdict = .failed }
        else { verdict = .unknown }
        let raw = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(rawText: raw.isEmpty ? "(no output)" : raw, verdict: verdict)
    }

    private static func sha256OfExecutable(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Public types

public struct NotarizationDeepDiveReport: Sendable, Hashable, Codable {
    public let staplerOutput: ToolOutput
    public let spctlOutput: ToolOutput
    public let executableSHA256: String?
    public let executableURL: URL

    public init(staplerOutput: ToolOutput,
                spctlOutput: ToolOutput,
                executableSHA256: String?,
                executableURL: URL) {
        self.staplerOutput = staplerOutput
        self.spctlOutput = spctlOutput
        self.executableSHA256 = executableSHA256
        self.executableURL = executableURL
    }

    public static let empty = NotarizationDeepDiveReport(
        staplerOutput: .init(rawText: "", verdict: .unknown),
        spctlOutput: .init(rawText: "", verdict: .unknown),
        executableSHA256: nil,
        executableURL: URL(fileURLWithPath: "/"))

    public struct ToolOutput: Sendable, Hashable, Codable {
        public let rawText: String
        public let verdict: Verdict
    }

    public enum Verdict: String, Sendable, Hashable, Codable {
        case ok        = "OK"
        case noTicket  = "No ticket"
        case failed    = "Failed"
        case unknown   = "Unknown"
    }

    /// Convenience URLs for external lookup. Built only when we have a
    /// SHA-256.
    public var virusTotalURL: URL? {
        guard let sha = executableSHA256 else { return nil }
        return URL(string: "https://www.virustotal.com/gui/file/\(sha)")
    }
}
