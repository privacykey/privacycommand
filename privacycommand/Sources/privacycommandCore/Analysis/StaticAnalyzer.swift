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
        let scan = BinaryStringScanner.scan(executable: bundle.executableURL)
        let provenance = ProvenanceReader.read(for: bundle)
        let updateMechanism = UpdateMechanismDetector.detect(
            in: bundle, plist: plistResult.raw, scan: scan)

        // New forensic passes — none are in the hot path; each uses bytes
        // already on disk or shelling to `codesign` (which is fast).
        let secrets = SecretsScanner.scan(executable: bundle.executableURL).findings
        let bundleSigning = BundleSigningAuditor.audit(bundle: bundle)
        let antiAnalysis = AntiAnalysisDetector.analyse(
            executable: bundle.executableURL, scan: scan).findings
        let rpathAudit = RPathAuditor.audit(executable: bundle.executableURL)
        let embeddedAssets = EmbeddedAssetScanner.scan(bundle: bundle)
        let privacyManifest = PrivacyManifestReader.read(for: bundle)
        let notarizationDeep = NotarizationDeepDive.analyse(bundle: bundle)
        let flagFindings = FlagsScanner.scan(executable: bundle.executableURL).findings

        // Mac App Store detection runs in microseconds (one filesystem
        // attribute lookup) so it lives inline. The actual iTunes
        // Lookup + privacy-label fetch are async and live in the
        // coordinator — they call back to update this struct in place.
        let masReceipt = MASReceiptDetector.detect(bundleAt: bundle.url)
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

        let domains = scan.domains.sorted()
        let urls = scan.urls.sorted()
        let paths = scan.paths.sorted()

        var warnings: [Finding] = []
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
        if !signing.hardenedRuntime && !signing.isPlatformBinary {
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
            enrichedWarnings.append(Finding(
                severity: .error,
                message: "Found \(secrets.count) hard-coded credential\(secrets.count == 1 ? "" : "s") in the binary.",
                evidence: secrets.map { "\($0.kind.rawValue): \($0.masked)" },
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
            && !signing.isAdhocSigned {
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
            appStoreInfo: appStoreInfo
        )
    }

    // MARK: - Inference

    private func inferCapabilities(
        entitlements: Entitlements,
        declaredKeys: [PrivacyKey],
        scan: BinaryStringScanner.Result,
        frameworks: [FrameworkRef]
    ) -> [InferredCapability] {

        let declaredCategories = Set(declaredKeys.map(\.category))
        var hits: [PrivacyCategory: [String]] = [:]

        // Symbol-based evidence
        let symbolMap: [(symbol: String, category: PrivacyCategory)] = [
            ("AVCaptureDevice",          .camera),
            ("AVCaptureSession",         .microphone),
            ("ScreenCaptureKit",         .desktopFolder),    // bucket: screen recording -> map to surprising-folder cat for now
            ("CGDisplayStream",          .desktopFolder),
            ("PHPhotoLibrary",           .photoLibrary),
            ("CNContactStore",           .contacts),
            ("EKEventStore",             .calendar),
            ("EKReminder",               .reminders),
            ("CLLocationManager",        .location),
            ("CBCentralManager",         .bluetoothAlways),
            ("AXIsProcessTrusted",       .automation),
            ("OSAScript",                .appleEvents),
            ("NSAppleScript",            .appleEvents),
            ("HMHome",                   .homeKit),
            ("SFSpeechRecognizer",       .speechRecognition),
            ("NWConnection",             .localNetwork)
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
            case "com.apple.ScreenCaptureKit":  hits[.desktopFolder, default: []].append("Links ScreenCaptureKit.framework")
            default: break
            }
        }

        var out: [InferredCapability] = []
        for (cat, evidence) in hits {
            let declared = declaredCategories.contains(cat) || categoryDeclaredViaEntitlement(cat, entitlements: entitlements)
            out.append(InferredCapability(
                category: cat,
                confidence: evidence.count >= 2 ? .high : .medium,
                evidence: evidence,
                declaredButNotJustified: false,
                inferredButNotDeclared: !declared
            ))
        }
        // Declared-but-not-justified: privacy keys with no symbol/framework hit
        for k in declaredKeys {
            if hits[k.category] == nil {
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
