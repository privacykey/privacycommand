import Foundation

/// Builds a plain-English forensic summary of a Mach-O binary from
/// **structured facts that are always readable** — the import table, the
/// linked-library list, embedded strings, and the Mach-O header — rather than
/// from a full text disassembly.
///
/// Why not disassembly? Parsing `objdump`/`otool` text is fragile (the
/// annotation format changes between toolchain versions), slow (hundreds of
/// MB for a browser-class app), and impossible for encrypted App Store
/// binaries. The information a non-expert actually wants — *what is this
/// binary asking the OS to do?* — lives at two boundaries that are trivially
/// readable from `__LINKEDIT` and the load commands:
///
///   * **Imported symbols** — the undefined external symbols a binary
///     references are the libc / framework functions it calls (`_connect`,
///     `_dlopen`, `_SecItemCopyMatching`, `_CGEventTapCreate`, …).
///   * **Linked libraries** — `LC_LOAD_DYLIB` entries reveal the high-level
///     capability surface (Security, Network, AVFoundation, CoreLocation, …).
///     For modern framework-based apps this is the *dominant* signal: such an
///     app often imports zero raw socket calls yet clearly does networking
///     because it links `CFNetwork` / `Network.framework`.
///
/// The result feeds the same `SymbolDictionary` / `PatternDetector` the
/// disassembly path uses, so both speak the same language. Disassembly, when
/// available, is layered on top as *optional enrichment* (call counts,
/// per-function network sites) — never a prerequisite.
public enum BinaryCapabilityAnalyzer {

    // MARK: - Output

    public struct Report: Sendable, Hashable {
        public var architectures: [String]
        public var isEncrypted: Bool
        public var isStripped: Bool
        public var importedSymbolCount: Int
        public var linkedLibraryCount: Int
        /// Capabilities inferred from the linked-library list, deduplicated
        /// and ordered most-notable first.
        public var linkedCapabilities: [LinkedCapability]
        /// Imported symbols classified into the shared call dictionary,
        /// ranked. `callCount` is 1 here (presence) unless disassembly
        /// enrichment supplied real counts.
        public var importedCalls: [DisassemblyAnalyzer.ExternalCall]
        /// Pattern matches (stub launcher, keychain, shell, crypto, …)
        /// computed from the imports + strings.
        public var patterns: [DisassemblyAnalyzer.Pattern]
        /// Best-effort URL / domain literals pulled from the binary.
        public var urls: [String]
        public var domains: [String]
        /// One or more plain-English paragraphs ready for display.
        public var narrative: String

        public init(architectures: [String] = [],
                    isEncrypted: Bool = false,
                    isStripped: Bool = false,
                    importedSymbolCount: Int = 0,
                    linkedLibraryCount: Int = 0,
                    linkedCapabilities: [LinkedCapability] = [],
                    importedCalls: [DisassemblyAnalyzer.ExternalCall] = [],
                    patterns: [DisassemblyAnalyzer.Pattern] = [],
                    urls: [String] = [],
                    domains: [String] = [],
                    narrative: String = "") {
            self.architectures = architectures
            self.isEncrypted = isEncrypted
            self.isStripped = isStripped
            self.importedSymbolCount = importedSymbolCount
            self.linkedLibraryCount = linkedLibraryCount
            self.linkedCapabilities = linkedCapabilities
            self.importedCalls = importedCalls
            self.patterns = patterns
            self.urls = urls
            self.domains = domains
            self.narrative = narrative
        }
    }

