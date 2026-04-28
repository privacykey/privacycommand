import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// A small pill that announces the fidelity of an adjacent claim. Every UI
/// element that reports something the auditor "observed" must place a
/// `FidelityBadge` next to it. We enforce this with a unit test.
struct FidelityBadge: View {
    let fidelity: Fidelity
    let detail: String?

    init(_ fidelity: Fidelity, detail: String? = nil) {
        self.fidelity = fidelity
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(background, in: .capsule)
        .foregroundStyle(foreground)
        .help(detail ?? help)
    }

    private var label: String {
        switch fidelity {
        case .staticAnalysis:        return "static"
        case .observed:              return "observed"
        case .bestEffort:            return "best-effort"
        case .requiresEntitlement:   return "requires entitlement"
        }
    }
    private var icon: String {
        switch fidelity {
        case .staticAnalysis:        return "doc.text.magnifyingglass"
        case .observed:              return "eye"
        case .bestEffort:            return "exclamationmark.triangle"
        case .requiresEntitlement:   return "lock"
        }
    }
    private var background: Color {
        switch fidelity {
        case .staticAnalysis:        return .gray.opacity(0.18)
        case .observed:              return .green.opacity(0.18)
        case .bestEffort:            return .orange.opacity(0.22)
        case .requiresEntitlement:   return .blue.opacity(0.18)
        }
    }
    private var foreground: Color {
        switch fidelity {
        case .staticAnalysis:        return .primary
        case .observed:              return .green
        case .bestEffort:            return .orange
        case .requiresEntitlement:   return .blue
        }
    }
    private var help: String {
        switch fidelity {
        case .staticAnalysis:
            return "Read directly from the bundle, deterministic."
        case .observed:
            return "Captured during the run and attributed to a tracked process."
        case .bestEffort:
            return "Captured by polling-based tools that may have missed events. Treat as a sample, not a complete log."
        case .requiresEntitlement:
            return "This data is unavailable in the current build. Enabling it requires an Apple-granted entitlement (Endpoint Security or Network Extension) or a privileged helper."
        }
    }
}
