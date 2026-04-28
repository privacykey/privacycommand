import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Expandable row for a nested bundle (XPC service, helper, login item).
/// On first expansion, asks the coordinator to analyze the sub-bundle and
/// shows a compact sub-report inline. Subsequent expansions reuse the cached
/// analysis.
struct EmbeddedBundleRow: View {
    let bundle: BundleRef
    let kind: String

    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            expansion
                .padding(.top, 6)
                .padding(.leading, 4)
        } label: {
            header
        }
        .onChange(of: expanded) { newValue in
            if newValue {
                coordinator.analyzeSubBundle(at: bundle.url)
            }
        }
    }

    // MARK: - Header (collapsed-state row)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: bundle.isXPCService ? "shippingbox.and.arrow.backward"
                              : bundle.isLoginItem ? "power"
                              : "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(bundle.bundleID ?? bundle.url.lastPathComponent).font(.callout.bold())
                Text("\(kind) — \(bundle.teamID ?? "no team")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Show a risk badge once analysis has completed.
            if let report = coordinator.subBundleAnalyses[bundle.url] {
                let score = RiskScorer().score(staticReport: report)
                RiskTierBadge(score: score)
            } else if coordinator.subBundleAnalyzing.contains(bundle.url) {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Expansion (lazy sub-report)

    @ViewBuilder
    private var expansion: some View {
        if coordinator.subBundleAnalyzing.contains(bundle.url) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Analyzing \(bundle.url.lastPathComponent)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let err = coordinator.subBundleErrors[bundle.url] {
            Label(err, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
        } else if let report = coordinator.subBundleAnalyses[bundle.url] {
            SubBundleReportView(report: report)
        } else {
            Text("Tap to analyze").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compact sub-report

/// Compact static-analysis summary shown inline inside an EmbeddedBundleRow's
/// expansion. Highlights the things that matter most when sizing up a nested
/// bundle: declared privacy keys, notable entitlements, signing posture, and
/// any findings.
struct SubBundleReportView: View {
    let report: StaticReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Bundle metadata strip.
            metadata

            // Declared privacy keys as chips.
            if !report.declaredPrivacyKeys.isEmpty {
                privacyKeysSection
            }

            // Notable entitlements (only the ones we'd flag at the top level).
            if hasNotableEntitlements {
                entitlementsSection
            }

            // Findings — same as Dashboard, but compact.
            if !report.warnings.isEmpty {
                findingsSection
            }

            // Hard-coded domains/paths if any — collapsed by default.
            if !report.hardcodedDomains.isEmpty || !report.hardcodedPaths.isEmpty {
                hardcodedSection
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if let v = report.bundle.bundleVersion {
                tag("v\(v)")
            }
            tag(report.entitlements.isSandboxed ? "sandboxed" : "unsandboxed",
                color: report.entitlements.isSandboxed ? .green : .orange)
            tag(report.codeSigning.hardenedRuntime ? "hardened-runtime"
                                                  : "no hardened-runtime",
                color: report.codeSigning.hardenedRuntime ? .green : .orange)
            switch report.notarization {
            case .notarized:           tag("notarized", color: .green)
            case .developerIDOnly:     tag("Dev ID — not notarized", color: .orange)
            case .unsigned:            tag("unsigned", color: .red)
            case .rejected:            tag("rejected", color: .red)
            case .unknown:             EmptyView()
            }
            Spacer()
        }
    }

    private var privacyKeysSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Declared privacy keys").font(.caption.bold()).foregroundStyle(.secondary)
            FlowingTags(items: report.declaredPrivacyKeys.map { ($0.humanLabel, "privacy-\($0.category.rawValue)") })
        }
    }

    private var hasNotableEntitlements: Bool {
        report.entitlements.endpointSecurityClient ||
        !report.entitlements.networkExtension.isEmpty ||
        report.entitlements.disablesLibraryValidation ||
        report.entitlements.allowsDyldEnvironmentVariables ||
        report.entitlements.appleEvents != nil
    }

    private var entitlementsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notable entitlements").font(.caption.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if report.entitlements.endpointSecurityClient {
                    entitlementChip("Endpoint Security client", id: "com.apple.developer.endpoint-security.client", color: .red)
                }
                if !report.entitlements.networkExtension.isEmpty {
                    entitlementChip("Network Extension: \(report.entitlements.networkExtension.joined(separator: ", "))",
                                    id: "com.apple.developer.networking.networkextension", color: .blue)
                }
                if report.entitlements.disablesLibraryValidation {
                    entitlementChip("Library validation disabled",
                                    id: "com.apple.security.cs.disable-library-validation", color: .orange)
                }
                if report.entitlements.allowsDyldEnvironmentVariables {
                    entitlementChip("DYLD env vars allowed",
                                    id: "com.apple.security.cs.allow-dyld-environment-variables", color: .orange)
                }
                if let appleEvts = report.entitlements.appleEvents {
                    switch appleEvts {
                    case .anyApp:
                        entitlementChip("Apple Events: any app",
                                        id: "com.apple.security.automation.apple-events", color: .orange)
                    case .bundleIDs(let ids):
                        entitlementChip("Apple Events: \(ids.prefix(2).joined(separator: ", "))\(ids.count > 2 ? "…" : "")",
                                        id: "com.apple.security.automation.apple-events", color: .secondary)
                    }
                }
            }
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Findings (\(report.warnings.count))").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(report.warnings) { f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: f.severity == .error ? "xmark.octagon"
                                    : f.severity == .warn ? "exclamationmark.triangle"
                                    : "info.circle")
                        .foregroundStyle(severityColor(f.severity))
                        .imageScale(.small)
                    Text(f.message).font(.callout)
                    InfoButton(articleID: f.kbArticleID)
                }
            }
        }
    }

    private var hardcodedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                if !report.hardcodedDomains.isEmpty {
                    Text("Domains: \(report.hardcodedDomains.prefix(8).joined(separator: ", "))\(report.hardcodedDomains.count > 8 ? "…" : "")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !report.hardcodedPaths.isEmpty {
                    Text("Paths: \(report.hardcodedPaths.prefix(4).joined(separator: ", "))\(report.hardcodedPaths.count > 4 ? "…" : "")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } label: {
            Text("Hard-coded references (\(report.hardcodedDomains.count) domains, \(report.hardcodedPaths.count) paths)")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Small helpers

    private func tag(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }

    private func entitlementChip(_ text: String, id: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.callout)
            InfoButton(articleID: id)
        }
    }

    private func severityColor(_ s: Finding.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        }
    }
}

// MARK: - FlowingTags

/// Wrapping flow layout for privacy-key chips. macOS 13 doesn't have
/// SwiftUI's `Layout` protocol-driven `FlowLayout`, so we use a simple
/// approximation: HStacks of ~3 chips wrapped via `LazyVGrid`.
private struct FlowingTags: View {
    let items: [(label: String, kbArticleID: String)]

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 110), spacing: 6)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Text(item.label)
                        .font(.caption.weight(.medium))
                    InfoButton(articleID: item.kbArticleID)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: .capsule)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}
