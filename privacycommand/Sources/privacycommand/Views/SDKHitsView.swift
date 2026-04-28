import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// "Telemetry & third-party SDKs" section for the Static Analysis tab.
/// Groups detected SDKs by category, with a header tally that highlights the
/// tracker-class ones (analytics + advertising + attribution + push).
struct SDKHitsView: View {
    let hits: [SDKHit]

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Text("Telemetry & third-party SDKs")
            InfoButton(articleID: "sdk-trackers")
        }) {
            VStack(alignment: .leading, spacing: 10) {
                summary

                if hits.isEmpty {
                    Text("No known third-party SDKs detected. The bundle may still ship analytics code that doesn't match a known fingerprint — particularly if it's been statically linked or built from source.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !trackingGroups.isEmpty {
                        trackingBand
                        ForEach(trackingGroups, id: \.category) { group in
                            sectionView(group: group)
                        }
                    }
                    if !supportingGroups.isEmpty {
                        if !trackingGroups.isEmpty {
                            Divider().padding(.vertical, 2)
                            Text("Supporting SDKs")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(supportingGroups, id: \.category) { group in
                            sectionView(group: group)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Summary line

    private var summary: some View {
        let telemetryCount = hits.filter(\.isTelemetry).count
        let trackerCount   = hits.filter(\.isTrackerLike).count
        let nonTrackerCount = hits.count - trackerCount

        return HStack(spacing: 16) {
            tally(value: hits.count, label: "SDKs detected", colour: .primary)
            tally(value: telemetryCount, label: "telemetry",
                  colour: telemetryCount > 0 ? .red : .secondary)
            tally(value: trackerCount, label: "tracker-class",
                  colour: trackerCount > 0 ? .orange : .secondary)
            tally(value: nonTrackerCount, label: "supporting",
                  colour: .secondary)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func tally(value: Int, label: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(colour)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private struct Group: Identifiable {
        let category: SDKCategory
        let hits: [SDKHit]
        var id: SDKCategory { category }
    }

    private var grouped: [Group] {
        let byCat = Dictionary(grouping: hits, by: \.fingerprint.category)
        // Iterate the canonical ordering so the section order is deterministic.
        return SDKCategory.allCases.compactMap { cat in
            guard let hs = byCat[cat], !hs.isEmpty else { return nil }
            return Group(category: cat, hits: hs)
        }
    }

    /// Groups whose category is telemetry — analytics, advertising,
    /// attribution. Rendered first under a coloured "Tracking" band.
    private var trackingGroups: [Group] {
        grouped.filter(\.category.isTelemetry)
    }

    /// Everything else — crash, performance, support, auth, payments,
    /// push, feature flags, logging, feedback. Quieter visual treatment.
    private var supportingGroups: [Group] {
        grouped.filter { !$0.category.isTelemetry }
    }

    /// Coloured callout bar that prefaces the tracking-class sections so
    /// they're visually distinct from the supporting SDKs that follow.
    private var trackingBand: some View {
        let count = trackingGroups.reduce(0) { $0 + $1.hits.count }
        return HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.red)
            Text("Tracking — \(count) SDK\(count == 1 ? "" : "s") that exists to observe user behaviour")
                .font(.subheadline.bold())
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sectionView(group: Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: group.category.icon)
                    .foregroundStyle(.secondary)
                Text(group.category.rawValue)
                    .font(.subheadline.bold())
                Text("(\(group.hits.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(group.hits) { hit in
                hitRow(hit)
            }
        }
        .padding(.vertical, 2)
    }

    private func hitRow(_ hit: SDKHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hit.fingerprint.displayName).font(.callout.bold())
                Text("·").foregroundStyle(.tertiary)
                Text(hit.fingerprint.vendor)
                    .font(.callout).foregroundStyle(.secondary)
                if hit.fingerprint.kbArticleID != nil {
                    InfoButton(articleID: hit.fingerprint.kbArticleID)
                }
                Spacer()
            }
            Text(hit.fingerprint.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Evidence row — small, monospaced, helps the user audit *why*
            // we flagged it.
            HStack(spacing: 8) {
                ForEach(hit.evidence, id: \.label) { ev in
                    Text(ev.label)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 2)
    }
}
