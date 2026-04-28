import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

// MARK: - Header chip

/// Compact risk badge for the toolbar / header.
struct RiskTierBadge: View {
    let score: RiskScore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(score.tier.label)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
            Text("\(score.score)").font(.caption.monospaced())
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(background, in: .capsule)
        .foregroundStyle(foreground)
        .help(tooltip)
    }

    private var icon: String {
        switch score.tier {
        case .low:      return "checkmark.shield.fill"
        case .medium:   return "exclamationmark.shield"
        case .high:     return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
    private var background: Color {
        switch score.tier {
        case .low:      return .green.opacity(0.18)
        case .medium:   return .yellow.opacity(0.22)
        case .high:     return .orange.opacity(0.22)
        case .critical: return .red.opacity(0.22)
        }
    }
    private var foreground: Color {
        switch score.tier {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
    private var tooltip: String {
        if score.contributors.isEmpty {
            return "Privacy concern: \(score.tier.label). No findings."
        }
        let top = score.contributors.prefix(3).map { "+\($0.impact) \($0.detail)" }.joined(separator: "\n")
        return "Privacy concern: \(score.tier.label) (\(score.score)/100)\n\nTop drivers:\n\(top)"
    }
}

// MARK: - Dashboard section

/// Full explanatory section for the Dashboard tab.
struct RiskScoreSection: View {
    let score: RiskScore

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Text("Privacy concern level")
            InfoButton(articleID: "risk-score")
            FidelityBadge(.staticAnalysis,
                          detail: "Score combines static-analysis signals with any captured dynamic events.")
        }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(score.tier.label.uppercased())
                        .font(.headline)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(tierBackground, in: .capsule)
                        .foregroundStyle(tierForeground)
                    Text("\(score.score) / 100")
                        .font(.title2.bold().monospacedDigit())
                    Spacer()
                    if !score.contributors.isEmpty {
                        Text("\(score.contributors.count) finding\(score.contributors.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Score bar with tier zones marked.
                scoreBar

                if score.contributors.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("No risk-elevating findings.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Divider()
                    Text("Top contributors").font(.subheadline.bold())
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(score.contributors.prefix(8)) { c in
                            ContributorRow(contributor: c)
                        }
                        if score.contributors.count > 8 {
                            Text("…and \(score.contributors.count - 8) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Sub-views

    private var scoreBar: some View {
        GeometryReader { geom in
            ZStack(alignment: .leading) {
                // Tier zones: 0-20 green, 20-50 yellow, 50-80 orange, 80-100 red.
                HStack(spacing: 0) {
                    Rectangle().fill(Color.green.opacity(0.18)).frame(width: geom.size.width * 0.20)
                    Rectangle().fill(Color.yellow.opacity(0.18)).frame(width: geom.size.width * 0.30)
                    Rectangle().fill(Color.orange.opacity(0.18)).frame(width: geom.size.width * 0.30)
                    Rectangle().fill(Color.red.opacity(0.18)).frame(width: geom.size.width * 0.20)
                }
                // Filled portion
                Rectangle()
                    .fill(tierForeground)
                    .frame(width: geom.size.width * CGFloat(score.score) / 100)
                // Tick at the score position
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 2, height: 14)
                    .offset(x: geom.size.width * CGFloat(score.score) / 100 - 1, y: -3)
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
    }

    // MARK: - Tier colors

    private var tierBackground: Color {
        switch score.tier {
        case .low:      return .green.opacity(0.20)
        case .medium:   return .yellow.opacity(0.25)
        case .high:     return .orange.opacity(0.25)
        case .critical: return .red.opacity(0.25)
        }
    }
    private var tierForeground: Color {
        switch score.tier {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }
}

// MARK: - One contributor row

/// A single row in the risk-score contributors list. Encapsulated so each
/// row can own its own `showingSource` state for the source popover.
private struct ContributorRow: View {
    let contributor: RiskContributor

    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var showingSource = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("+\(contributor.impact)")
                .font(.caption.monospaced().bold())
                .foregroundStyle(.orange)
                .frame(width: 32, alignment: .trailing)

            Image(systemName: contributor.source == .staticAnalysis
                  ? "doc.text.magnifyingglass" : "eye")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(contributor.detail)
                .font(.callout)
                .lineLimit(2)

            // KB explainer
            InfoButton(articleID: contributor.category)

            // "Where in the bundle / events did this come from?"
            sourceButton

            Spacer()

            Text(contributor.category)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Source button + popover

    @ViewBuilder
    private var sourceButton: some View {
        if let report = coordinator.staticReport,
           let source = contributor.source(staticReport: report, events: coordinator.events) {
            Button {
                showingSource.toggle()
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .imageScale(.small)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .help("Show source: \(source.pathHint)")
            .popover(isPresented: $showingSource, arrowEdge: .trailing) {
                SourcePopover(source: source)
                    .frame(width: 460)
                    .padding(16)
            }
        }
    }
}

// MARK: - Source popover content

private struct SourcePopover: View {
    let source: ContributorSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "magnifyingglass").foregroundStyle(.blue)
                Text(source.title).font(.headline)
            }
            Text(source.pathHint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let snippet = source.snippet, !snippet.isEmpty {
                Divider()
                ScrollView {
                    Text(snippet)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                }
                .frame(maxHeight: 240)
            }

            HStack(spacing: 8) {
                if let url = source.revealURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let action = source.actionLabel {
                    Text(action)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