    /// A capability inferred from a linked library, with the evidence
    /// (which dylibs triggered it) and a one-line plain-English meaning.
    public struct LinkedCapability: Sendable, Hashable, Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let category: DisassemblyAnalyzer.Category
        /// Whether this is a privacy-sensitive capability worth highlighting.
        public let privacySensitive: Bool
        /// Library basenames that triggered this capability.
        public let evidence: [String]
        public let kbArticleID: String?
    }

    // MARK: - Entry point

    /// Analyse a Mach-O executable. Pure structured parsing — no shell-out,
    /// no disassembly. Always returns a `Report`; for an unreadable file the
    /// report is mostly empty but the narrative explains why.
    public static func analyse(executable url: URL) -> Report {
        let archs = (try? MachOInspector.architectures(of: url)) ?? []
        let lc = MachOInspector.loadCommands(of: url)
        let imports = MachOInspector.importedSymbols(of: url)
        let scan = BinaryStringScanner.scan(executable: url)
        return analyse(architectures: archs,
                       loadCommands: lc,
                       importedSymbols: imports,
                       strings: scan)
    }

    /// Testable seam: build a report from already-extracted facts.
    public static func analyse(architectures: [String],
                               loadCommands: MachOInspector.LoadCommandsSummary,
                               importedSymbols: [String],
                               strings: BinaryStringScanner.Result) -> Report {

        // Classify the *full* import set for pattern detection (dlopen,
        // malloc-zone tricks, etc. must be visible even though they're a
        // tiny fraction of a Swift app's thousands of mangled witness
        // symbols).
        let allCalls = DisassemblyAnalyzer.classify(symbols: importedSymbols)
        // Pattern detection wants both symbols (as calls) and string literals.
        // Feed it the URLs/domains/paths we scanned plus the framework symbols
        // so string-driven patterns (DYLD_INSERT_LIBRARIES, CGEventTapCreate)
        // can fire.
        let literals = Array(strings.urls)
            + Array(strings.domains)
            + Array(strings.paths)
            + Array(strings.foundFrameworkSymbols)
        let patterns = DisassemblyAnalyzer.detectPatterns(calls: allCalls, literals: literals)

        // For display, drop the uncategorised bucket — for a Swift/ObjC app
        // that's thousands of mangled protocol-witness symbols that mean
        // nothing to a human. Keep everything we could actually name.
        let calls = allCalls.filter { $0.category != .other }

        var report = Report(
            architectures: architectures,
            isEncrypted: loadCommands.hasEncryptedSegment,
            isStripped: loadCommands.isStripped,
            importedSymbolCount: importedSymbols.count,
            linkedLibraryCount: loadCommands.dylibs.count,
            linkedCapabilities: linkedCapabilities(for: loadCommands.dylibs),
            importedCalls: calls,
            patterns: patterns,
            urls: Array(strings.urls).sorted(),
            domains: Array(strings.domains).sorted(),
            narrative: ""
        )
        report.narrative = NarrativeBuilder.build(report)
        return report
    }

    // MARK: - Linked-library → capability mapping

    /// Map a list of `LC_LOAD_DYLIB` paths to deduplicated capabilities.
    /// Matching is on the library's basename (the framework / dylib name),
    /// case-insensitively, so `/System/.../Security.framework/Versions/A/Security`
    /// matches the `Security` rule.
    static func linkedCapabilities(for dylibs: [String]) -> [LinkedCapability] {
        // basename (last path component) lower-cased → original for evidence
        var byCapability: [String: (rule: CapabilityRule, evidence: [String])] = [:]
        var order: [String] = []

        for path in dylibs {
            let base = (path as NSString).lastPathComponent
            guard let rule = rules[base.lowercased()] else { continue }
            if byCapability[rule.title] == nil { order.append(rule.title) }
            byCapability[rule.title, default: (rule, [])].evidence.append(base)
        }

        let built: [LinkedCapability] = order.compactMap { title in
            guard let entry = byCapability[title] else { return nil }
            return LinkedCapability(title: entry.rule.title,
                                    detail: entry.rule.detail,
                                    category: entry.rule.category,
                                    privacySensitive: entry.rule.privacySensitive,
                                    evidence: dedupePreservingOrder(entry.evidence),
                                    kbArticleID: entry.rule.kbArticleID)
        }
        // Privacy-sensitive first, then by category name for stability.
        return built.sorted {
            if $0.privacySensitive != $1.privacySensitive { return $0.privacySensitive }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    private struct CapabilityRule {
        let title: String
        let detail: String
        let category: DisassemblyAnalyzer.Category
        let privacySensitive: Bool
        let kbArticleID: String?
    }

    /// Keyed by lower-cased library basename. Multiple libraries can map to
    /// the same capability title (they then merge, accumulating evidence).
    private static let rules: [String: CapabilityRule] = {
        func r(_ title: String, _ detail: String, _ cat: DisassemblyAnalyzer.Category,
               privacy: Bool = false, kb: String? = nil) -> CapabilityRule {
            CapabilityRule(title: title, detail: detail, category: cat,
                           privacySensitive: privacy, kbArticleID: kb)
        }

        let networking = r("Networking",
            "Links networking frameworks — it can open outbound connections, make HTTP(S) requests, and resolve hostnames.",
            .networking)
        let crypto = r("Cryptography & keychain",
            "Links the Security framework — it can encrypt/decrypt data, evaluate TLS trust, and read or write the macOS keychain.",
            .crypto, kb: "asm-keychain")

        return [
            // Networking ------------------------------------------------------
            "cfnetwork": networking,
            "network": networking,
            "libnetwork.dylib": networking,
            "libnetworkextension.dylib": networking,
            "networkextension": networking,
            // Security / keychain / TLS --------------------------------------
            "security": crypto,
            "securityfoundation": crypto,
            "cryptotokenkit": crypto,
            "libssl.dylib": r("TLS (OpenSSL/BoringSSL)",
                "Links an OpenSSL-family TLS library — it manages its own encrypted connections rather than using the system networking stack.",
                .crypto),
            "libcrypto.dylib": r("Cryptography (libcrypto)",
                "Links libcrypto — low-level cryptographic primitives, usually paired with a bundled TLS stack.",
                .crypto),
            // Privacy-sensitive device access --------------------------------
            "avfoundation": r("Camera / microphone",
                "Links AVFoundation — it can capture from the camera and microphone.",
                .privacy, privacy: true, kb: "privacy-NSCameraUsageDescription"),
            "coremedia": r("Media processing",
                "Links CoreMedia — low-level audio/video codec and pipeline handling. Used for both playback and capture; playback alone has no privacy implications, so this is only sensitive when paired with the camera/microphone capability above.",
                .other, privacy: false),
            "corelocation": r("Location",
                "Links CoreLocation — it can read the device's location.",
                .privacy, privacy: true, kb: "privacy-NSLocationUsageDescription"),
            "contacts": r("Contacts",
                "Links the Contacts framework — it can read the user's address book.",
                .privacy, privacy: true, kb: "privacy-NSContactsUsageDescription"),
            "contactsui": r("Contacts",
                "Links ContactsUI — contact-picker UI, implies access to the address book.",
                .privacy, privacy: true, kb: "privacy-NSContactsUsageDescription"),
            "eventkit": r("Calendar & reminders",
                "Links EventKit — it can read and write calendar events and reminders.",
                .privacy, privacy: true, kb: "privacy-NSCalendarsUsageDescription"),
            "photos": r("Photo library",
                "Links the Photos framework — it can read the user's photo library.",
                .privacy, privacy: true, kb: "privacy-NSPhotoLibraryUsageDescription"),
            "photosui": r("Photo library",
                "Links PhotosUI — photo-picker UI, implies photo-library access.",
                .privacy, privacy: true, kb: "privacy-NSPhotoLibraryUsageDescription"),
            "corebluetooth": r("Bluetooth",
                "Links CoreBluetooth — it can scan for and connect to Bluetooth devices.",
                .privacy, privacy: true),
            "screencapturekit": r("Screen recording",
                "Links ScreenCaptureKit — it can record the screen and audio.",
                .privacy, privacy: true, kb: "privacy-NSScreenCaptureUsageDescription"),
            "speech": r("Speech recognition",
                "Links the Speech framework — it can transcribe audio to text.",
                .privacy, privacy: true),
            "homekit": r("HomeKit",
                "Links HomeKit — it can control home-automation accessories.",
                .privacy, privacy: true),
            "mediaplayer": r("Media library / now-playing",
                "Links MediaPlayer — exposes now-playing info and remote-control events; can also read the music library. Common in benign media-control and menu-bar utilities, so not treated as high-sensitivity on its own.",
                .other, privacy: false),
            // Automation / input ---------------------------------------------
            "carbon": r("Legacy Carbon",
                "Links Carbon — a legacy compatibility framework. Usually pulled in for menus or window plumbing in older apps; occasionally for global hotkeys / system-event taps, which only matter in an input-monitoring context.",
                .other, privacy: false),
            // IPC / system services ------------------------------------------
            "xpc": r("XPC services",
                "Links libxpc — it talks to other processes / system daemons over XPC.",
                .ipc),
            "endpointsecurity": r("Endpoint Security",
                "Links the Endpoint Security framework — it observes system-wide process, file, and network events (a high-privilege monitoring capability).",
                .privacy, privacy: true, kb: "com.apple.developer.endpoint-security.client"),
            "systemextensions": r("System / network extensions",
                "Links SystemExtensions — it can install kernel-adjacent extensions (network filters, endpoint-security agents).",
                .privacy, privacy: true),
            // Scripting --------------------------------------------------------
            "osakit": r("AppleScript / automation",
                "Links OSAKit — it can compile and run AppleScript / JXA, i.e. automate other apps.",
                .shell),
        ]
    }()

    private static func dedupePreservingOrder(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }

    // MARK: - Narrative

    enum NarrativeBuilder {
        static func build(_ r: Report) -> String {
            var paras: [String] = []

            // 1. What it is.
            let archList = r.architectures.isEmpty ? "an unknown architecture"
                : r.architectures.joined(separator: " + ")
            var opening = "This is a Mach-O executable built for \(archList)."
            if r.linkedLibraryCount > 0 || r.importedSymbolCount > 0 {
                opening += " It links \(count(r.linkedLibraryCount, "system library", "system libraries"))"
                    + " and imports \(count(r.importedSymbolCount, "external function", "external functions"))."
            }
            paras.append(opening)

            // 2. Capability rundown from linked frameworks, grouped.
            let privacy = r.linkedCapabilities.filter { $0.privacySensitive }
            let nonPrivacy = r.linkedCapabilities.filter { !$0.privacySensitive }

            if !nonPrivacy.isEmpty {
                let titles = nonPrivacy.map { $0.title.lowercased() }
                paras.append("Capability surface (from the libraries it links): "
                    + naturalJoin(titles) + ".")
            }
            if !privacy.isEmpty {
                let lines = privacy.map { "• \($0.title): \($0.detail)" }
                paras.append("Privacy-sensitive frameworks detected:\n" + lines.joined(separator: "\n"))
            }

            // 3. Raw imported-call capabilities — the categories that show up
            // as direct libc/framework symbols (lower-level signal).
            let byCat = Dictionary(grouping: r.importedCalls, by: \.category)
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .filter { interestingCategories.contains($0.key) }
            if !byCat.isEmpty {
                let top = byCat.prefix(4).map { "\($0.key.rawValue.lowercased()) (\($0.value))" }
                paras.append("Direct system-call imports cluster around: \(top.joined(separator: ", ")).")
            }

            // 4. Patterns, loudest first.
            let ordered = r.patterns.sorted { a, b in
                let rank: [DisassemblyAnalyzer.Pattern.Confidence: Int] = [.high: 0, .medium: 1, .low: 2]
                return (rank[a.confidence] ?? 9) < (rank[b.confidence] ?? 9)
            }
            for p in ordered.prefix(6) {
                paras.append("• \(p.title) (\(p.confidence.rawValue) confidence): \(p.summary)")
            }

            // 5. Fidelity / caveats.
            var caveats: [String] = []
            if r.isEncrypted {
                caveats.append("This binary has an encrypted segment (typical of Mac App Store apps), so its instructions can't be disassembled until macOS decrypts it at launch — but the import table and linked libraries above are still accurate.")
            }
            if r.isStripped {
                caveats.append("The binary is stripped of local symbols, so function-level detail is limited; the imports and links it declares are unaffected.")
            }
            if r.linkedCapabilities.isEmpty && r.importedCalls.isEmpty && r.linkedLibraryCount == 0 {
                caveats.append("No libraries or imports could be read — the file may not be a Mach-O executable, or it may be unreadable.")
            }
            caveats.append("This is evidence of capability, not proof of behaviour: a referenced API means the code can do something, not that it does at runtime. Confirm with a monitored run.")
            paras.append(caveats.joined(separator: "\n\n"))

            return paras.joined(separator: "\n\n")
        }

        /// Categories worth calling out as direct imports (skip the noise:
        /// string ops, memory alloc, error handling, runtimes).
        private static let interestingCategories: Set<DisassemblyAnalyzer.Category> = [
            .networking, .crypto, .keychain, .shell, .process, .dynamicLoading,
            .privacy, .ipc, .fileIO
        ]

        static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
            "\(n) \(n == 1 ? singular : plural)"
        }

        static func naturalJoin(_ items: [String]) -> String {
            switch items.count {
            case 0: return ""
            case 1: return items[0]
            case 2: return "\(items[0]) and \(items[1])"
            default:
                return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
            }
        }
    }
}
