import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Dashboard card that displays an app's **App Store Privacy Nutrition
/// Labels** — the structured "what data does this app collect?"
/// declaration the developer was forced to fill in to ship through the
/// Mac App Store.
///
/// **What this is showing.** Apple groups the developer's declarations
/// into four canonical buckets:
///   1. **Data Used to Track You** — data that's linked to advertising
///      identifiers or otherwise sent to third parties for cross-site
///      tracking. The most severe bucket.
///   2. **Data Linked to You** — collected and tied to the user's
///      identity (account, device ID, name, …).
///   3. **Data Not Linked to You** — collected but stripped of
///      identifying ties before storage.
///   4. **Data Not Collected** — the explicit "we don't take this".
///
/// **Why we show it on the Dashboard.** It's the developer's own
/// statement, not Auditor's inference, and it carries legal weight —
/// Apple can pull an app for misrepresentation. Surfacing it next to
/// our static-analysis findings lets the user compare the developer's
/// declared behaviour against what the binary actually contains. If
/// the binary embeds Firebase Analytics but the labels say "Data Not
/// Collected", that's a discrepancy worth investigating.
///
/// **Empty / loading / error states.** We render a card in every case
/// so the user knows whether we *tried*: a spinner during fetch, an
/// inline error if the network call failed, the actual labels when
/// they arrive, or a "no labels declared" state when Apple's "No
/// Details Provided" disclaimer is on the product page.
struct PrivacyLabelsCard: View {
    let info: AppStoreInfo
    let isFetching: Bool

