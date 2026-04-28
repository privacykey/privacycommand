import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// One-screen synthesis of everything else on the dashboard. Aggregates
/// the risk grade, an app-profile badge row, a plain-English narrative,
/// and the top 3-5 concerns into a single card so the user has *one
/// thing to read* before drilling into the longer Static / Files /
/// Network tabs.
///
/// The exec summary has a deliberately strict ordering: high-severity
/// warnings first, then risk-tier callouts, then app-profile chips, then
/// supporting trivia. Anything below the fold is non-essential.
struct ExecutiveSummaryView: View {
    let report: StaticReport
    let riskScore: RiskScore?

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Image(systemName: "doc.text.below.ecg").foregroundStyle(.blue)
            Text("Executive summary").font(.headline)
            InfoButton(articleID: "exec-summary")
            Spacer()
            if let score = riskScore {
                RiskTierBadge(score: score)
            }
        }) {
            VStack(alignment: .leading, spacing: 12) {
                narrative
                Divider()
                profileBadges
                if !topConcerns.isEmpty {
                    Divider()
                    concernsSection
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Narrative

    private var narrative: some View {
        Text(buildNarrative())
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Build a paragraph-length plain-English summary by stitching
    /// together signing posture, sandbox state, distribution channel,
    /// notable counts, and the most prominent risk contributor (if any).
    private func buildNarrative() -> String {
        var parts: [String] = []
        let appName = report.bundle.bundleName ?? report.bundle.url
            .deletingPathExtension().lastPathComponent

        // Sentence 1: what kind of app it is.
        parts.append("\(appName) \(signingPhrase()).")

        // Sentence 2: distribution / installation context.
        if let phrase = distributionPhrase() {
            parts.append(phrase)
        }

        // Sentence 3: notable counts.
        var counts: [String] = []
        let trackers = report.sdkHits.filter(\.isTrackerLike).count
        let allSDKs  = report.sdkHits.count
        if allSDKs > 0 {
            counts.append("\(allSDKs) third-party SDK\(allSDKs == 1 ? "" : "s")"
                + (trackers > 0 ? " (\(trackers) tracker-class)" : ""))
        }
        if !report.secrets.isEmpty {
            counts.append("\(report.secrets.count) hard-coded credential\(report.secrets.count == 1 ? "" : "s")")
        }
        let strongAA = report.antiAnalysis.filter { $0.confidence != .low }.count
        if strongAA > 0 {
            counts.append("\(strongAA) anti-analysis signal\(strongAA == 1 ? "" : "s")")
        }
        if report.rpathAudit.hijackableCount > 0 {
            counts.append("\(report.rpathAudit.hijackableCount) hijackable rpath\(report.rpathAudit.hijackableCount == 1 ? "" : "s")")
        }
        if !counts.isEmpty {
            parts.append("Contains: " + counts.joined(separator: "; ") + ".")
        }

        // Sentence 4: the loudest risk contributor (if any) so the user
        // knows where to look first.
        if let score = riskScore, let top = score.contributors.first {
            parts.append("Biggest single risk contributor: \(top.detail).")
        }

        return parts.joined(separator: " ")
    }

    private func signingPhrase() -> String {
        let sign = report.codeSigning
        switch report.notarization {
        case .notarized:
            return "is notarized by Apple under Team ID \(sign.teamIdentifier ?? "?")"
        case .developerIDOnly:
            return "is signed with a Developer ID (Team \(sign.teamIdentifier ?? "?")) but not notarized — older or pre-notarization build"
        case .unsigned:
            return "is **not signed** — Gatekeeper would refuse to launch this in default settings"
        case .rejected:
            return "has a code signature Gatekeeper rejects"
        case .unknown:
            return sign.isPlatformBinary ? "is an Apple platform binary"
                                         : "has an unverified signing posture"
        }
    }

    private func distributionPhrase() -> String? {
        // Provenance-derived hint: where was this app downloaded from?
        if let where_ = report.provenance.whereFromURLs.first {
            return "Provenance tag points to \(host(of: where_) ?? where_)."
        }
        if report.entitlements.isSandboxed && report.codeSigning.signingIdentifier?.contains(".") == true {
            return "Sandboxed app; bundle ID suggests App Store distribution."
        }
        return nil
    }

    private func host(of url: String) -> String? {
        URL(string: url)?.host
    }

    // MARK: - Profile badges

    private var profileBadges: some View {
        let chips = buildProfileChips()
        return VStack(alignment: .leading, spacing: 4) {
            Text("App profile").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(chips, id: \.id) { chip in
                    chipView(chip)
                }
            }
        }
    }

    private struct Chip: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let colour: Color
    }

    private func buildProfileChips() -> [Chip] {
        var chips: [Chip] = []

        // Sandbox.
        if report.entitlements.isSandboxed {
            chips.append(.init(icon: "shield.lefthalf.filled",
                               label: "Sandboxed", colour: .green))
        } else {
            chips.append(.init(icon: "shield.slash",
                               label: "Not sandboxed", colour: .orange))
        }

        // Hardened runtime.
        if report.codeSigning.hardenedRuntime {
            chips.append(.init(icon: "lock.shield",
                               label: "Hardened Runtime",
                               colour: .green))
        } else if !report.codeSigning.isPlatformBinary {
            chips.append(.init(icon: "lock.open",
                               label: "No Hardened Runtime",
                               colour: .orange))
        }

        // Notarization.
        switch report.notarization {
        case .notarized:
            chips.append(.init(icon: "checkmark.seal.fill",
                               label: "Notarized", colour: .green))
        case .developerIDOnly:
            chips.append(.init(icon: "checkmark.seal",
                               label: "Developer ID only", colour: .yellow))
        case .unsigned:
            chips.append(.init(icon: "xmark.seal.fill",
                               label: "Unsigned", colour: .red))
        case .rejected:
            chips.append(.init(icon: "xmark.octagon.fill",
                               label: "Gatekeeper rejected", colour: .red))
        case .unknown:
            break
        }

        // Trackers.
        let trackers = report.sdkHits.filter(\.isTrackerLike).count
        if trackers > 0 {
            chips.append(.init(icon: "antenna.radiowaves.left.and.right",
                               label: "\(trackers) trackers",
                               colour: trackers >= 5 ? .red : .orange))
        }

        // Secrets.
        if !report.secrets.isEmpty {
            chips.append(.init(icon: "key.fill",
                               label: "\(report.secrets.count) secret\(report.secrets.count == 1 ? "" : "s")",
                               colour: .red))
        }

        // Anti-analysis.
        let aa = report.antiAnalysis.filter { $0.confidence != .low }.count
        if aa > 0 {
            chips.append(.init(icon: "eye.slash",
                               label: "\(aa) anti-analysis",
                               colour: .orange))
        }

        // Hijackable rpaths.
        if report.rpathAudit.hijackableCount > 0 {
            chips.append(.init(icon: "exclamationmark.triangle.fill",
                               label: "\(report.rpathAudit.hijackableCount) hijackable rpath\(report.rpathAudit.hijackableCount == 1 ? "" : "s")",
                               colour: .red))
        }

        // Embedded launchd plists.
        let launchPlists = report.embeddedAssets.launchPlists.filter {
            $0.kind == .agent || $0.kind == .daemon
        }.count
        if launchPlists > 0 {
            chips.append(.init(icon: "person.crop.circle.badge.plus",
                               label: "\(launchPlists) launch agent\(launchPlists == 1 ? "" : "s")",
                               colour: .orange))
        }

        // Privacy manifest.
        if report.privacyManifest != nil {
            chips.append(.init(icon: "doc.text.below.ecg",
                               label: "Privacy manifest",
                               colour: .blue))
        }

        return chips
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 4) {
            Image(systemName: chip.icon).imageScale(.small)
            Text(chip.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(chip.colour.opacity(0.15), in: .capsule)
        .foregroundStyle(chip.colour)
    }

    // MARK: - Concerns

    private var topConcerns: [Finding] {
        let order: [Finding.Severity: Int] = [.error: 0, .warn: 1, .info: 2]
        return report.warnings
            .filter { $0.severity != .info }
            .sorted { (order[$0.severity] ?? 9) < (order[$1.severity] ?? 9) }
            .prefix(5)
            .map { $0 }
    }

    private var concernsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top concerns").font(.caption).foregroundStyle(.secondary)
            ForEach(topConcerns) { concern in
                concernRow(concern)
            }
        }
    }

    /// One row — message + first evidence line + a small action toolbar
    /// on the right (web search, copy for sharing, reveal-in-Finder when
    /// the finding mentions a file path, plus the KB info button when
    /// the finding has a linked article).
    private func concernRow(_ concern: Finding) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: severityIcon(concern.severity))
                .foregroundStyle(severityColour(concern.severity))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(concern.message).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = concern.evidence.first {
                    Text(first).font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            concernActions(concern)
        }
    }

    /// Compact icon-only toolbar of actions for a single concern.
    /// Borderless buttons keep the row visually quiet — tooltips carry
    /// the meaning.
    private func concernActions(_ concern: Finding) -> some View {
        HStack(spacing: 4) {
            // Web-search — opens DuckDuckGo with a query built from the
            // finding's message + first evidence line. DDG isn't an
            // affirmative endorsement; it's the search engine that
            // doesn't redirect through us-region results and won't
            // require sign-in for the kinds of technical queries this
            // produces.
            if let url = webSearchURL(for: concern) {
                Link(destination: url) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search the web for context on this finding.")
            }

            // Copy-to-clipboard for sharing in Slack / GitHub issues /
            // a vendor-support ticket. Markdown-flavoured so it pastes
            // cleanly into any of those.
            Button {
                copyToClipboard(formattedFinding(concern))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy a Markdown-formatted summary to the clipboard.")

            // Reveal-in-Finder — only when the finding's evidence
            // includes something that looks like an absolute file path.
            if let path = extractedPath(from: concern) {
                Button {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal \(path) in Finder.")
            }

            if concern.kbArticleID != nil {
                InfoButton(articleID: concern.kbArticleID)
            }
        }
    }

    // MARK: - Action helpers

    /// Builds a DuckDuckGo search URL whose query covers the most
    /// distinctive parts of the finding — the message plus any
    /// quoted-looking tokens from the first evidence line. Stop-words
    /// are not stripped; the user is the one judging the results.
    private func webSearchURL(for f: Finding) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        var pieces: [String] = [f.message]
        if let ev = f.evidence.first { pieces.append(ev) }
        // Trim trailing punctuation and collapse runs of whitespace.
        let raw = pieces.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        components?.queryItems = [URLQueryItem(name: "q", value: raw)]
        return components?.url
    }

    /// Markdown summary suitable for pasting into a chat or issue.
    private func formattedFinding(_ f: Finding) -> String {
        let appLabel = report.bundle.bundleName
            ?? report.bundle.url.deletingPathExtension().lastPathComponent
        let header = "**\(appLabel)** — \(severityLabel(f.severity))"
        var lines = [header, "", f.message]
        if !f.evidence.isEmpty {
            lines.append("")
            lines.append("Evidence:")
            for e in f.evidence.prefix(5) {
                lines.append("- \(e)")
            }
        }
        if let id = f.kbArticleID {
            lines.append("")
            lines.append("KB article: `\(id)`")
        }
        lines.append("")
        lines.append("(via privacycommand)")
        return lines.joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Returns the first plausible absolute path mentioned anywhere in
    /// the finding's message or evidence, if it actually exists on
    /// disk. We only surface the Reveal button when the path is real
    /// — pointing the user at a non-existent path is worse than
    /// hiding the button.
    private func extractedPath(from f: Finding) -> String? {
        let candidates = ([f.message] + f.evidence)
        for line in candidates {
            // Match `/.../...` with at least one slash inside, eating
            // until whitespace or a closing paren / quote.
            guard let m = line.range(of: #"(/[^\s'"`,)\]]+)+"#,
                                     options: .regularExpression) else { continue }
            let path = String(line[m])
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func severityLabel(_ s: Finding.Severity) -> String {
        switch s {
        case .error: return "Error"
        case .warn:  return "Warning"
        case .info:  return "Info"
        }
    }

    private func severityIcon(_ s: Finding.Severity) -> String {
        switch s {
        case .error: return "exclamationmark.octagon.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .info:  return "info.circle"
        }
    }
    private func severityColour(_ s: Finding.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        }
    }
}

// MARK: - FlowLayout

/// Simple FlowLayout — wraps chips onto multiple lines without using
/// `LazyVGrid` (which is column-rigid). Only used by the profile-badge
/// row, which has variable-width content.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                      proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
