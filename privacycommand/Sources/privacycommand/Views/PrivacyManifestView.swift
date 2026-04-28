import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Renders the bundle's `PrivacyInfo.xcprivacy` manifest plus a
/// cross-check against the binary's observed symbol references.
struct PrivacyManifestView: View {
    let manifest: PrivacyManifest?
    let crossCheck: PrivacyManifestCrossCheck?

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Text("Privacy manifest")
            InfoButton(articleID: "privacy-manifest")
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if let manifest {
                    headerRow(manifest)
                    if !manifest.trackingDomains.isEmpty {
                        trackingDomains(manifest.trackingDomains)
                    }
                    if !manifest.collectedDataTypes.isEmpty {
                        collectedDataSection(manifest.collectedDataTypes)
                    }
                    if !manifest.accessedAPITypes.isEmpty {
                        accessedAPISection(manifest.accessedAPITypes)
                    }
                    if let xc = crossCheck, !xc.isClean {
                        Divider()
                        crossCheckSection(xc)
                    }
                } else {
                    notShipped
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notShipped: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
                Text("No PrivacyInfo.xcprivacy shipped").font(.callout.bold())
            }
            Text("Apple's privacy manifest declares what data the app collects, the tracking domains it uses, and which 'required-reason' APIs it accesses. Required for App Store apps since May 2024; optional outside.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headerRow(_ m: PrivacyManifest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.isTrackingDeclared ? "Yes" : "No")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(m.isTrackingDeclared ? .orange : .green)
                Text("declares tracking").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(m.trackingDomains.count)").font(.title3.monospacedDigit().bold())
                Text("tracking domain\(m.trackingDomains.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(m.collectedDataTypes.count)").font(.title3.monospacedDigit().bold())
                Text("collected data type\(m.collectedDataTypes.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(m.accessedAPITypes.count)").font(.title3.monospacedDigit().bold())
                Text("required-reason API claim\(m.accessedAPITypes.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func trackingDomains(_ domains: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tracking domains").font(.subheadline.bold())
            ForEach(domains, id: \.self) { d in
                Text(d).font(.caption.monospaced()).textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func collectedDataSection(_ list: [PrivacyManifest.CollectedDataType]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Collected data types").font(.subheadline.bold())
            ForEach(list) { d in
                HStack(alignment: .firstTextBaseline) {
                    Text(d.displayName).font(.caption)
                    if d.linkedToUser     { tag("linked", .orange) }
                    if d.usedForTracking  { tag("tracking", .red) }
                    Spacer()
                    Text(d.purposes.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    private func accessedAPISection(_ list: [PrivacyManifest.AccessedAPI]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Required-reason API claims").font(.subheadline.bold())
            ForEach(list) { a in
                HStack(alignment: .firstTextBaseline) {
                    Text(a.category.rawValue).font(.caption.bold())
                    Spacer()
                    Text(a.reasons.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func crossCheckSection(_ xc: PrivacyManifestCrossCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manifest vs binary").font(.subheadline.bold())
            ForEach(xc.declaredButUnused, id: \.self) { cat in
                HStack {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
                    Text("\(cat.rawValue) declared but no symbol references found.")
                        .font(.caption)
                }
            }
            ForEach(xc.usedButUndeclared) { miss in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(miss.category.rawValue) used by binary but not declared.")
                            .font(.caption)
                        Text("Evidence: \(miss.evidence.joined(separator: ", "))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(c)
    }
}
