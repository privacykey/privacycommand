import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct StaticAnalysisView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var previewingUpdates = false

    /// Machine-state-dependent fields recomputed each time the bundle
    /// changes. We don't persist these in StaticReport because they vary
    /// across machines (a stored report shouldn't claim "this Mac has
    /// this in BTM" forever).
    @State private var sandboxContainer: SandboxContainerInfo = .init(state: .noBundleID)
    @State private var btmAudit: BTMAuditResult = .init(state: .notRequested)
    /// True while the user-clicked "Run BTM audit" button is shelling
    /// out to sfltool (the direct, admin-prompting path). Drives the
    /// progress spinner inside `BTMAuditView`'s opt-in card.
    @State private var btmRunning = false
    @EnvironmentObject private var helperInstaller: HelperInstaller

    /// Anchor IDs for the Jump-to-section popover. Each section is
    /// `.id(SectionAnchor.<case>.rawValue)`-tagged inside the scroll view
    /// so ScrollViewReader can scroll directly to it.
    enum SectionAnchor: String, CaseIterable, Identifiable {
        case bundle, disassembler, provenance, updateMechanism, signing
        case entitlements, urlSchemes, ats, docTypes, notarizationDeep
        case privacyManifest, sandboxContainer, btm
        case secrets, bundleSigning, antiAnalysis, rpath
        case privacyClaims, embeddedAssets, helpers
        case sdks, flags, domains, paths
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bundle:           return "Bundle"
            case .disassembler:     return "Reverse-engineering tools"
            case .provenance:       return "Provenance"
            case .updateMechanism:  return "Update mechanism"
            case .signing:          return "Code signing"
            case .entitlements:     return "Entitlements"
            case .urlSchemes:       return "URL schemes"
            case .ats:              return "App Transport Security"
            case .docTypes:         return "Document types"
            case .notarizationDeep: return "Notarization deep dive"
            case .privacyManifest:  return "Privacy manifest"
            case .sandboxContainer: return "Sandbox container"
            case .btm:              return "Background Task Management"
            case .secrets:          return "Hard-coded credentials"
            case .bundleSigning:    return "Whole-bundle signing audit"
            case .antiAnalysis:     return "Anti-analysis signals"
            case .rpath:            return "Dynamic linking surface"
            case .privacyClaims:    return "Privacy claims vs. usage"
            case .embeddedAssets:   return "Embedded scripts & launchd"
            case .helpers:          return "Helpers / XPC services"
            case .sdks:             return "Telemetry & SDKs"
            case .flags:            return "Feature flags & trials"
            case .domains:          return "Hard-coded domains"
            case .paths:            return "Hard-coded paths"
            }
        }
    }

    var body: some View {
        if let report = coordinator.staticReport {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        jumpToBar(proxy: proxy)
                        bundleHeader(report).id(SectionAnchor.bundle.rawValue)
                        BundleInspectorLauncher(bundleURL: report.bundle.url)
                        DisassemblerLauncher(executableURL: report.bundle.executableURL,
                                             bundleURL: report.bundle.url)
                            .id(SectionAnchor.disassembler.rawValue)
                        ProvenanceSection(provenance: report.provenance,
                                          bundleURL: report.bundle.url)
                            .id(SectionAnchor.provenance.rawValue)
                        if let mechanism = report.updateMechanism {
                            updateSection(report: report, mechanism: mechanism)
                                .id(SectionAnchor.updateMechanism.rawValue)
                        }
                        signing(report).id(SectionAnchor.signing.rawValue)
                        entitlements(report).id(SectionAnchor.entitlements.rawValue)
                        urlSchemes(report).id(SectionAnchor.urlSchemes.rawValue)
                        if let ats = report.atsConfig, ats.hasAnyException {
                            ATSSection(ats: ats).id(SectionAnchor.ats.rawValue)
                        }
                        docTypes(report).id(SectionAnchor.docTypes.rawValue)
                        NotarizationDeepDiveView(report: report.notarizationDeepDive)
                            .id(SectionAnchor.notarizationDeep.rawValue)
                        PrivacyManifestView(
                            manifest: report.privacyManifest,
                            crossCheck: report.privacyManifest.map {
                                PrivacyManifestReader.crossCheck(
                                    manifest: $0,
                                    scan: BinaryStringScanner.scan(executable: report.bundle.executableURL))
                            })
                            .id(SectionAnchor.privacyManifest.rawValue)
                        SandboxContainerView(info: sandboxContainer)
                            .id(SectionAnchor.sandboxContainer.rawValue)
                        BTMAuditView(
                            result: btmAudit,
                            isRunning: btmRunning,
                            helperInstalled: helperInstaller.status == .installed,
                            onRunDirect: { runBTMDirect(bundle: report.bundle) }
                        )
                            .id(SectionAnchor.btm.rawValue)
                        SecretsView(findings: report.secrets)
                            .id(SectionAnchor.secrets.rawValue)
                        BundleSigningAuditView(audit: report.bundleSigning)
                            .id(SectionAnchor.bundleSigning.rawValue)
                        AntiAnalysisView(findings: report.antiAnalysis)
                            .id(SectionAnchor.antiAnalysis.rawValue)
                        RPathAuditView(audit: report.rpathAudit)
                            .id(SectionAnchor.rpath.rawValue)
                        PrivacyClaimsView(inferred: report.inferredCapabilities)
                            .id(SectionAnchor.privacyClaims.rawValue)
                        EmbeddedAssetsView(assets: report.embeddedAssets)
                            .id(SectionAnchor.embeddedAssets.rawValue)
                        helpers(report).id(SectionAnchor.helpers.rawValue)
                        SDKHitsView(hits: report.sdkHits)
                            .id(SectionAnchor.sdks.rawValue)
                        FlagsView(findings: report.flagFindings)
                            .id(SectionAnchor.flags.rawValue)
                        domains(report).id(SectionAnchor.domains.rawValue)
                        paths(report).id(SectionAnchor.paths.rawValue)
                    }
                    .padding(20)
                }
            }
            .task(id: report.bundle.url) {
                // Recompute machine-state passes whenever the bundle changes.
                let bundle = report.bundle
                sandboxContainer = SandboxContainerInspector.inspect(bundle: bundle)

                // BTM audit. We deliberately do NOT shell out to
                // /usr/bin/sfltool here — on macOS 14+ sfltool dumpbtm
                // triggers an Authorization Services prompt for an
                // admin password, and clicking the Static tab should
                // never spring that on the user. Two paths instead:
                //   1. Helper installed → call over XPC. Helper is
                //      root, so it runs sfltool without any prompt.
                //   2. Helper not installed → leave state as
                //      `.notRequested`. The opt-in button in
                //      `BTMAuditView` runs `auditDirect` only when the
                //      user clicks (the prompt is then expected, not
                //      a surprise).
                btmAudit = .init(state: .notRequested)
                btmRunning = false
                if helperInstaller.status == .installed {
                    await runBTMViaHelper(bundle: bundle)
                }
            }
        } else {
            Text("No bundle selected").foregroundStyle(.secondary)
        }
    }

    // MARK: - BTM audit dispatch

    /// Helper-driven path: ask the privileged helper to run
    /// `sfltool dumpbtm` and return its stdout, then parse the
    /// result here in the GUI process. No admin prompt, no shelling
    /// out from the unprivileged app.
    private func runBTMViaHelper(bundle: AppBundle) async {
        btmRunning = true
        defer { btmRunning = false }

        let output: String? = await withCheckedContinuation { continuation in
            // The HelperInstaller exposes the live XPC connection.
            // If it can't be obtained right now (helper crashed,
            // first-call resolve failure, etc.) we fall back to
            // `.failed` — the opt-in button in BTMAuditView remains
            // available as a manual recovery path.
            helperInstaller.dumpBTM { stdout, error in
                if let error {
                    Task { @MainActor in
                        btmAudit = .init(state: .failed(error))
                    }
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: stdout)
                }
            }
        }

        guard let output else { return }
        btmAudit = BTMAuditor.auditOutput(output, bundle: bundle)
    }

    /// Direct path: invoked when the user clicks the opt-in button
    /// in `BTMAuditView`. Will trigger an admin prompt on macOS 14+;
    /// that's expected because the user explicitly asked for it.
    private func runBTMDirect(bundle: AppBundle) {
        btmRunning = true
        Task.detached(priority: .userInitiated) {
            let result = BTMAuditor.auditDirect(bundle: bundle)
            await MainActor.run {
                btmAudit = result
                btmRunning = false
            }
        }
    }

    /// Sticky bar with a Jump-to picker and a hint about how many sections
    /// are below. Lives at the top of the scroll content (not the chrome)
    /// so it scrolls away — keeps the page clean once the user is reading
    /// a specific section.
    @ViewBuilder
    private func jumpToBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SectionAnchor.allCases) { anchor in
                    Button(anchor.label) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor.rawValue, anchor: .top)
                        }
                    }
                }
            } label: {
                Label("Jump to section…", systemImage: "list.bullet.below.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Text("\(SectionAnchor.allCases.count) sections")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func bundleHeader(_ r: StaticReport) -> some View {
        GroupBox("Bundle") {
            HStack {
                grid(
                    ("Bundle ID", r.bundle.bundleID ?? "—"),
                    ("Version", r.bundle.bundleVersion ?? "—"),
                    ("Min macOS", r.bundle.minimumSystemVersion ?? "—"),
                    ("Architectures", r.bundle.architectures.joined(separator: ", "))
                )
                Spacer()
                FidelityBadge(.staticAnalysis)
            }.padding(8)
        }
    }

    private func signing(_ r: StaticReport) -> some View {
        GroupBox("Code signing") {
            HStack {
                grid(
                    ("Team ID", r.codeSigning.teamIdentifier ?? "—"),
                    ("Identifier", r.codeSigning.signingIdentifier ?? "—"),
                    ("Hardened Runtime", r.codeSigning.hardenedRuntime ? "yes" : "no"),
                    ("Validates", r.codeSigning.validates ? "yes" : "no"),
                    ("Notarization", notarizationLabel(r.notarization))
                )
                Spacer()
                FidelityBadge(.staticAnalysis)
            }
            if let req = r.codeSigning.designatedRequirement {
                Text(req).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func notarizationLabel(_ n: NotarizationStatus) -> String {
        switch n {
        case .notarized:           return "notarized"
        case .developerIDOnly:     return "Developer ID (not notarized)"
        case .unsigned:            return "unsigned"
        case .rejected(let m):     return "rejected: \(m.prefix(80))"
        case .unknown(let m):      return "unknown: \(m.prefix(80))"
        }
    }

    private func entitlements(_ r: StaticReport) -> some View {
        GroupBox("Entitlements") {
            VStack(alignment: .leading, spacing: 6) {
                entRow("Sandboxed", value: r.entitlements.isSandboxed ? "yes" : "no",
                       articleID: "com.apple.security.app-sandbox")
                if !r.entitlements.appGroups.isEmpty {
                    entRow("App groups",
                           value: r.entitlements.appGroups.joined(separator: ", "),
                           articleID: "com.apple.security.application-groups")
                }
                entRow("Network client",
                       value: r.entitlements.networkClient ? "yes" : "no",
                       articleID: "com.apple.security.network.client")
                entRow("Network server",
                       value: r.entitlements.networkServer ? "yes" : "no",
                       articleID: "com.apple.security.network.server")
                entRow("Allow JIT",
                       value: r.entitlements.allowsJIT ? "yes" : "no",
                       articleID: "com.apple.security.cs.allow-jit")
                entRow("Allow DYLD env vars",
                       value: r.entitlements.allowsDyldEnvironmentVariables ? "yes" : "no",
                       articleID: "com.apple.security.cs.allow-dyld-environment-variables")
                entRow("Library validation disabled",
                       value: r.entitlements.disablesLibraryValidation ? "yes" : "no",
                       articleID: "com.apple.security.cs.disable-library-validation")
                if r.entitlements.endpointSecurityClient {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.red)
                        Text("Endpoint Security client (Apple-granted entitlement).")
                        InfoButton(articleID: "com.apple.developer.endpoint-security.client")
                    }
                }
                if !r.entitlements.networkExtension.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
                        Text("Network Extension: \(r.entitlements.networkExtension.joined(separator: ", "))")
                        InfoButton(articleID: "com.apple.developer.networking.networkextension")
                    }
                }

                if !r.entitlements.raw.isEmpty {
                    Divider().padding(.vertical, 4)
                    DisclosureGroup("All entitlement keys (\(r.entitlements.raw.count))") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(r.entitlements.raw.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(key).font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1).truncationMode(.middle)
                                    InfoButton(articleID: key)
                                    Spacer()
                                    Text(rawValueLabel(r.entitlements.raw[key]))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
            .padding(8)
        }
    }

    private func entRow(_ label: String, value: String, articleID: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(value).bold()
            InfoButton(articleID: articleID)
        }
    }

    private func rawValueLabel(_ v: PlistValue?) -> String {
        guard let v else { return "—" }
        switch v {
        case .string(let s): return "\"\(s)\""
        case .bool(let b):   return b ? "true" : "false"
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .array(let a):  return "[\(a.count)]"
        case .dict(let d):   return "{\(d.count)}"
        default:             return "—"
        }
    }

    private func urlSchemes(_ r: StaticReport) -> some View {
        Group {
            if r.urlSchemes.isEmpty { EmptyView() }
            else {
                GroupBox("URL schemes") {
                    VStack(alignment: .leading) {
                        ForEach(r.urlSchemes, id: \.schemes) { s in
                            HStack { Text(s.schemes.joined(separator: ", ")); Spacer(); Text(s.role ?? "").foregroundStyle(.secondary) }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private func docTypes(_ r: StaticReport) -> some View {
        Group {
            if r.documentTypes.isEmpty { EmptyView() }
            else {
                GroupBox("Document types") {
                    VStack(alignment: .leading) {
                        ForEach(r.documentTypes, id: \.contentTypes) { t in
                            VStack(alignment: .leading) {
                                Text(t.name ?? "—").bold()
                                Text(t.contentTypes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(8)
                }
            }
        }
    }

    private func helpers(_ r: StaticReport) -> some View {
        Group {
            if r.loginItems.isEmpty && r.xpcServices.isEmpty && r.helpers.isEmpty { EmptyView() }
            else {
                GroupBox(label: HStack {
                    Text("Embedded code")
                    Text("(\(r.xpcServices.count + r.loginItems.count + r.helpers.count) items, expand to analyze)")
                        .font(.caption).foregroundStyle(.secondary)
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(r.xpcServices, id: \.url) { EmbeddedBundleRow(bundle: $0, kind: "XPC service") }
                        ForEach(r.loginItems, id: \.url) { EmbeddedBundleRow(bundle: $0, kind: "Login item") }
                        ForEach(r.helpers, id: \.url) { EmbeddedBundleRow(bundle: $0, kind: "Helper") }
                    }.padding(8)
                }
            }
        }
    }

    private func domains(_ r: StaticReport) -> some View {
        Group {
            if r.hardcodedDomains.isEmpty { EmptyView() }
            else {
                GroupBox(label: HStack { Text("Hard-coded domains"); FidelityBadge(.staticAnalysis) }) {
                    Text(r.hardcodedDomains.joined(separator: "\n")).font(.callout.monospaced()).padding(8)
                }
            }
        }
    }

    private func paths(_ r: StaticReport) -> some View {
        Group {
            if r.hardcodedPaths.isEmpty { EmptyView() }
            else {
                GroupBox(label: HStack { Text("Hard-coded paths"); FidelityBadge(.staticAnalysis) }) {
                    Text(r.hardcodedPaths.joined(separator: "\n")).font(.callout.monospaced()).padding(8)
                }
            }
        }
    }

    private func updateSection(report: StaticReport,
                               mechanism: UpdateMechanism) -> some View {
        GroupBox(label: HStack {
            Text("Update mechanism")
            InfoButton(articleID: "update-preview")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: mechanismIcon(mechanism.kind))
                        .foregroundStyle(mechanismColor(mechanism.kind)).font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(mechanism.kind.label).font(.headline)
                            InfoButton(articleID: mechanismKBArticle(mechanism.kind))
                        }
                        if let url = mechanism.feedURL {
                            Text(url.absoluteString)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        } else if !mechanism.kind.supportsPreview {
                            Text(noPreviewSubtitle(for: mechanism.kind))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if mechanism.kind.supportsPreview, mechanism.feedURL != nil {
                        Button {
                            previewingUpdates = true
                        } label: {
                            Label("Preview next version", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if !mechanism.detectionEvidence.isEmpty {
                    DisclosureGroup("Why we think this app uses \(mechanism.kind.label)") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(mechanism.detectionEvidence, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.secondary).font(.caption)
                                    Text(line).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(8)
        }
        .sheet(isPresented: $previewingUpdates) {
            if let feed = mechanism.feedURL, mechanism.kind.supportsPreview {
                UpdateComparisonSheet(
                    fetcher: UpdateFetcher(feedURL: feed,
                                           currentBundle: report.bundle),
                    currentReport: report,
                    onClose: { previewingUpdates = false }
                )
            }
        }
    }

    private func mechanismIcon(_ kind: UpdateMechanism.Kind) -> String {
        switch kind {
        case .sparkle:          return "arrow.triangle.2.circlepath"
        case .squirrel:         return "ant.fill"
        case .electronUpdater:  return "atom"
        case .devMate:          return "clock.badge.exclamationmark"
        case .appStore:         return "bag"
        case .customInferred:   return "questionmark.diamond"
        case .unknown:          return "questionmark.circle"
        }
    }

    private func mechanismColor(_ kind: UpdateMechanism.Kind) -> Color {
        switch kind {
        case .sparkle:          return .blue
        case .squirrel:         return .blue
        case .electronUpdater:  return .blue
        case .devMate:          return .orange
        case .appStore:         return .green
        case .customInferred:   return .purple
        case .unknown:          return .secondary
        }
    }

    private func mechanismKBArticle(_ kind: UpdateMechanism.Kind) -> String {
        switch kind {
        case .sparkle:          return "sparkle"
        case .squirrel:         return "squirrel-mac"
        case .electronUpdater:  return "electron-updater"
        case .devMate:          return "devmate"
        case .appStore:         return "mac-app-store-updates"
        case .customInferred:   return "custom-inferred"
        case .unknown:          return "update-preview"
        }
    }

    private func noPreviewSubtitle(for kind: UpdateMechanism.Kind) -> String {
        switch kind {
        case .squirrel:
            return "Squirrel sets its feed URL programmatically — preview download is unavailable."
        case .electronUpdater:
            return "electron-updater isn't a Sparkle XML feed — preview download is unavailable."
        case .devMate:
            return "DevMate's update service is shut down — these apps are unlikely to update."
        case .appStore:
            return "App Store updates are managed by macOS, not by the app."
        case .customInferred:
            return "Detected from heuristics — auditor can't safely fetch this update."
        default:
            return ""
        }
    }

    private func grid(_ pairs: (String, String)...) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    Text(pair.0).foregroundStyle(.secondary)
                    Text(pair.1)
                }
            }
        }
    }
}
