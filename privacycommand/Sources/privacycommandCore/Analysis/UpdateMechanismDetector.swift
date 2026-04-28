import Foundation

// MARK: - Public types

public struct UpdateMechanism: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case sparkle
        case squirrel              // GitHub's Squirrel.Mac (used directly)
        case electronUpdater       // electron-updater (Slack, VS Code, Discord…)
        case devMate               // legacy DevMate-managed Sparkle
        case appStore
        case customInferred        // generic — matched on binary strings / helper names
        case unknown

        public var label: String {
            switch self {
            case .sparkle:          return "Sparkle"
            case .squirrel:         return "Squirrel.Mac"
            case .electronUpdater:  return "electron-updater"
            case .devMate:          return "DevMate (legacy)"
            case .appStore:         return "Mac App Store"
            case .customInferred:   return "Custom (inferred)"
            case .unknown:          return "Unknown"
            }
        }

        /// Whether the auditor can offer a "Preview next version" download
        /// for this mechanism. Currently Sparkle (with a feed URL) only —
        /// other mechanisms have unstable or non-XML feeds.
        public var supportsPreview: Bool {
            self == .sparkle
        }
    }

    public let kind: Kind
    /// URL of the appcast/feed if discoverable, nil otherwise.
    public let feedURL: URL?
    public let signatureKeyType: String?
    public let detectionEvidence: [String]

    public init(kind: Kind, feedURL: URL? = nil,
                signatureKeyType: String? = nil,
                detectionEvidence: [String] = []) {
        self.kind = kind
        self.feedURL = feedURL
        self.signatureKeyType = signatureKeyType
        self.detectionEvidence = detectionEvidence
    }
}

// MARK: - Detector

public enum UpdateMechanismDetector {

    /// Detect a self-update mechanism. Returns the strongest signal first;
    /// caller gets a single mechanism even if multiple weak signals exist.
    /// The optional `scan` is used by the heuristic detector to avoid
    /// re-reading the executable.
    public static func detect(
        in bundle: AppBundle,
        plist: [String: Any],
        scan: BinaryStringScanner.Result? = nil
    ) -> UpdateMechanism? {
        // Order matters: more-specific frameworks before heuristic fallback.
        if let m = detectSparkle(in: bundle, plist: plist) { return m }
        if let m = detectSquirrel(in: bundle, plist: plist) { return m }
        if let m = detectElectronUpdater(in: bundle) { return m }
        if let m = detectDevMate(in: bundle, plist: plist) { return m }
        if let m = detectAppStore(in: bundle) { return m }
        if let m = detectCustomInferred(in: bundle, scan: scan) { return m }
        return nil
    }

    // MARK: - Sparkle

    private static func detectSparkle(in bundle: AppBundle, plist: [String: Any]) -> UpdateMechanism? {
        let frameworksDir = bundle.url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let sparkleFW = frameworksDir.appendingPathComponent("Sparkle.framework")
        let hasSparkleFW = FileManager.default.fileExists(atPath: sparkleFW.path)

        let feedURLString = plist["SUFeedURL"] as? String
        let feedURL = feedURLString.flatMap { URL(string: $0) }

        let hasEDKey  = (plist["SUPublicEDKey"] as? String)?.isEmpty == false
        let hasDSAKey = (plist["SUPublicDSAKeyFile"] as? String)?.isEmpty == false

        guard hasSparkleFW || feedURL != nil || hasEDKey || hasDSAKey else { return nil }

        var evidence: [String] = []
        if hasSparkleFW {
            evidence.append("Sparkle.framework present at Contents/Frameworks/Sparkle.framework")
        }
        if let s = feedURLString, !s.isEmpty { evidence.append("SUFeedURL = \(s)") }
        if hasEDKey  { evidence.append("SUPublicEDKey present (EdDSA-signed appcast)") }
        if hasDSAKey { evidence.append("SUPublicDSAKeyFile present (legacy DSA)") }

        return UpdateMechanism(
            kind: .sparkle,
            feedURL: feedURL,
            signatureKeyType: hasEDKey ? "EdDSA" : (hasDSAKey ? "DSA" : nil),
            detectionEvidence: evidence
        )
    }

    // MARK: - Squirrel.Mac

    private static func detectSquirrel(in bundle: AppBundle, plist: [String: Any]) -> UpdateMechanism? {
        let frameworksDir = bundle.url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let squirrelFW = frameworksDir.appendingPathComponent("Squirrel.framework")
        guard FileManager.default.fileExists(atPath: squirrelFW.path) else { return nil }

        var evidence = ["Squirrel.framework present at Contents/Frameworks/"]
        if let feedURLString = plist["SUFeedURL"] as? String, !feedURLString.isEmpty {
            evidence.append("SUFeedURL = \(feedURLString) (Squirrel can borrow Sparkle's key)")
            return UpdateMechanism(
                kind: .squirrel,
                feedURL: URL(string: feedURLString),
                detectionEvidence: evidence
            )
        }
        evidence.append("Feed URL is set programmatically — preview not available.")
        return UpdateMechanism(kind: .squirrel, feedURL: nil, detectionEvidence: evidence)
    }

    // MARK: - electron-updater

    private static func detectElectronUpdater(in bundle: AppBundle) -> UpdateMechanism? {
        // electron-builder writes Contents/Resources/app-update.yml at build time.
        let appUpdateYML = bundle.url
            .appendingPathComponent("Contents/Resources/app-update.yml")
        guard FileManager.default.fileExists(atPath: appUpdateYML.path) else { return nil }

        var evidence = ["Contents/Resources/app-update.yml present (electron-builder)"]
        var feedURL: URL? = nil
        if let yml = try? String(contentsOf: appUpdateYML),
           let parsed = parseElectronUpdateYML(yml) {
            evidence.append(contentsOf: parsed.evidence)
            feedURL = parsed.feedURL
        }
        return UpdateMechanism(
            kind: .electronUpdater,
            feedURL: feedURL,
            detectionEvidence: evidence
        )
    }

