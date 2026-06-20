import Foundation

/// Detects common anti-analysis / anti-debugging patterns in a Mach-O.
///
/// Each finding shifts the user's prior — apps that try to hide what
/// they're doing from a debugger or a static-analysis tool deserve more
/// scrutiny, even when each individual signal has innocent explanations.
public enum AntiAnalysisDetector {

    public struct Result: Sendable, Hashable, Codable {
        public var findings: [Finding]
        public init(findings: [Finding] = []) { self.findings = findings }

        public struct Finding: Sendable, Hashable, Codable, Identifiable {
            public var id: String { kind.rawValue }
            public enum Kind: String, Sendable, Hashable, Codable {
                case ptraceDenyAttach    = "ptrace(PT_DENY_ATTACH)"
                case sysctlDebugCheck    = "sysctl debug detection"
                case encryptedSegment    = "Encrypted segment"
                case stripped            = "Stripped binary"
                case dyldInsertReference = "DYLD_INSERT_LIBRARIES literal"
                case obfuscatedSelectors = "Obfuscated Objective-C selectors"
            }
            public let kind: Kind
            public let summary: String
            public let detail: String?
            public let kbArticleID: String?
            public let confidence: Confidence
            public enum Confidence: String, Sendable, Hashable, Codable { case low, medium, high }
        }
    }

    /// Symbol/string tokens this detector needs the `BinaryStringScanner` pass
    /// to capture. `StaticAnalyzer` unions these into the scan symbol set so the
    /// ptrace/sysctl detectors actually have data. (PT_DENY_ATTACH, KERN_PROC
    /// and P_TRACED are numeric macros — they only appear if used as string
    /// literals; the reliable ptrace signal is the imported `_ptrace` symbol.)
    public static let scanSymbols: [String] = [
        "_ptrace", "ptrace", "KERN_PROC", "P_TRACED", "DYLD_INSERT_LIBRARIES"
    ]

    /// Run the detector against an executable on disk plus the cheap
    /// pre-extracted `BinaryStringScanner` result we already produce. `isMASApp`
    /// gates the encrypted-segment signal: FairPlay encryption is expected for
    /// App Store apps and is not an anti-analysis signal there.
    public static func analyse(executable url: URL,
                               scan: BinaryStringScanner.Result,
                               isMASApp: Bool = false) -> Result {
        let machO = MachOInspector.loadCommands(of: url)
        return Result(findings: findings(
            symbols: scan.foundFrameworkSymbols,
            hasEncryptedSegment: machO.hasEncryptedSegment,
            isStripped: machO.isStripped,
            isMASApp: isMASApp))
    }

    /// Pure gating logic, split out so it is testable without a Mach-O on disk.
    ///
    /// The KB's guidance: a *lone* anti-analysis signal is rarely meaningful —
    /// the combination is. So deliberate signals (intentional anti-debug /
    /// injection awareness / non-App-Store encryption) are separated from
    /// ambient artefacts (a stripped binary; expected App-Store encryption).
    /// Two+ deliberate signals corroborate and are raised to high; a stripped
    /// binary is surfaced only when a deliberate signal gives it meaning;
    /// App-Store encryption is always shown but flagged low/expected.
    static func findings(symbols syms: Set<String>,
                         hasEncryptedSegment: Bool,
                         isStripped: Bool,
                         isMASApp: Bool) -> [Result.Finding] {
        var deliberate: [Result.Finding] = []
        var info: [Result.Finding] = []
        var corroborationOnly: [Result.Finding] = []

        // ptrace(PT_DENY_ATTACH): the static signal is the imported `_ptrace`
        // symbol (the PT_DENY_ATTACH argument is a numeric macro, not a string).
        if syms.contains("_ptrace") || syms.contains("ptrace") {
            deliberate.append(.init(
                kind: .ptraceDenyAttach,
                summary: "Imports `ptrace` — likely used with PT_DENY_ATTACH to refuse debugger attachment.",
                detail: "macOS's `ptrace(PT_DENY_ATTACH)` is the canonical anti-debug call: a process invokes it on itself and any later debugger attach fails with EPERM. Legitimate uses include DRM and game anti-cheat; concerning when the app has no obvious reason to refuse inspection.",
                kbArticleID: "antianalysis-ptrace",
                confidence: .medium))
        }

        // sysctl P_TRACED check: only fires when the distinguishing constants
        // appear as string literals (rare). Bare `sysctl` is far too common to
        // flag — almost every app reads sysctl for system info.
        if syms.contains("KERN_PROC") && syms.contains("P_TRACED") {
            deliberate.append(.init(
                kind: .sysctlDebugCheck,
                summary: "Looks for the P_TRACED flag via sysctl — alternate anti-debug pattern.",
                detail: "Some apps detect a debugger by calling sysctl(KERN_PROC, KERN_PROC_PID, …) and checking the P_TRACED bit on kp_proc.p_flag. The second-most-common macOS anti-debug technique after PT_DENY_ATTACH.",
                kbArticleID: "antianalysis-sysctl",
                confidence: .medium))
        }

        // DYLD_INSERT_LIBRARIES literal.
        if syms.contains("DYLD_INSERT_LIBRARIES") {
            deliberate.append(.init(
                kind: .dyldInsertReference,
                summary: "References the DYLD_INSERT_LIBRARIES environment variable.",
                detail: "This env var injects a dylib into a process at launch; legitimate for debuggers/profilers/tests but also the standard injection vector for malware. The reference alone doesn't prove intent — it shows the code knows the mechanism.",
                kbArticleID: "antianalysis-dyld-insert",
                confidence: .medium))
        }

        // Encrypted segment — expected (FairPlay) for App Store apps, notable
        // outside it (custom DRM).
        if hasEncryptedSegment {
            if isMASApp {
                info.append(.init(
                    kind: .encryptedSegment,
                    summary: "Encrypted segment (LC_ENCRYPTION_INFO) — expected for a Mac App Store app.",
                    detail: "App Store apps ship FairPlay-encrypted and dyld decrypts at launch. Normal for App Store distribution; not an anti-analysis signal here.",
                    kbArticleID: "antianalysis-encrypted",
                    confidence: .low))
            } else {
                deliberate.append(.init(
                    kind: .encryptedSegment,
                    summary: "Mach-O has an encrypted segment outside the App Store (LC_ENCRYPTION_INFO).",
                    detail: "Encrypted at rest; dyld decrypts at launch. Outside the App Store this suggests a custom DRM scheme — disassembly won't see the real code without a memory dump from a running instance.",
                    kbArticleID: "antianalysis-encrypted",
                    confidence: .medium))
            }
        }

        // Stripped — a normal release-build optimisation. Surfaced only when
        // corroborated by a deliberate signal.
        if isStripped {
            corroborationOnly.append(.init(
                kind: .stripped,
                summary: "Symbol table is unusually small — binary appears stripped.",
                detail: "Local-symbol stripping is a normal release optimisation; most production apps ship stripped. Surfaced here only because it compounds with other anti-analysis signals.",
                kbArticleID: "antianalysis-stripped",
                confidence: .low))
        }

        // The combination is what matters: >= 2 deliberate signals corroborate
        // and rise to high; a lone deliberate signal stays medium.
        let corroborated = deliberate.count >= 2
        var out = deliberate.map { f -> Result.Finding in
            guard corroborated, f.confidence != .low else { return f }
            return .init(kind: f.kind, summary: f.summary, detail: f.detail,
                         kbArticleID: f.kbArticleID, confidence: .high)
        }
        out += info
        if !deliberate.isEmpty { out += corroborationOnly }
        return out
    }
}