    var body: some View {
        // Non-MAS bundles: we render nothing rather than a green
        // "not from the App Store" card every time. Detection is
        // surfaced more prominently if it ever becomes useful as a
        // standalone signal.
        if info.isMASApp {
            GroupBox(label: header) {
                VStack(alignment: .leading, spacing: 12) {
                    storeMetadataRow

                    if isFetching {
                        loadingRow
                    } else if let labels = info.privacyLabels, !labels.isEmpty {
                        // `isEmpty` here means "no privacy types at all",
                        // not "no categories" — so a developer who
                        // declared only `DATA_NOT_COLLECTED` (a lone
                        // type with zero categories) still falls into
                        // this branch and gets the green positive
                        // rendering, instead of being misclassified as
                        // "no details provided".
                        Divider()
                        labelsBody(labels)
                    } else if info.privacyDetailsStatus == .noDetailsProvided {
                        Divider()
                        noDetailsRow
                    } else if let err = info.error {
                        Divider()
                        errorRow(err)
                    }

                    if let policy = info.privacyPolicyURL,
                       let url = URL(string: policy) {
                        Divider()
                        policyRow(url: url)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.blue)
            Text("Mac App Store privacy labels")
                .font(.headline)
            InfoButton(articleID: "privacy-labels-overview")
        }
    }

    // MARK: - Store metadata

    @ViewBuilder
    private var storeMetadataRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "bag")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(info.storeName ?? info.bundleID ?? "App Store app")
                        .font(.callout.bold())
                    if let v = info.storeVersion {
                        Text("v\(v)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let seller = info.sellerName, !seller.isEmpty {
                        Text(seller).font(.caption).foregroundStyle(.secondary)
                    }
                    if let genre = info.genreName, !genre.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(genre).font(.caption).foregroundStyle(.secondary)
                    }
                    if let price = info.priceFormatted, !price.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(price).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let urlString = info.trackViewURL,
               let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Open on App Store").font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Loading / error / no-details rows

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Fetching privacy labels from the App Store…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var noDetailsRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Developer has not provided privacy details.")
                    .font(.callout.bold())
                Text("Apple shows the \"No Details Provided\" disclaimer for this app. The developer will be required to provide privacy details with their next submission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't fetch privacy labels.")
                    .font(.callout.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func policyRow(url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("Privacy policy:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(url.absoluteString, destination: url)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: - Labels body

    private func labelsBody(_ labels: PrivacyLabels) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(orderedTypes(in: labels)) { type in
                privacyTypeSection(type)
            }
        }
    }

    /// Apple's canonical severity order, with anything unfamiliar
    /// appended in source order at the bottom so a future identifier
    /// doesn't disappear.
    private func orderedTypes(in labels: PrivacyLabels) -> [PrivacyLabels.PrivacyType] {
        let order = PrivacyLabels.TypeIdentifier.displayOrder.map(\.rawValue)
        let known = labels.types.filter { order.contains($0.identifier) }
        let unknown = labels.types.filter { !order.contains($0.identifier) }
        let sortedKnown = known.sorted {
            (order.firstIndex(of: $0.identifier) ?? .max)
            < (order.firstIndex(of: $1.identifier) ?? .max)
        }
        return sortedKnown + unknown
    }

    private func privacyTypeSection(_ type: PrivacyLabels.PrivacyType) -> some View {
        let colour = colour(for: type.identifier)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: type.identifier))
                    .foregroundStyle(colour)
                Text(type.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(colour)
                Text("(\(type.categories.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if type.categories.isEmpty {
                Text(emptyMessage(for: type.identifier))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            } else {
                FlexibleChipRow(items: type.categories)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    /// Per-bucket colour: red for tracking, orange for linked,
    /// blue for not-linked, green for not-collected. Matches the
    /// SwiftUI `severity` palette used elsewhere in the app.
    private func colour(for identifier: String) -> Color {
        switch identifier {
        case PrivacyLabels.TypeIdentifier.usedToTrack.rawValue:  return .red
        case PrivacyLabels.TypeIdentifier.linked.rawValue:       return .orange
        case PrivacyLabels.TypeIdentifier.notLinked.rawValue:    return .blue
        case PrivacyLabels.TypeIdentifier.notCollected.rawValue: return .green
        default: return .secondary
        }
    }

    private func icon(for identifier: String) -> String {
        switch identifier {
        case PrivacyLabels.TypeIdentifier.usedToTrack.rawValue:  return "eye.trianglebadge.exclamationmark"
        case PrivacyLabels.TypeIdentifier.linked.rawValue:       return "person.crop.circle.badge.exclamationmark"
        case PrivacyLabels.TypeIdentifier.notLinked.rawValue:    return "person.crop.circle.badge.questionmark"
        case PrivacyLabels.TypeIdentifier.notCollected.rawValue: return "checkmark.shield"
        default: return "shield"
        }
    }

    /// Per-bucket empty-state copy.
    ///
    /// `DATA_NOT_COLLECTED` is special — its presence in the labels is
    /// itself the declaration. An empty `categories` array under it
    /// means "the developer states the app collects nothing", which is
    /// the strongest privacy answer the App Store offers. We say so
    /// directly rather than the generic "(none declared)" copy used for
    /// the data-collected buckets when the developer simply chose not
    /// to put anything in them.
    ///
    /// This is **distinct** from Apple's "No Details Provided"
    /// disclaimer (rendered by `noDetailsRow`), which fires when the
    /// developer never filled in the form at all. See
    /// `PrivacyLabels.isEmpty` and `isExplicitlyNotCollected` for the
    /// upstream classification.
    private func emptyMessage(for identifier: String) -> String {
        if identifier == PrivacyLabels.TypeIdentifier.notCollected.rawValue {
            return "The developer states this app does not collect any data."
        }
        return "(none declared)"
    }
}

/// Tag-style flow layout for category chips. SwiftUI doesn't ship a
/// proper FlowLayout below macOS 13 / iOS 16, so we use a simple
/// `HStack` wrapped in a `LazyVGrid` of adaptive columns — chips wrap
/// to as many rows as needed without manual size measurement.
private struct FlexibleChipRow: View {
    let items: [PrivacyLabels.DataCategory]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items) { cat in
                HStack(spacing: 4) {
                    Image(systemName: chipIcon(for: cat.identifier))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(cat.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Coarse SF Symbol per category identifier. Keeps chips
    /// recognisable without being noisy.
    private func chipIcon(for identifier: String) -> String {
        switch identifier {
        case "LOCATION":           return "location"
        case "IDENTIFIERS":        return "number"
        case "USAGE_DATA":         return "chart.bar"
        case "CONTACT_INFO":       return "person.text.rectangle"
        case "FINANCIAL_INFO":     return "dollarsign.circle"
        case "HEALTH_AND_FITNESS": return "heart"
        case "SENSITIVE_INFO":     return "exclamationmark.shield"
        case "USER_CONTENT":       return "doc.text"
        case "BROWSING_HISTORY":   return "safari"
        case "SEARCH_HISTORY":     return "magnifyingglass"
        case "CONTACTS":           return "person.2"
        case "PURCHASES":          return "creditcard"
        case "DIAGNOSTICS":        return "stethoscope"
        case "OTHER":              return "ellipsis.circle"
        default:                   return "circle"
        }
    }
}
