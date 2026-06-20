import Foundation

/// Orchestrates the static analysis passes. Pure functions; the input is a URL
/// to a `.app` bundle, the output is a `StaticReport`. Designed to be cheap to
/// re-run.
public struct StaticAnalyzer {

    public let privacyDB: PrivacyKeyDatabase

    public init(privacyDB: PrivacyKeyDatabase = .builtin) {
        self.privacyDB = privacyDB
    }

    public func analyze(bundleAt url: URL) throws -> StaticReport {
        let bundle = try AppBundle.resolve(bundleURL: url)
        return analyze(bundle: bundle)
    }

    public func analyze(bundle: AppBundle) -> StaticReport {
        let plistResult = InfoPlistReader.read(for: bundle, db: privacyDB)
        let entitlements = EntitlementsReader.read(for: bundle)
        let signing = CodesignWrapper.info(for: bundle)
        let notarization = CodesignWrapper.notarization(for: bundle)
        let framework = FrameworkScanner.scan(bundle: bundle)
        let scan = BinaryStringScanner.scan(
            executable: bundle.executableURL,
            symbols: BinaryStringScanner.defaultPrivacySymbols + AntiAnalysisDetector.scanSymbols)
        let provenance = ProvenanceReader.read(for: bundle)
        let updateMechanism = UpdateMechanismDetector.detect(
            in: bundle, plist: plistResult.raw, scan: scan)

        // New forensic passes — none are in the hot path; each uses bytes
        // already on disk or shelling to `codesign` (which is fast).
        // Scan the main executable plus every embedded Mach-O (frameworks,
        // helpers, XPC services, login items) for hard-coded secrets, so one
        // buried in a vendored binary is found and attributed to the file it
        // lives in rather than silently missed. Each finding's sourceFile is a
        // path relative to the .app ("Contents/MacOS/AppName"). The main
        // executable goes first so it wins attribution when the same secret
        // appears in more than one file.
        let bundleRoot = bundle.url.path
        func bundleRelative(_ url: URL) -> String {
            let p = url.standardizedFileURL.path
            return p.hasPrefix(bundleRoot + "/")
                ? String(p.dropFirst(bundleRoot.count + 1))
                : url.lastPathComponent
        }
        let mainExec = bundle.executableURL.standardizedFileURL
        let embeddedMachOs = BundleSigningAuditor.enumerateExecutables(in: bundle.url)
            .filter { $0.standardizedFileURL != mainExec }
        let secretFiles = ([mainExec] + embeddedMachOs)
            .map { (url: $0, label: bundleRelative($0)) }
        let secrets = SecretsScanner.scan(files: secretFiles).findings
        let bundleSigning = BundleSigningAuditor.audit(bundle: bundle)
        // MAS receipt drives the anti-analysis encrypted-segment gate (FairPlay
        // is expected for App Store apps); AppStoreInfo below reuses it.
        let masReceipt = MASReceiptDetector.detect(for: bundle)
        let antiAnalysis = AntiAnalysisDetector.analyse(
            executable: bundle.executableURL, scan: scan, isMASApp: masReceipt.isMASApp).findings
        let rpathAudit = RPathAuditor.audit(executable: bundle.executableURL)
        let embeddedAssets = EmbeddedAssetScanner.scan(bundle: bundle)
        let privacyManifest = PrivacyManifestReader.read(for: bundle)
        let notarizationDeep = NotarizationDeepDive.analyse(bundle: bundle)
        let flagFindings = FlagsScanner.scan(executable: bundle.executableURL).findings

        // `masReceipt` is computed above (the anti-analysis MAS gate needs it).
        // The iTunes Lookup + privacy-label fetch are async and live in the
        // coordinator — they call back to update this struct in place.
        let appStoreInfo = AppStoreInfo(
            isMASApp: masReceipt.isMASApp,
            bundleID: masReceipt.bundleID
        )

        let inferred = inferCapabilities(
            entitlements: entitlements,
            declaredKeys: plistResult.declaredPrivacyKeys,
            scan: scan,
            frameworks: framework.frameworks
        )

        // Endpoints/strings from EVERY embedded Mach-O (frameworks, XPC
        // services, helpers, .appex extensions) — not just the main executable.
        // An SDK's network domains usually live in its embedded framework
        // binary, so the main-exec-only scan missed them entirely. Capability
        // inference deliberately still keys on the main executable's symbols.
        let embeddedScan = BinaryStringScanner.scan(executables: embeddedMachOs)
        // Endpoints also live in bundled config/resource files (Settings
        // bundles, config.json, SDK plists), which the binary scan never reads.
        let resourceScan = EmbeddedResourceScanner.scan(bundle: bundle)
        let domains = scan.domains.union(embeddedScan.domains).union(resourceScan.domains).sorted()
        let urls = scan.urls.union(embeddedScan.urls).union(resourceScan.urls).sorted()
        let paths = scan.paths.union(embeddedScan.paths).sorted()

        // Persist the network call-site map so it's diffable across updates.
        // Size-capped + disassembler-gated so large apps aren't slowed.
        let netCallSites = StaticAnalyzer.networkCallSites(for: bundle.executableURL)

        var warnings: [Finding] = []
        // iPhone/iPad apps run on Apple Silicon from a wrapped, flat bundle.
        // Flag that up front so the reader knows why some macOS-only checks
        // (Hardened Runtime, notarization stapling) are intentionally skipped.
        if bundle.platform == .iOS {
            warnings.append(Finding(
                severity: .info,
                message: "iPhone/iPad app running on macOS.",
                evidence: ["Analyzed the wrapped iOS bundle (flat layout).",
                           "macOS-only checks like Hardened Runtime and notarization stapling don't apply to iOS apps."],
                kbArticleID: "ios-app-on-mac"
            ))
        }
        if let note = netCallSites.note {
            warnings.append(Finding(
                severity: .info,
                message: note,
                evidence: ["The on-demand Forensic disassembly summary can still analyse it."],
                kbArticleID: "asm-network-call-sites"))
        }
        for k in plistResult.declaredPrivacyKeys where k.isEmpty {
            warnings.append(Finding(
                severity: .warn,
                message: "Empty purpose string for \(k.rawKey).",
                evidence: ["Info.plist key \(k.rawKey) is set but blank."],
                kbArticleID: "privacy-key-empty"
            ))
        }
        if !signing.validates {
            warnings.append(Finding(
                severity: .error,
                message: "Code signature does not validate.",
                evidence: [signing.validationError ?? "(no detail)"],
                kbArticleID: "code-signing"
            ))
        }
        if !signing.hardenedRuntime && !signing.isPlatformBinary && bundle.platform == .macOS {
            warnings.append(Finding(
                severity: .warn,
                message: "Hardened Runtime is OFF.",
                evidence: ["A modern third-party app should ship with the Hardened Runtime enabled."],
                kbArticleID: "hardened-runtime"
            ))
        }
        if entitlements.disablesLibraryValidation && !signing.isPlatformBinary {
            warnings.append(Finding(
                severity: .info,
                message: "Library validation is disabled.",
                evidence: ["com.apple.security.cs.disable-library-validation = YES",
                           "Common in Electron apps; widens the attack surface for plug-ins."],
                kbArticleID: "library-validation"
            ))
        }
        if let appleEvts = entitlements.appleEvents {
            switch appleEvts {
            case .anyApp:
                warnings.append(Finding(
                    severity: .warn,
                    message: "Apple Events automation enabled for any application.",
                    evidence: ["com.apple.security.automation.apple-events = YES"],
                    kbArticleID: "automation"
                ))
            case .bundleIDs(let ids):
                warnings.append(Finding(
                    severity: .info,
                    message: "Apple Events automation declared for: \(ids.joined(separator: ", "))",
                    evidence: ["com.apple.security.temporary-exception.apple-events"],
                    kbArticleID: "automation"
                ))
            }
        }

        // High-trust / sandbox-escape entitlements. (Skip Apple's own binaries,
        // which legitimately hold many of these.)
        if !signing.isPlatformBinary {
            for ne in EntitlementsReader.notableEntitlements(in: entitlements.raw) {
                warnings.append(Finding(
                    severity: ne.severity == .high ? .warn : .info,
                    message: ne.title,
                    evidence: [ne.key, ne.detail],
                    kbArticleID: "entitlement-notable"))
            }
        }

        // Surface ATS-derived findings so the risk scorer + UI pick them up.
        if let ats = plistResult.atsConfig {
            if ats.allowsArbitraryLoads {
                warnings.append(Finding(
                    severity: .warn,
                    message: "App Transport Security: arbitrary loads allowed.",
                    evidence: ["NSAppTransportSecurity → NSAllowsArbitraryLoads = YES",
                               "App can connect over plain HTTP to any domain."],
                    kbArticleID: "ats-arbitrary-loads"
                ))
            }
            if !ats.exceptionDomains.isEmpty {
                let perDomain = ats.exceptionDomains.filter { $0.allowsInsecureHTTPLoads || $0.allowsArbitraryLoads }
                if !perDomain.isEmpty {
                    warnings.append(Finding(
                        severity: .info,
                        message: "ATS exceptions: \(perDomain.count) domain(s) permit insecure connections.",
                        evidence: perDomain.map { "\($0.domain): " +
                            ($0.allowsInsecureHTTPLoads ? "allows insecure HTTP" : "arbitrary loads") +
                            ($0.includesSubdomains ? " (incl. subdomains)" : "") },
                        kbArticleID: "ats-exception-domains"
                    ))
                }
            }
        }

        // Build a draft report first (without sdkHits) so the SDK detector
        // can read the same structured fields the rest of the UI does.
        // We then run the detector and assemble the final report.
        let draft = StaticReport(
            bundle: bundle,
            declaredPrivacyKeys: plistResult.declaredPrivacyKeys,
            entitlements: entitlements,
            codeSigning: signing,
            notarization: notarization,
            urlSchemes: plistResult.urlSchemes,
            documentTypes: plistResult.documentTypes,
            loginItems: framework.loginItems,
            xpcServices: framework.xpcServices,
            helpers: framework.helpers,
            frameworks: framework.frameworks,
            inferredCapabilities: inferred,
            hardcodedURLs: urls,
            hardcodedDomains: domains,
            hardcodedPaths: paths,
            warnings: warnings,
            atsConfig: plistResult.atsConfig,
            provenance: provenance,
            updateMechanism: updateMechanism
        )

        let sdkHits = SDKFingerprintDetector.detect(
            in: draft, extraSymbols: scan.foundFrameworkSymbols)

        // Telemetry / advertising / attribution count is high-signal — surface
        // it as a finding so it propagates into the risk score and the report
        // exporters without UI-only code needing to know about SDKs.
        var enrichedWarnings = warnings
        let trackerCount = sdkHits.filter(\.isTrackerLike).count
        if trackerCount >= 1 {
            let names = sdkHits.filter(\.isTrackerLike).map(\.fingerprint.displayName)
            enrichedWarnings.append(Finding(
                severity: trackerCount >= 5 ? .warn : .info,
                message: "Contains \(trackerCount) tracker-class SDK\(trackerCount == 1 ? "" : "s").",
                evidence: names,
                kbArticleID: "sdk-trackers"
            ))
        }

        // Secrets — high signal, single-finding callout regardless of count.
        if !secrets.isEmpty {
            let fileCount = Set(secrets.compactMap(\.sourceFile)).count
            let scope = fileCount > 1 ? " across \(fileCount) binaries" : " in the binary"
            enrichedWarnings.append(Finding(
                severity: .error,
                message: "Found \(secrets.count) hard-coded credential\(secrets.count == 1 ? "" : "s")\(scope).",
                evidence: secrets.map { s in
                    var line = "\(s.kind.rawValue): \(s.masked)"
                    if let src = s.sourceFile {
                        line += " — \(src)"
                        if let off = s.byteOffset { line += " @ 0x\(String(off, radix: 16))" }
                    }
                    return line
                },
                kbArticleID: "secret-findings"
            ))
        }

        // Bundle-signing verdicts — promote each Verdict into a Finding.
        for v in bundleSigning.verdicts where v.severity != .info {
            let mapped: Finding.Severity = v.severity == .error ? .error : .warn
            enrichedWarnings.append(Finding(
                severity: mapped, message: v.summary,
                evidence: v.detail.map { [$0] } ?? [],
                kbArticleID: "bundle-signing-audit"))
        }

        // Anti-analysis findings — info / warn depending on confidence.
        for a in antiAnalysis where a.confidence != .low {
            enrichedWarnings.append(Finding(
                severity: a.confidence == .high ? .warn : .info,
                message: a.summary,
                evidence: a.detail.map { [$0] } ?? [],
                kbArticleID: a.kbArticleID))
        }

        // Hijackable rpaths — warn each, with the resolved path.
        for entry in rpathAudit.entries where entry.kind == .hijackable {
            enrichedWarnings.append(Finding(
                severity: .warn,
                message: "User-writable rpath: \(entry.raw)",
                evidence: ["Resolved: \(entry.resolvedPath ?? "?")",
                           "An attacker writing a dylib here could be loaded ahead of the legitimate one."],
                kbArticleID: "rpath-hijacking"))
        }

        // Embedded launch agents/daemons — info-level callouts so the user
        // sees what services the bundle is poised to install.
        for lp in embeddedAssets.launchPlists where lp.kind == .daemon || lp.kind == .agent {
            enrichedWarnings.append(Finding(
                severity: .info,
                message: "Embedded \(lp.kind.rawValue.lowercased()): \(lp.label)",
                evidence: ["Path: \(lp.url.path)",
                           "Command: \(lp.commandSummary)"],
                kbArticleID: "embedded-launch-plist"))
        }

        // Privacy-manifest cross-check.
        if let manifest = privacyManifest {
            let xc = PrivacyManifestReader.crossCheck(manifest: manifest, scan: scan)
            if !xc.declaredButUnused.isEmpty {
                enrichedWarnings.append(Finding(
                    severity: .info,
                    message: "Privacy manifest declares \(xc.declaredButUnused.count) required-reason API categor\(xc.declaredButUnused.count == 1 ? "y" : "ies") not seen in the binary.",
                    evidence: xc.declaredButUnused.map(\.rawValue),
                    kbArticleID: "privacy-manifest"))
            }
            if !xc.usedButUndeclared.isEmpty {
                enrichedWarnings.append(Finding(
                    severity: .warn,
                    message: "Binary references required-reason APIs not declared in the privacy manifest.",
                    evidence: xc.usedButUndeclared.map { "\($0.category.rawValue): \($0.evidence.joined(separator: ", "))" },
                    kbArticleID: "privacy-manifest"))
            }

            // Tracking consistency: the manifest's stated tracking vs what the
            // binary actually embeds (tracker SDKs) and contacts (tracker domains).
            let trackerSDKs = sdkHits.filter { $0.isTrackerLike }.map { $0.fingerprint.displayName }
            let domainClassifier = DomainClassifier()
            let observedTrackerDomains = domains.filter {
                switch domainClassifier.classify($0).category {
                case .adTech, .analytics, .telemetry: return true
                default: return false
                }
            }
            let tx = PrivacyManifestReader.trackingCrossCheck(
                manifest: manifest, trackerSDKNames: trackerSDKs, observedTrackerDomains: observedTrackerDomains)
            if !tx.trackerSDKsButTrackingNotDeclared.isEmpty {
                enrichedWarnings.append(Finding(
                    severity: .warn,
                    message: "Privacy manifest declares no tracking, but the app embeds tracking SDK(s).",
                    evidence: tx.trackerSDKsButTrackingNotDeclared,
                    kbArticleID: "privacy-manifest"))
            }
            if !tx.undeclaredTrackingDomains.isEmpty {
                enrichedWarnings.append(Finding(
                    severity: .info,
                    message: "\(tx.undeclaredTrackingDomains.count) tracker domain(s) contacted but not listed in NSPrivacyTrackingDomains.",
                    evidence: Array(tx.undeclaredTrackingDomains.prefix(12)),
                    kbArticleID: "privacy-manifest"))
            }
        } else if signing.teamIdentifier != nil && !signing.isPlatformBinary {
            // Apple-platform binaries don't ship a manifest. Third-party
            // notarized apps generally should.
            enrichedWarnings.append(Finding(
                severity: .info,
                message: "No PrivacyInfo.xcprivacy manifest shipped.",
                evidence: ["Apple's privacy manifest is required for App Store distribution since May 2024.",
                           "Outside the App Store it's optional but well-behaved apps still ship one."],
                kbArticleID: "privacy-manifest"))
        }

        // Stapled-ticket regression — surfaces apps that were notarized
        // but whose ticket isn't stapled (so Gatekeeper has to phone home
        // to verify, and offline-first installs may break).
        if notarizationDeep.staplerOutput.verdict == .noTicket
            && !signing.isPlatformBinary
            && !signing.isAdhocSigned
            && bundle.platform == .macOS {
            enrichedWarnings.append(Finding(
                severity: .info,
                message: "Notarization ticket is not stapled to the bundle.",
                evidence: ["xcrun stapler validate reports no embedded ticket.",
                           "Gatekeeper must contact Apple to verify; offline launches may fail."],
                kbArticleID: "notarization-deep-dive"))
        }

        return StaticReport(
            bundle: draft.bundle,
            declaredPrivacyKeys: draft.declaredPrivacyKeys,
            entitlements: draft.entitlements,
            codeSigning: draft.codeSigning,
            notarization: draft.notarization,
            urlSchemes: draft.urlSchemes,
            documentTypes: draft.documentTypes,
            loginItems: draft.loginItems,
            xpcServices: draft.xpcServices,
            helpers: draft.helpers,
            frameworks: draft.frameworks,
            inferredCapabilities: draft.inferredCapabilities,
            hardcodedURLs: draft.hardcodedURLs,
            hardcodedDomains: draft.hardcodedDomains,
            hardcodedPaths: draft.hardcodedPaths,
            warnings: enrichedWarnings,
            atsConfig: draft.atsConfig,
            provenance: draft.provenance,
            updateMechanism: draft.updateMechanism,
            sdkHits: sdkHits,
            secrets: secrets,
            bundleSigning: bundleSigning,
            antiAnalysis: antiAnalysis,
            rpathAudit: rpathAudit,
            embeddedAssets: embeddedAssets,
            privacyManifest: privacyManifest,
            notarizationDeepDive: notarizationDeep,
            flagFindings: flagFindings,
            networkCallSites: netCallSites.sites,
            appStoreInfo: appStoreInfo
        )
    }

