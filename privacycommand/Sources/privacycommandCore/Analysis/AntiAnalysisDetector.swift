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

    /// Run the detector against an executable on disk plus the cheap
    /// pre-extracted `BinaryStringScanner` result we already produce.
    public static func analyse(executable url: URL,
                               scan: BinaryStringScanner.Result) -> Result {
        var findings: [Result.Finding] = []
        let machO = MachOInspector.loadCommands(of: url)

        // 1. ptrace(PT_DENY_ATTACH) — searched by symbol presence in scan.
        // The most reliable signal is the literal symbol name `_ptrace`
        // PLUS a sibling literal `PT_DENY_ATTACH`. We also accept `_sysctl`
        // for the alternate technique below.
        if scan.foundFrameworkSymbols.contains("ptrace")
            || scan.foundFrameworkSymbols.contains("PT_DENY_ATTACH") {
            findings.append(.init(
                kind: .ptraceDenyAttach,
                summary: "References `ptrace` — possibly used with PT_DENY_ATTACH to refuse debugger attachment.",
                detail: "macOS's `ptrace(PT_DENY_ATTACH)` is the canonical anti-debug call: a process invokes it on itself, and from then on any attempt to attach a debugger fails with EPERM. The code remains debuggable through Apple's get-task-allow workaround (used by Xcode's debug builds) but denies attachment in production. Legitimate uses include DRM and game anti-cheat; concerning when the app has no obvious reason to refuse inspection.",
                kbArticleID: "antianalysis-ptrace",
                confidence: .medium))
        }

        // 2. sysctl-based debug detection — signature is reading
        // KERN_PROC + checking the P_TRACED flag on the bsdinfo struct.
        // Detected via the literal "P_TRACED" or repeated `sysctl` symbol
        // refs combined with `KERN_PROC`. These rarely appear together by
        // accident.
        let strings = scan.paths.map { $0.lowercased() }   // cheap haystack
            + scan.urls.map { $0.lowercased() }
        let mentionsKernProc = strings.contains(where: { $0.contains("kern_proc") })
            || scan.foundFrameworkSymbols.contains("KERN_PROC")
        let mentionsPTraced = strings.contains(where: { $0.contains("p_traced") })
            || scan.foundFrameworkSymbols.contains("P_TRACED")
        if mentionsKernProc && mentionsPTraced {
            findings.append(.init(
                kind: .sysctlDebugCheck,
                summary: "Looks for the P_TRACED flag via sysctl — alternate anti-debug pattern.",
                detail: "Some apps detect a debugger by calling `sysctl(KERN_PROC, KERN_PROC_PID, …)` and checking whether the returned `kp_proc.p_flag` has the `P_TRACED` bit set. This is the second-most-common anti-debug technique on macOS after `PT_DENY_ATTACH`.",
                kbArticleID: "antianalysis-sysctl",
                confidence: .high))
        }

        // 3. Encrypted segment — Mac App Store apps and some DRM-protected
        // apps ship LC_ENCRYPTION_INFO with cryptid != 0. Static analysis
        // is impossible until decrypted by dyld at launch.
        if machO.hasEncryptedSegment {
            findings.append(.init(
                kind: .encryptedSegment,
                summary: "Mach-O contains an encrypted segment (LC_ENCRYPTION_INFO).",
                detail: "Encrypted at rest; dyld decrypts at launch. Common in Mac App Store apps shipped through Apple's FairPlay DRM. Outside the App Store this is unusual and suggests a custom DRM scheme — disassembly tools won't see the real code without a memory dump from a running instance.",
                kbArticleID: "antianalysis-encrypted",
                confidence: .high))
        }

        // 4. Stripped — heuristic via SYMTAB string-table size.
        if machO.isStripped {
            findings.append(.init(
                kind: .stripped,
                summary: "Symbol table is unusually small — binary appears stripped.",
                detail: "Local-symbol stripping is a normal release-build optimisation; many production apps ship stripped. We surface it here because stripped binaries are noticeably harder to reverse-engineer, which compounds with other anti-analysis signals.",
                kbArticleID: "antianalysis-stripped",
                confidence: .low))
        }

        // 5. DYLD_INSERT_LIBRARIES references in the binary's literals —
        // strong injection-tooling signal.
        if scan.foundFrameworkSymbols.contains("DYLD_INSERT_LIBRARIES") {
            findings.append(.init(
                kind: .dyldInsertReference,
                summary: "References the DYLD_INSERT_LIBRARIES environment variable.",
                detail: "This env var injects a dylib into a process at launch; legitimate uses include debuggers, profilers, and testing harnesses, but it is also the standard injection vector for malware. The reference alone doesn't prove malicious intent — it just tells us the code knows about the mechanism.",
                kbArticleID: "antianalysis-dyld-insert",
                confidence: .medium))
        }

        return Result(findings: findings)
    }
}
