import Foundation

/// Where in the bundle (or in a captured run) a `RiskContributor` came from.
/// Used to power the "show source" popover next to each contributor — so a
/// score isn't just a number, it's a number you can chase down.
public struct ContributorSource: Hashable, Sendable {
    /// Short label shown as the popover headline.
    public let title: String
    /// One-line description of where the data lives ("Contents/Info.plist",
    /// "From `codesign -d --entitlements :- ...`", "Files tab", …).
    public let pathHint: String
    /// Optional excerpt — usually a code snippet or a few matched lines —
    /// shown monospaced. Capped to a few hundred characters by the producer.
    public let snippet: String?
    /// Optional file URL the UI should pass to `NSWorkspace.activateFileViewerSelecting`.
    public let revealURL: URL?
    /// Optional secondary action label, e.g. "Show 12 events in Files tab".
    public let actionLabel: String?

    public init(title: String, pathHint: String,
                snippet: String? = nil, revealURL: URL? = nil,
                actionLabel: String? = nil) {
        self.title = title
        self.pathHint = pathHint
        self.snippet = snippet
        self.revealURL = revealURL
        self.actionLabel = actionLabel
    }
}

public extension RiskContributor {

    /// Resolve a `ContributorSource` for this contributor against the static
    /// report and (optionally) the dynamic events that produced it. Returns
    /// nil for contributor categories we don't have a source mapping for —
    /// the UI hides the "show source" button in that case.
    func source(staticReport: StaticReport, events: [DynamicEvent] = []) -> ContributorSource? {
        let bundleURL = staticReport.bundle.url
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let signatureURL = contentsURL.appendingPathComponent("_CodeSignature")
        let executableURL = staticReport.bundle.executableURL

        switch (source, category) {

        // ─── Signing posture ────────────────────────────────────────────────
        case (.staticAnalysis, "code-signing"):
            return ContributorSource(
                title: "Code signature",
                pathHint: "Contents/_CodeSignature/",
                snippet: staticReport.codeSigning.validationError
                    ?? staticReport.codeSigning.designatedRequirement,
                revealURL: signatureURL
            )

        case (.staticAnalysis, "hardened-runtime"):
            return ContributorSource(
                title: "Hardened Runtime flag",
                pathHint: "Mach-O signature on \(executableURL.lastPathComponent)",
                snippet: """
                    The app's main executable is signed without the
                    Hardened Runtime bit. Verify with:

                    codesign -dvv "\(bundleURL.path)"

                    Look for `flags=0x10000(runtime)` — its absence is the finding.
                    """,
                revealURL: executableURL
            )

        case (.staticAnalysis, "notarization"):
            return ContributorSource(
                title: "Gatekeeper assessment",
                pathHint: "spctl(8) output",
                snippet: """
                    Result captured by:

                    spctl --assess -vvv "\(bundleURL.path)"

                    Status: \(notarizationLabel(staticReport.notarization))
                    """,
                revealURL: nil
            )

        // ─── Entitlement-derived findings ───────────────────────────────────
        case (.staticAnalysis, "library-validation"):
            return entitlementSource(
                key: "com.apple.security.cs.disable-library-validation",
                report: staticReport)

        case (.staticAnalysis, "dyld-env"):
            return entitlementSource(
                key: "com.apple.security.cs.allow-dyld-environment-variables",
                report: staticReport)

        case (.staticAnalysis, "automation"):
            return entitlementSource(
                key: "com.apple.security.automation.apple-events",
                report: staticReport)

        case (.staticAnalysis, "endpoint-security"):
            return entitlementSource(
                key: "com.apple.developer.endpoint-security.client",
                report: staticReport)

        // ─── Info.plist findings ────────────────────────────────────────────
        case (.staticAnalysis, "privacy-key-empty"):
            let empty = staticReport.declaredPrivacyKeys.filter { $0.isEmpty }
            let snippet = empty.map { "<key>\($0.rawKey)</key>\n<string></string>" }
                .joined(separator: "\n\n")
            return ContributorSource(
                title: "Info.plist",
                pathHint: "Contents/Info.plist",
                snippet: snippet.isEmpty ? nil : snippet,
                revealURL: infoPlistURL
            )

        // ─── Inferred-API findings ──────────────────────────────────────────
        case (.staticAnalysis, "undeclared-api"):
            let inferred = staticReport.inferredCapabilities.filter { $0.inferredButNotDeclared }
            let snippet = inferred.map {
                "\($0.category.rawValue) — evidence: \($0.evidence.joined(separator: "; "))"
            }.joined(separator: "\n")
            return ContributorSource(
                title: "Binary string scan",
                pathHint: "Contents/MacOS/\(executableURL.lastPathComponent)",
                snippet: snippet.isEmpty ? nil : snippet,
                revealURL: executableURL
            )

        case (.staticAnalysis, "unjustified-permission"):
            let unjust = staticReport.inferredCapabilities.filter { $0.declaredButNotJustified }
            let snippet = unjust.map {
                "\($0.category.rawValue) — declared in Info.plist, no matching framework or symbol in the binary."
            }.joined(separator: "\n")
            return ContributorSource(
                title: "Info.plist + Binary scan (cross-reference)",
                pathHint: "Contents/Info.plist · Contents/MacOS/\(executableURL.lastPathComponent)",
                snippet: snippet.isEmpty ? nil : snippet,
                revealURL: infoPlistURL
            )

        // ─── Dynamic findings ───────────────────────────────────────────────
        case (.dynamicAnalysis, "surprising-file-access"):
            let hits = events.compactMap { e -> FileEvent? in
                if case .file(let f) = e, f.risk == .surprising { return f } else { return nil }
            }
            return dynamicFileSource(title: "Surprising file events", events: hits)

        case (.dynamicAnalysis, "sensitive-file-access"):
            let hits = events.compactMap { e -> FileEvent? in
                if case .file(let f) = e, f.risk == .sensitive { return f } else { return nil }
            }
            return dynamicFileSource(title: "Sensitive file events", events: hits)

        case (.dynamicAnalysis, "surprising-network"):
            let hits = events.compactMap { e -> NetworkEvent? in
                if case .network(let n) = e, n.risk == .surprising { return n } else { return nil }
            }
            return dynamicNetSource(title: "Surprising network events", events: hits)

        case (.dynamicAnalysis, "many-hosts"):
            let nets = events.compactMap { e -> NetworkEvent? in
                if case .network(let n) = e { return n } else { return nil }
            }
            let distinct = Set(nets.compactMap { $0.remoteHostname ?? $0.remoteEndpoint.address })
                .sorted()
            let snippet = distinct.prefix(20).joined(separator: "\n")
            return ContributorSource(
                title: "Distinct remote hosts",
                pathHint: "Network tab",
                snippet: snippet.isEmpty ? nil
                    : "\(distinct.count) distinct host(s) contacted:\n\n\(snippet)\(distinct.count > 20 ? "\n…" : "")",
                revealURL: nil,
                actionLabel: "Show \(distinct.count) host(s) in Network tab"
            )

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private func entitlementSource(key: String, report: StaticReport) -> ContributorSource {
        let bundleURL = report.bundle.url
        let snippet: String
        if let value = report.entitlements.raw[key] {
            snippet = "<key>\(key)</key>\n\(plistValueXML(value))"
        } else {
            snippet = "<key>\(key)</key>\n<true/>"
        }
        return ContributorSource(
            title: "Bundle entitlement",
            pathHint: "From `codesign -d --entitlements :- \"\(bundleURL.lastPathComponent)\"`",
            snippet: snippet,
            revealURL: bundleURL.appendingPathComponent("Contents/_CodeSignature")
        )
    }

    private func dynamicFileSource(title: String, events: [FileEvent]) -> ContributorSource {
        let snippet = events.prefix(10).map {
            "[\($0.risk.rawValue)]\t\($0.processName)[\($0.pid)]\t\($0.op.rawValue)\t\($0.path)"
        }.joined(separator: "\n")
        return ContributorSource(
            title: title,
            pathHint: "Files tab",
            snippet: snippet.isEmpty ? nil
                : "\(events.count) event(s):\n\n\(snippet)\(events.count > 10 ? "\n…" : "")",
            revealURL: nil,
            actionLabel: "Show \(events.count) event(s) in Files tab"
        )
    }

    private func dynamicNetSource(title: String, events: [NetworkEvent]) -> ContributorSource {
        let snippet = events.prefix(10).map {
            "[\($0.risk.rawValue)]\t\($0.processName)[\($0.pid)]\t→ \($0.remoteHostname ?? $0.remoteEndpoint.address):\($0.remoteEndpoint.port) (\($0.netProto.rawValue.uppercased()))"
        }.joined(separator: "\n")
        return ContributorSource(
            title: title,
            pathHint: "Network tab",
            snippet: snippet.isEmpty ? nil
                : "\(events.count) event(s):\n\n\(snippet)\(events.count > 10 ? "\n…" : "")",
            revealURL: nil,
            actionLabel: "Show \(events.count) event(s) in Network tab"
        )
    }

    private func plistValueXML(_ v: PlistValue) -> String {
        switch v {
        case .string(let s): return "<string>\(s)</string>"
        case .bool(let b):   return b ? "<true/>" : "<false/>"
        case .int(let i):    return "<integer>\(i)</integer>"
        case .double(let d): return "<real>\(d)</real>"
        case .array(let a):  return "<array> (\(a.count) item(s)) </array>"
        case .dict(let d):   return "<dict> (\(d.count) key(s)) </dict>"
        default:             return "<!-- unsupported -->"
        }
    }

    private func notarizationLabel(_ n: NotarizationStatus) -> String {
        switch n {
        case .notarized:           return "notarized"
        case .developerIDOnly:     return "Developer ID — not notarized"
        case .unsigned:            return "unsigned"
        case .rejected(let m):     return "rejected: \(m.prefix(120))"
        case .unknown(let m):      return "unknown: \(m.prefix(120))"
        }
    }
}