    // MARK: - Network call sites

    /// Above this size we skip disassembly during static analysis to keep the
    /// pass fast (the on-demand summary sheet has no such cap). 25 MB covers
    /// the vast majority of single-binary apps while excluding browser-class
    /// mega-frameworks.
    static let disassemblySizeCap = 25 * 1024 * 1024

    /// Disassemble the main executable (size-capped) and extract the network
    /// call-site map. Returns the sites plus an optional fidelity note when we
    /// deliberately skipped because the binary is too large.
    static func networkCallSites(for executable: URL)
        -> (sites: [DisassemblyAnalyzer.NetworkCallSite], note: String?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > disassemblySizeCap {
            return ([], "Network call-site map skipped: the executable is \(size / (1024 * 1024)) MB (cap \(disassemblySizeCap / (1024 * 1024)) MB).")
        }
        guard let text = DisassemblyAnalyzer.disassemble(executable: executable) else {
            return ([], nil)   // no disassembler installed — stay silent
        }
        return (DisassemblyAnalyzer.analyse(disassembly: text).networkCallSites, nil)
    }

    // MARK: - Inference

    func inferCapabilities(
        entitlements: Entitlements,
        declaredKeys: [PrivacyKey],
        scan: BinaryStringScanner.Result,
        frameworks: [FrameworkRef]
    ) -> [InferredCapability] {

        let declaredCategories = Set(declaredKeys.map(\.category))
        var hits: [PrivacyCategory: [String]] = [:]

        // Symbol-based evidence
        // NOTE: screen-recording (ScreenCaptureKit/CGDisplayStream) and
        // accessibility (AXIsProcessTrusted) were removed — there is no
        // matching PrivacyCategory, so they were mislabelled as
        // desktop-folder/automation. NWConnection was removed — it is generic
        // Network.framework usage, not a local-network signal. These need
        // their own categories (tracked as detection gaps), not a wrong label.
        let symbolMap: [(symbol: String, category: PrivacyCategory)] = [
            ("AVCaptureDevice",          .camera),
            ("AVCaptureSession",         .microphone),
            ("PHPhotoLibrary",           .photoLibrary),
            ("CNContactStore",           .contacts),
            ("EKEventStore",             .calendar),
            ("EKReminder",               .reminders),
            ("CLLocationManager",        .location),
            ("CBCentralManager",         .bluetoothAlways),
            ("OSAScript",                .appleEvents),
            ("NSAppleScript",            .appleEvents),
            ("HMHome",                   .homeKit),
            ("SFSpeechRecognizer",       .speechRecognition)
        ]
        for entry in symbolMap where scan.foundFrameworkSymbols.contains(entry.symbol) {
            hits[entry.category, default: []].append("Binary references \(entry.symbol)")
        }

        // Framework-link evidence — much stronger than mere symbol presence.
        for fw in frameworks {
            switch fw.bundleID {
            case "com.apple.AVFoundation":      hits[.camera, default: []].append("Links AVFoundation.framework")
            case "com.apple.coreimage":         break
            case "com.apple.Photos":            hits[.photoLibrary, default: []].append("Links Photos.framework")
            case "com.apple.Contacts":          hits[.contacts, default: []].append("Links Contacts.framework")
            case "com.apple.CoreLocation":      hits[.location, default: []].append("Links CoreLocation.framework")
            case "com.apple.CoreBluetooth":     hits[.bluetoothAlways, default: []].append("Links CoreBluetooth.framework")
            case "com.apple.EventKit":          hits[.calendar, default: []].append("Links EventKit.framework")
            default: break
            }
        }

        // `.bluetooth` (peripheral) and `.bluetoothAlways` share one
        // CoreBluetooth surface; a usage key of either justifies a CoreBluetooth
        // inference and vice-versa, so treat them as one for both checks.
        func declaredFor(_ cat: PrivacyCategory) -> Bool {
            if declaredCategories.contains(cat) { return true }
            if Self.isBluetooth(cat) && declaredCategories.contains(where: Self.isBluetooth) { return true }
            return categoryDeclaredViaEntitlement(cat, entitlements: entitlements)
        }
        func inferredFor(_ cat: PrivacyCategory) -> Bool {
            if hits[cat] != nil { return true }
            if Self.isBluetooth(cat) && hits.keys.contains(where: Self.isBluetooth) { return true }
            return false
        }

        var out: [InferredCapability] = []
        for (cat, evidence) in hits {
            // "Used but not declared" only means something for categories that
            // HAVE a static declaration channel (a usage key or entitlement).
            // Categories without one were the source of the permanent false
            // flags — surface them, never score them as undeclared.
            let undeclared = Self.declarableCategories.contains(cat) && !declaredFor(cat)
            out.append(InferredCapability(
                category: cat,
                confidence: evidence.count >= 2 ? .high : .medium,
                evidence: evidence,
                declaredButNotJustified: false,
                inferredButNotDeclared: undeclared
            ))
        }
        // Declared-but-not-justified: a declared usage key whose API we can
        // actually detect but found no trace of. Restricted to categories the
        // inference map COVERS — otherwise categories we simply can't see
        // (motion, tracking, …) would all look "unused".
        for k in declaredKeys where Self.coverableCategories.contains(k.category) {
            if !inferredFor(k.category) {
                out.append(InferredCapability(
                    category: k.category,
                    confidence: .low,
                    evidence: ["Declared via \(k.rawKey) but no matching framework or symbol found in the binary."],
                    declaredButNotJustified: true,
                    inferredButNotDeclared: false
                ))
            }
        }
        return out.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    // Categories with a real static declaration channel (Info.plist usage key
    // and/or entitlement) — only these can meaningfully be "used but not declared".
    static let declarableCategories: Set<PrivacyCategory> = [
        .camera, .microphone, .contacts, .calendar, .reminders, .photoLibrary,
        .photoLibraryAdd, .location, .bluetooth, .bluetoothAlways, .homeKit,
        .motion, .speechRecognition, .mediaLibrary, .appleEvents, .automation,
        .localNetwork, .userTrackingTransparency, .focusStatus, .faceID
    ]
    // Categories the inference map can actually detect — only these can be
    // "declared but not justified".
    static let coverableCategories: Set<PrivacyCategory> = [
        .camera, .microphone, .photoLibrary, .contacts, .calendar, .reminders,
        .location, .bluetooth, .bluetoothAlways, .appleEvents, .homeKit, .speechRecognition
    ]
    static func isBluetooth(_ c: PrivacyCategory) -> Bool { c == .bluetooth || c == .bluetoothAlways }

    private func categoryDeclaredViaEntitlement(_ cat: PrivacyCategory, entitlements: Entitlements) -> Bool {
        switch cat {
        case .appleEvents, .automation:
            return entitlements.appleEvents != nil
        case .localNetwork:
            return entitlements.networkClient || entitlements.networkServer
        default:
            return false
        }
    }
}
