import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Compact colored chip for a remote-host classification. Hides itself when
/// the classifier returns `.unknown` so unfamiliar hosts don't get a confusing
/// "Unknown" pill — a missing chip is the more honest signal.
struct DomainCategoryBadge: View {
    let host: String
    var compact: Bool = false

    private static let classifier = DomainClassifier()

    var body: some View {
        let classification = Self.classifier.classify(host)
        if classification.category != .unknown {
            HStack(spacing: 4) {
                Image(systemName: classification.category.systemImage)
                    .imageScale(.small)
                if !compact {
                    Text(classification.category.label)
                        .font(.caption2.weight(.medium))
                }
            }
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .background(color(for: classification.category).opacity(0.18), in: .capsule)
            .foregroundStyle(color(for: classification.category))
            .help(tooltip(for: classification))
        }
    }

    private func tooltip(for c: DomainClassification) -> String {
        let summary = KnowledgeBase.article(id: c.category.kbArticleID)?.summary
            ?? c.category.label
        if !c.matchedPattern.isEmpty {
            return "\(c.category.label) — matches \(c.matchedPattern).\n\n\(summary)"
        }
        return "\(c.category.label).\n\n\(summary)"
    }

    /// Color choices kept consistent with the rest of the app's palette: red
    /// for high-attention, orange for moderate, blue/green for benign, grey
    /// for neutral.
    private func color(for category: DomainClassification.Category) -> Color {
        switch category {
        case .adTech:           return .red
        case .analytics:        return .orange
        case .errorReporting:   return .blue
        case .telemetry:        return .blue
        case .payment:          return .purple
        case .socialAuth:       return .green
        case .devTools:         return .green
        case .cdn:              return .gray
        case .apple:            return .secondary
        case .google:           return .blue
        case .microsoft:        return .blue
        case .meta:             return .indigo
        case .amazon:           return .orange
        case .unknown:          return .secondary
        }
    }
}