    /// Tiny YAML extractor for the few keys electron-builder writes. We don't
    /// pull in a real YAML lib because the file's grammar is constrained and
    /// failing to parse is non-fatal.
    private static func parseElectronUpdateYML(_ yaml: String) -> (feedURL: URL?, evidence: [String])? {
        var url: URL? = nil
        var owner: String? = nil
        var repo: String? = nil
        var provider: String? = nil
        var evidence: [String] = []

        for raw in yaml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "url":      if let u = URL(string: val), u.scheme != nil { url = u }
            case "owner":    owner = val
            case "repo":     repo = val
            case "provider": provider = val
            default: break
            }
        }

        if let provider, !provider.isEmpty { evidence.append("provider: \(provider)") }
        if let url {
            evidence.append("update URL: \(url.absoluteString)")
            return (url, evidence)
        }
        if let owner, let repo, let github = URL(string: "https://github.com/\(owner)/\(repo)/releases") {
            evidence.append("GitHub releases: \(owner)/\(repo)")
            return (github, evidence)
        }
        return evidence.isEmpty ? nil : (nil, evidence)
    }

    // MARK: - DevMate

    private static func detectDevMate(in bundle: AppBundle, plist: [String: Any]) -> UpdateMechanism? {
        // DevMate apps usually had Contents/Frameworks/DevMateKit.framework
        // and an SUFeedURL pointing at devmate.com.
        let dmKit = bundle.url.appendingPathComponent("Contents/Frameworks/DevMateKit.framework")
        let hasFW = FileManager.default.fileExists(atPath: dmKit.path)
        let feedURLString = plist["SUFeedURL"] as? String
        let feedHost = URL(string: feedURLString ?? "")?.host?.lowercased() ?? ""
        let isDevMateFeed = feedHost.contains("devmate.com")

        guard hasFW || isDevMateFeed else { return nil }
        var evidence: [String] = []
        if hasFW { evidence.append("DevMateKit.framework present at Contents/Frameworks/") }
        if let s = feedURLString, isDevMateFeed { evidence.append("SUFeedURL = \(s)") }
        evidence.append("DevMate's update service shut down in 2018 — this app may not auto-update anymore.")
        return UpdateMechanism(
            kind: .devMate,
            feedURL: feedURLString.flatMap { URL(string: $0) },
            detectionEvidence: evidence
        )
    }

    // MARK: - Mac App Store

    private static func detectAppStore(in bundle: AppBundle) -> UpdateMechanism? {
        let receiptURL = bundle.url
            .appendingPathComponent("Contents/_MASReceipt/receipt")
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        return UpdateMechanism(
            kind: .appStore,
            feedURL: nil,
            detectionEvidence: ["Contents/_MASReceipt/receipt present — distributed via the Mac App Store."]
        )
    }

    // MARK: - Custom inferred

    /// Heuristic catch-all for apps that ship their own update logic without
    /// a known framework (e.g. WhyFi). Looks for "Updater"-named helpers and
    /// URLs in the binary that look like update endpoints.
    ///
    /// Always lower confidence than the framework-specific detectors above.
    /// Surfaces detected hints in the evidence list so users can judge.
    private static func detectCustomInferred(
        in bundle: AppBundle,
        scan: BinaryStringScanner.Result?
    ) -> UpdateMechanism? {
        var evidence: [String] = []

        // Helper / login-item names that smell like updaters.
        let candidates = [
            bundle.url.appendingPathComponent("Contents/Helpers"),
            bundle.url.appendingPathComponent("Contents/Library/LoginItems"),
            bundle.url.appendingPathComponent("Contents/Library/AutoUpdate"),
            bundle.url.appendingPathComponent("Contents/Frameworks")
        ]
        let updateNamePatterns = ["update", "autoupdate", "updater"]
        for dir in candidates {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for entry in contents {
                let lower = entry.lastPathComponent.lowercased()
                if updateNamePatterns.contains(where: { lower.contains($0) }) {
                    evidence.append("Update-named entry: \(entry.lastPathComponent) under \(dir.lastPathComponent)/")
                }
            }
        }

        // URLs that look like update endpoints.
        let urls = scan?.urls ?? BinaryStringScanner.scan(executable: bundle.executableURL).urls
        let updateURLPatterns = [
            "appcast", "update", "/latest", "/version", "/releases",
            "version.json", "version.xml", "update.json", "update.xml"
        ]
        let suspicious = urls.compactMap { url -> String? in
            let lower = url.lowercased()
            return updateURLPatterns.contains(where: { lower.contains($0) }) ? url : nil
        }
        for url in suspicious.prefix(6) {
            evidence.append("URL in binary: \(url)")
        }

        // Don't fire if we found nothing — we'd rather show nothing than
        // misleading "Custom (inferred)" panels for apps that don't auto-update.
        guard !evidence.isEmpty else { return nil }

        // Pick the most plausible URL as a hint. We won't actually fetch it
        // for preview (only Sparkle is supported there), but surface it in
        // the section so users know what URL the auditor is reading as
        // "update endpoint".
        let probableFeedURL = suspicious
            .first { $0.lowercased().contains("appcast") } // appcasts are canonical
            ?? suspicious.first
        let feedURL = probableFeedURL.flatMap { URL(string: $0) }

        return UpdateMechanism(
            kind: .customInferred,
            feedURL: feedURL,
            detectionEvidence: evidence
        )
    }
}
