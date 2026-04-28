import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Dashboard card that calls out **embedded telemetry** at a glance — the
/// analytics, advertising, and attribution SDKs that exist primarily to
/// observe user behaviour and ship it off-device.
///
/// **Why a separate card.** SDK fingerprints already appear in the Static
/// tab's `SDKHitsView`, but the Static tab is a long scroll and a user
/// glancing at the Dashboard shouldn't have to dig for the headline answer
/// to "is this app spying on me?". This card answers that in three lines:
/// the count, the per-category breakdown, and the actual SDK names.
///
/// **Quiet when nothing's there.** A bundle that doesn't ship any
/// analytics/ad/attribution SDKs gets a green confirmation row instead of
/// the loud orange/red treatment — the absence is itself a useful signal
/// and worth showing without being alarmist.
struct TelemetrySummaryCard: View {
    let hits: [SDKHit]

    private var telemetryHits: [SDKHit] {
        hits.filter(\.isTelemetry)
    }

    private var analytics: [SDKHit] {
        telemetryHits.filter { $0.fingerprint.category == .analytics }
    }
    private var advertising: [SDKHit] {
        telemetryHits.filter { $0.fingerprint.category == .advertising }
    }
    private var attribution: [SDKHit] {
        telemetryHits.filter { $0.fingerprint.category == .attribution }
    }

    /// Heat colour for the headline — escalates with the count.
    private var headlineColour: Color {
        switch telemetryHits.count {
        case 0:    return .green
        case 1:    return .yellow
        case 2...3: return .orange
        default:   return .red
        }
    }

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Image(systemName: telemetryHits.isEmpty
                  ? "checkmark.shield"
                  : "antenna.radiowaves.left.and.right")
                .foregroundStyle(headlineColour)
            Text("Embedded telemetry")
                .font(.headline)
            InfoButton(articleID: "telemetry-overview")
        }) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                if !telemetryHits.isEmpty {
                    Divider()
                    breakdown
                    Divider()
                    sdkList
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Headline

    @ViewBuilder
    private var headline: some View {
        if telemetryHits.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("No analytics, advertising, or attribution SDKs detected.")
                    .font(.callout)
                Spacer()
            }
            Text("The bundle may still ship hand-rolled tracking that doesn't match a known fingerprint. The Static tab's hard-coded domains list is the second place to look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(telemetryHits.count)")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(headlineColour)
                VStack(alignment: .leading, spacing: 2) {
                    Text(telemetryHits.count == 1
                         ? "tracking SDK embedded"
                         : "tracking SDKs embedded")
                        .font(.headline)
                    Text("Analytics, advertising, and attribution platforms — they exist to observe what users do and ship it off-device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // MARK: - Per-category breakdown

    private var breakdown: some View {
        HStack(spacing: 16) {
            categoryCounter(icon: SDKCategory.analytics.icon,
                            value: analytics.count,
                            label: "analytics",
                            colour: analytics.isEmpty ? .secondary : .orange)
            categoryCounter(icon: SDKCategory.advertising.icon,
                            value: advertising.count,
                            label: "advertising",
                            colour: advertising.isEmpty ? .secondary : .red)
            categoryCounter(icon: SDKCategory.attribution.icon,
                            value: attribution.count,
                            label: "attribution",
                            colour: attribution.isEmpty ? .secondary : .orange)
            Spacer()
        }
    }

    private func categoryCounter(icon: String, value: Int, label: String, colour: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(colour)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - SDK list

    private var sdkList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detected")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            ForEach(telemetryHits) { hit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: hit.fingerprint.category.icon)
                        .foregroundStyle(badgeColour(for: hit))
                        .frame(width: 18)
                    Text(hit.fingerprint.displayName)
                        .font(.callout.bold())
                    Text("·").foregroundStyle(.tertiary)
                    Text(hit.fingerprint.vendor)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(hit.fingerprint.category.rawValue)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(badgeColour(for: hit).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(badgeColour(for: hit))
                    if hit.fingerprint.kbArticleID != nil {
                        InfoButton(articleID: hit.fingerprint.kbArticleID)
                    }
                }
            }
            HStack {
                Spacer()
                Text("Full SDK list and evidence in the Static tab →")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badgeColour(for hit: SDKHit) -> Color {
        switch hit.fingerprint.category {
        case .advertising:  return .red
        case .analytics:    return .orange
        case .attribution:  return .orange
        default:            return .secondary
        }
    }
}
