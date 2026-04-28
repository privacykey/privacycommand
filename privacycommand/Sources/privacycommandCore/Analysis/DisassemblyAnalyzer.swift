import Foundation

/// Forensic analysis of `objdump -d` output (or any disassembler that emits
/// AT&T-flavoured listings with Mach-O symbol-stub annotations).
///
/// The goal is **plain-English narrative for non-experts**. Reading raw
/// `mov`/`add`/`bl` instructions is meaningless to most users, so this
/// analyzer extracts the bits a human can actually act on:
///
///   * **External calls** — `bl … ; symbol stub for: _foo` lines tell you
///     what the binary is *asking the operating system to do*. Counting
///     and categorising those reveals capabilities (file I/O, networking,
///     keychain access, `system()` calls, etc).
///   * **String literals** — `; literal pool for: "…"` reveals embedded
///     paths, URLs, error messages, and command lines.
///   * **High-level patterns** — combinations of the above let us infer
///     architectural facts: "this is a stub launcher", "uses Chromium's
///     PartitionAlloc", "hooks malloc", "does C++ exception unwinding",
///     "talks to the keychain".
///
/// The analyzer is **deliberately format-tolerant**: objdump's output
/// changes between LLVM versions, otool's `-tV` looks slightly different,
/// and Apple sometimes annotates symbols with `_<name>` and sometimes
/// without the underscore. We use loose regex matching and treat anything
/// we can't recognise as a no-op rather than failing.
public enum DisassemblyAnalyzer {

    // MARK: - Public types

    public struct Summary: Sendable, Hashable, Codable {
        public var totalLines: Int
        public var totalInstructions: Int
        public var totalFunctions: Int
        public var architecture: String?
        public var externalCalls: [ExternalCall]
        public var stringLiterals: [String]
        public var detectedPatterns: [Pattern]
        /// One-paragraph plain-English narrative, ready for display.
        public var narrative: String

        public init(totalLines: Int = 0,
                    totalInstructions: Int = 0,
                    totalFunctions: Int = 0,
                    architecture: String? = nil,
                    externalCalls: [ExternalCall] = [],
                    stringLiterals: [String] = [],
                    detectedPatterns: [Pattern] = [],
                    narrative: String = "") {
            self.totalLines = totalLines
            self.totalInstructions = totalInstructions
            self.totalFunctions = totalFunctions
            self.architecture = architecture
            self.externalCalls = externalCalls
            self.stringLiterals = stringLiterals
            self.detectedPatterns = detectedPatterns
            self.narrative = narrative
        }
    }

    public struct ExternalCall: Sendable, Hashable, Codable, Identifiable {
        public var id: String { symbol }
        /// The mangled / decorated name as it appears in the disassembly,
        /// e.g. `_dlopen`, `_NSGetExecutablePath`, `___stack_chk_fail`.
        public let symbol: String
        /// The category we've assigned this symbol to.
        public let category: Category
        /// How many times the binary called this symbol (across all
        /// functions in the disassembly window we analysed).
        public let callCount: Int
        /// Short human label, e.g. "Open shared library", "Read keychain
        /// item", "Launch shell command".
        public let humanLabel: String
        /// KB article ID if there's a deeper write-up, else nil.
        public let kbArticleID: String?

        public init(symbol: String, category: Category, callCount: Int,
                    humanLabel: String, kbArticleID: String? = nil) {
            self.symbol = symbol
            self.category = category
            self.callCount = callCount
            self.humanLabel = humanLabel
            self.kbArticleID = kbArticleID
        }
    }

    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case fileIO            = "File I/O"
        case process           = "Process control"
        case dynamicLoading    = "Dynamic loading"
        case networking        = "Networking"
        case crypto            = "Cryptography"
        case keychain          = "Keychain"
        case stringOps         = "String / memory ops"
        case memoryAlloc       = "Memory allocation"
        case threading         = "Threading"
        case errorHandling     = "Errors & exceptions"
        case privacy           = "Privacy-sensitive"
        case ipc               = "IPC"
        case shell             = "Shell execution"
        case objc              = "Objective-C runtime"
        case swift             = "Swift runtime"
        case cppRuntime        = "C++ runtime"
        case other             = "Other"
    }

    public struct Pattern: Sendable, Hashable, Codable, Identifiable {
        public var id: String { kind.rawValue }
        public enum Kind: String, Sendable, Hashable, Codable {
            case stubLauncher
            case partitionAlloc
            case mallocInterception
            case cppExceptions
            case keychainAccess
            case shellExecution
            case networkConnection
            case cryptoUse
            case dyldInjectionHooks
            case keyloggerLikely
            case privilegeEscalation
        }
        public let kind: Kind
        public let title: String
        public let summary: String
        public let confidence: Confidence
        /// The symbols / strings that triggered this detection. Lets the UI
        /// show "why we think so" so the user can audit the inference.
        public let evidence: [String]
        public let kbArticleID: String?

        public enum Confidence: String, Sendable, Hashable, Codable {
            case low, medium, high
        }
    }

    // MARK: - Entry point

    /// Analyse a chunk of disassembly text. Designed to be cheap enough to
    /// run on a few hundred kilobytes of objdump output on the main thread
    /// without locking the UI noticeably; for whole-binary dumps the caller
    /// should run this on a background queue.
    public static func analyse(disassembly text: String, maxLines: Int = 200_000) -> Summary {
        // Hard cap: enormous binaries (Chrome's framework is ~600 MB of
        // text when fully disassembled) would otherwise dominate the run.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cappedLines = lines.prefix(maxLines)

        var totalInstr = 0
        var totalFns = 0
        var arch: String? = nil
        var stubCounts: [String: Int] = [:]
        var literals: [String] = []
        var seenLiterals = Set<String>()

        // Cheap regex objects, compiled once per call.
        // NB: NSRegularExpression is intentionally not stored statically —
        // these patterns are very fast and the analyzer is rarely called.
        let stubRE = try? NSRegularExpression(
            pattern: #";\s*symbol stub for:\s*([A-Za-z0-9_\$\.@:]+)"#,
            options: [])
        let literalRE = try? NSRegularExpression(
            pattern: #";\s*literal pool for:\s*"(.+)"\s*$"#,
            options: [])
        let funcRE = try? NSRegularExpression(
            pattern: #"^[_A-Za-z][A-Za-z0-9_\.\$]*:\s*$"#,
            options: [])
        let archRE = try? NSRegularExpression(
            pattern: #"file format\s+([A-Za-z0-9\-]+)"#,
            options: [])
        // Match a tab-indented disassembly line: "<addr>: <bytes>\t<mnemonic>…"
        let instrRE = try? NSRegularExpression(
            pattern: #"^\s*[0-9a-fA-F]+:\s+[0-9a-fA-F ]+\s+[a-z]+"#,
            options: [])

        for line in cappedLines {
            let s = String(line)
            let r = NSRange(s.startIndex..<s.endIndex, in: s)

            if arch == nil, let m = archRE?.firstMatch(in: s, range: r),
               m.numberOfRanges > 1, let rg = Range(m.range(at: 1), in: s) {
                arch = String(s[rg])
            }
            if let m = stubRE?.firstMatch(in: s, range: r),
               m.numberOfRanges > 1, let rg = Range(m.range(at: 1), in: s) {
                stubCounts[String(s[rg]), default: 0] += 1
            }
            if let m = literalRE?.firstMatch(in: s, range: r),
               m.numberOfRanges > 1, let rg = Range(m.range(at: 1), in: s) {
                let lit = String(s[rg])
                if seenLiterals.insert(lit).inserted, lit.count <= 240 {
                    literals.append(lit)
                }
            }
            if funcRE?.firstMatch(in: s, range: r) != nil { totalFns += 1 }
            if instrRE?.firstMatch(in: s, range: r) != nil { totalInstr += 1 }
        }

        // Resolve external calls into the rich form, sorted by frequency.
        let calls: [ExternalCall] = stubCounts
            .map { (sym, count) -> ExternalCall in
                let info = SymbolDictionary.lookup(sym)
                return ExternalCall(symbol: sym,
                                    category: info.category,
                                    callCount: count,
                                    humanLabel: info.label,
                                    kbArticleID: info.kbArticleID)
            }
            .sorted {
                if $0.callCount != $1.callCount { return $0.callCount > $1.callCount }
                return $0.symbol < $1.symbol
            }

        let patterns = PatternDetector.detect(calls: calls, literals: literals)
        let narrative = NarrativeBuilder.build(
            totalInstr: totalInstr, totalFns: totalFns,
            architecture: arch, calls: calls, patterns: patterns)

        return Summary(
            totalLines: lines.count,
            totalInstructions: totalInstr,
            totalFunctions: totalFns,
            architecture: arch,
            externalCalls: calls,
            stringLiterals: literals,
            detectedPatterns: patterns,
            narrative: narrative
        )
    }

    // MARK: - Symbol dictionary
    //
    // Intentionally pragmatic, not exhaustive. We're not trying to model
    // every libc function — only the ones a non-expert would want flagged
    // because they hint at a *capability*. Anything not listed falls back
    // to a heuristic categorisation by name prefix.

    fileprivate enum SymbolDictionary {
        struct Info { let category: Category; let label: String; let kbArticleID: String? }

        static func lookup(_ symbol: String) -> Info {
            // Strip leading underscore (Mach-O convention).
            let s = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
            if let exact = exact[s] { return exact }
            // Heuristic by prefix (alphabetical).
            if s.hasPrefix("AVCapture")               { return .init(category: .privacy, label: "Camera / microphone capture", kbArticleID: "privacy-NSCameraUsageDescription") }
            if s.hasPrefix("AX") && s.contains("Trusted") { return .init(category: .privacy, label: "Accessibility API check", kbArticleID: nil) }
            if s.hasPrefix("CB")                      { return .init(category: .privacy, label: "Bluetooth (CoreBluetooth)", kbArticleID: nil) }
            if s.hasPrefix("CC")                      { return .init(category: .crypto, label: "CommonCrypto primitive", kbArticleID: nil) }
            if s.hasPrefix("CFNetwork") || s.hasPrefix("CFURL") || s.hasPrefix("CFHTTP") {
                return .init(category: .networking, label: "CoreFoundation networking", kbArticleID: nil)
            }
            if s.hasPrefix("CL")                      { return .init(category: .privacy, label: "Location services", kbArticleID: "privacy-NSLocationUsageDescription") }
            if s.hasPrefix("CN")                      { return .init(category: .privacy, label: "Contacts framework", kbArticleID: "privacy-NSContactsUsageDescription") }
            if s.hasPrefix("CGDisplay") || s.hasPrefix("CGWindow") || s.hasPrefix("ScreenCapture") {
                return .init(category: .privacy, label: "Screen capture", kbArticleID: "privacy-NSScreenCaptureUsageDescription")
            }
            if s.hasPrefix("EK")                      { return .init(category: .privacy, label: "Calendar / reminders", kbArticleID: "privacy-NSCalendarsUsageDescription") }
            if s.hasPrefix("PH")                      { return .init(category: .privacy, label: "Photos library", kbArticleID: "privacy-NSPhotoLibraryUsageDescription") }
            if s.hasPrefix("HM")                      { return .init(category: .privacy, label: "HomeKit", kbArticleID: nil) }
            if s.hasPrefix("Sec") || s.hasPrefix("SSL") {
                return .init(category: .crypto, label: "Security framework", kbArticleID: nil)
            }
            if s.hasPrefix("SecKeychain") || s.hasPrefix("kSecClass") {
                return .init(category: .keychain, label: "Keychain access", kbArticleID: nil)
            }
            if s.hasPrefix("__cxa") || s.hasPrefix("_Unwind") || s.hasPrefix("Unwind") {
                return .init(category: .cppRuntime, label: "C++ exception machinery", kbArticleID: "asm-cpp-exceptions")
            }
            if s.hasPrefix("objc_") || s.hasPrefix("_objc_") {
                return .init(category: .objc, label: "Objective-C runtime", kbArticleID: nil)
            }
            if s.hasPrefix("swift_") || s.hasPrefix("_swift_") {
                return .init(category: .swift, label: "Swift runtime", kbArticleID: nil)
            }
            if s.hasPrefix("dispatch_") || s.contains("pthread_") {
                return .init(category: .threading, label: "Threading / dispatch", kbArticleID: nil)
            }
            if s.hasPrefix("xpc_") || s.contains("mach_msg") || s.contains("bootstrap_") {
                return .init(category: .ipc, label: "IPC (XPC / Mach)", kbArticleID: nil)
            }
            if s.contains("malloc") || s.contains("free") || s.contains("calloc") || s.contains("realloc") {
                return .init(category: .memoryAlloc, label: "Memory allocator", kbArticleID: "asm-malloc")
            }
            if s.hasPrefix("str") || s.hasPrefix("mem") || s.hasPrefix("wcs") {
                return .init(category: .stringOps, label: "String / memory operation", kbArticleID: nil)
            }
            return .init(category: .other, label: "External call (\(symbol))", kbArticleID: nil)
        }

        // Exact-match table for well-known APIs. Sorted alphabetically for
        // human review.
        static let exact: [String: Info] = [
            // Dynamic loading -------------------------------------------------
            "dlopen":               .init(category: .dynamicLoading, label: "Open a shared library at runtime", kbArticleID: "asm-dlopen"),
            "dlsym":                .init(category: .dynamicLoading, label: "Resolve a symbol at runtime", kbArticleID: "asm-dlopen"),
            "dlclose":              .init(category: .dynamicLoading, label: "Close a previously opened shared library", kbArticleID: "asm-dlopen"),
            "dlerror":              .init(category: .dynamicLoading, label: "Read the last dynamic-loader error", kbArticleID: "asm-dlopen"),
            "NSGetExecutablePath":  .init(category: .dynamicLoading, label: "Find own executable path on disk", kbArticleID: nil),
            "_dyld_image_count":    .init(category: .dynamicLoading, label: "Enumerate loaded dylibs", kbArticleID: nil),

            // File I/O --------------------------------------------------------
            "open":                 .init(category: .fileIO, label: "Open a file", kbArticleID: nil),
            "openat":               .init(category: .fileIO, label: "Open a file (relative to a directory fd)", kbArticleID: nil),
            "close":                .init(category: .fileIO, label: "Close a file descriptor", kbArticleID: nil),
            "read":                 .init(category: .fileIO, label: "Read from a file / pipe / socket", kbArticleID: nil),
            "write":                .init(category: .fileIO, label: "Write to a file / pipe / socket", kbArticleID: nil),
            "fopen":                .init(category: .fileIO, label: "Open a file (stdio)", kbArticleID: nil),
            "fread":                .init(category: .fileIO, label: "Buffered read", kbArticleID: nil),
            "fwrite":               .init(category: .fileIO, label: "Buffered write", kbArticleID: nil),
            "stat":                 .init(category: .fileIO, label: "Look up file metadata", kbArticleID: nil),
            "lstat":                .init(category: .fileIO, label: "Look up file metadata (no symlink follow)", kbArticleID: nil),
            "unlink":               .init(category: .fileIO, label: "Delete a file", kbArticleID: nil),
            "rename":               .init(category: .fileIO, label: "Rename / move a file", kbArticleID: nil),
            "mmap":                 .init(category: .fileIO, label: "Map a file into memory", kbArticleID: nil),
            "munmap":               .init(category: .fileIO, label: "Unmap memory", kbArticleID: nil),

            // Process / shell -------------------------------------------------
            "fork":                 .init(category: .process, label: "Fork a child process", kbArticleID: nil),
            "vfork":                .init(category: .process, label: "Fork a child process (vfork)", kbArticleID: nil),
            "execv":                .init(category: .process, label: "Replace this process with another binary", kbArticleID: nil),
            "execve":               .init(category: .process, label: "Replace this process with another binary", kbArticleID: nil),
            "execvp":               .init(category: .process, label: "Replace this process with another binary (PATH search)", kbArticleID: nil),
            "posix_spawn":          .init(category: .process, label: "Spawn a child process", kbArticleID: nil),
            "system":               .init(category: .shell, label: "Run a shell command (`system(3)`)", kbArticleID: "asm-shell"),
            "popen":                .init(category: .shell, label: "Run a shell command and capture its output", kbArticleID: "asm-shell"),
            "kill":                 .init(category: .process, label: "Send a signal to another process", kbArticleID: nil),
            "exit":                 .init(category: .process, label: "Terminate this process", kbArticleID: nil),
            "abort":                .init(category: .errorHandling, label: "Abort with SIGABRT", kbArticleID: nil),
            "abort_report_np":      .init(category: .errorHandling, label: "Abort with a structured crash report", kbArticleID: nil),
            "__assert_rtn":         .init(category: .errorHandling, label: "Failed assertion", kbArticleID: nil),
            "__stack_chk_fail":     .init(category: .errorHandling, label: "Stack buffer overflow detected", kbArticleID: nil),

            // Networking ------------------------------------------------------
            "socket":               .init(category: .networking, label: "Open a network socket", kbArticleID: nil),
            "connect":              .init(category: .networking, label: "Connect a socket to a remote endpoint", kbArticleID: nil),
            "bind":                 .init(category: .networking, label: "Bind a socket to a local port", kbArticleID: nil),
            "listen":               .init(category: .networking, label: "Listen for incoming connections", kbArticleID: nil),
            "accept":               .init(category: .networking, label: "Accept an incoming connection", kbArticleID: nil),
            "getaddrinfo":          .init(category: .networking, label: "Resolve a hostname (DNS)", kbArticleID: nil),
            "send":                 .init(category: .networking, label: "Send data on a socket", kbArticleID: nil),
            "recv":                 .init(category: .networking, label: "Receive data on a socket", kbArticleID: nil),
            "CFSocketCreate":       .init(category: .networking, label: "Create a CoreFoundation socket", kbArticleID: nil),

            // Crypto ----------------------------------------------------------
            "CCCrypt":              .init(category: .crypto, label: "Symmetric encryption / decryption", kbArticleID: nil),
            "CCHmac":               .init(category: .crypto, label: "Compute an HMAC", kbArticleID: nil),
            "SecRandomCopyBytes":   .init(category: .crypto, label: "Cryptographically-secure random bytes", kbArticleID: nil),

            // Keychain --------------------------------------------------------
            "SecItemCopyMatching":  .init(category: .keychain, label: "Read a keychain item", kbArticleID: "asm-keychain"),
            "SecItemAdd":           .init(category: .keychain, label: "Save a keychain item", kbArticleID: "asm-keychain"),
            "SecItemUpdate":        .init(category: .keychain, label: "Update a keychain item", kbArticleID: "asm-keychain"),
            "SecItemDelete":        .init(category: .keychain, label: "Delete a keychain item", kbArticleID: "asm-keychain"),

            // Memory allocation (Chrome / Chromium specifics) -----------------
            "malloc_get_all_zones":          .init(category: .memoryAlloc, label: "Inspect every malloc zone (Chromium-style allocator hooking)", kbArticleID: "asm-malloc-interception"),
            "malloc_zone_register":          .init(category: .memoryAlloc, label: "Register a custom malloc zone", kbArticleID: "asm-malloc-interception"),
            "malloc_zone_unregister":        .init(category: .memoryAlloc, label: "Unregister a malloc zone", kbArticleID: "asm-malloc-interception"),
            "malloc_default_zone":           .init(category: .memoryAlloc, label: "Get the default malloc zone", kbArticleID: "asm-malloc-interception"),

            // C++ ABI ---------------------------------------------------------
            "__cxa_throw":          .init(category: .cppRuntime, label: "Throw a C++ exception", kbArticleID: "asm-cpp-exceptions"),
            "__cxa_begin_catch":    .init(category: .cppRuntime, label: "Begin a C++ catch handler", kbArticleID: "asm-cpp-exceptions"),
            "__cxa_end_catch":      .init(category: .cppRuntime, label: "End a C++ catch handler", kbArticleID: "asm-cpp-exceptions"),
            "_Unwind_RaiseException": .init(category: .cppRuntime, label: "Raise an exception (C++ unwinder)", kbArticleID: "asm-cpp-exceptions"),
            "_Unwind_Resume":       .init(category: .cppRuntime, label: "Resume unwinding after a finally", kbArticleID: "asm-cpp-exceptions"),

            // String / mem ----------------------------------------------------
            "strcmp":               .init(category: .stringOps, label: "Compare two C strings", kbArticleID: nil),
            "strncmp":              .init(category: .stringOps, label: "Compare two C strings (bounded)", kbArticleID: nil),
            "strlen":               .init(category: .stringOps, label: "Compute string length", kbArticleID: nil),
            "memcpy":               .init(category: .stringOps, label: "Copy memory", kbArticleID: nil),
            "memset":               .init(category: .stringOps, label: "Fill memory", kbArticleID: nil),
            "memcmp":               .init(category: .stringOps, label: "Compare memory", kbArticleID: nil),
            "bzero":                .init(category: .stringOps, label: "Zero memory", kbArticleID: nil),

            // Threading -------------------------------------------------------
            "pthread_create":       .init(category: .threading, label: "Create a thread", kbArticleID: nil),
            "pthread_mutex_lock":   .init(category: .threading, label: "Acquire a mutex", kbArticleID: nil),
            "pthread_mutex_unlock": .init(category: .threading, label: "Release a mutex", kbArticleID: nil),
            "dispatch_async":       .init(category: .threading, label: "Queue work on a GCD queue", kbArticleID: nil),
            "dispatch_sync":        .init(category: .threading, label: "Run work synchronously on a GCD queue", kbArticleID: nil),
            "dispatch_once":        .init(category: .threading, label: "Run work exactly once", kbArticleID: nil),

            // IPC -------------------------------------------------------------
            "xpc_connection_create":  .init(category: .ipc, label: "Open an XPC connection", kbArticleID: nil),
            "xpc_connection_resume":  .init(category: .ipc, label: "Activate an XPC connection", kbArticleID: nil),
            "xpc_connection_send_message": .init(category: .ipc, label: "Send an XPC message", kbArticleID: nil),

            // Privilege -------------------------------------------------------
            "AuthorizationCreate":          .init(category: .privacy, label: "Request an authorization rights set (admin prompt)", kbArticleID: nil),
            "AuthorizationExecuteWithPrivileges": .init(category: .privacy, label: "Run a tool as root (deprecated, dangerous)", kbArticleID: nil),
            "SMJobBless":                    .init(category: .privacy, label: "Install a privileged helper (legacy)", kbArticleID: nil),

            // Misc Apple ------------------------------------------------------
            "getenv":               .init(category: .other, label: "Read an environment variable", kbArticleID: nil),
            "setenv":               .init(category: .other, label: "Set an environment variable", kbArticleID: nil),
            "unsetenv":             .init(category: .other, label: "Clear an environment variable", kbArticleID: nil),
        ]
    }

    // MARK: - Pattern detection

    fileprivate enum PatternDetector {
        static func detect(calls: [ExternalCall], literals: [String]) -> [Pattern] {
            var out: [Pattern] = []
            let symbols = Set(calls.map { $0.symbol.hasPrefix("_") ? String($0.symbol.dropFirst()) : $0.symbol })
            let lowerLiterals = literals.map { $0.lowercased() }

            // Stub launcher: tiny binary that mainly does `dlopen` + `dlsym`
            // + `NSGetExecutablePath` and not much else. Common pattern for
            // app stubs (the Chromium "Helper" binaries, CrashReporter, etc).
            if symbols.contains("dlopen"), symbols.contains("dlsym"),
               symbols.contains("NSGetExecutablePath") || symbols.contains("_NSGetExecutablePath"),
               calls.count < 60 {
                out.append(Pattern(
                    kind: .stubLauncher,
                    title: "Stub launcher",
                    summary: "This binary is small and mostly loads another framework at runtime via `dlopen`/`dlsym`, then jumps into it. Browsers (Chrome/Edge), Electron apps, and CrashReporter helpers all do this so multiple sub-binaries can share the same big framework on disk.",
                    confidence: .high,
                    evidence: ["dlopen", "dlsym", "NSGetExecutablePath"],
                    kbArticleID: "asm-stub-launcher"))
            }

            // Chromium PartitionAlloc — registers itself as the default
            // malloc zone. Distinguishing detail: walks `malloc_get_all_zones`.
            if symbols.contains("malloc_get_all_zones"),
               (symbols.contains("malloc_zone_register") || symbols.contains("malloc_default_zone")) {
                out.append(Pattern(
                    kind: .partitionAlloc,
                    title: "PartitionAlloc-style malloc replacement",
                    summary: "The binary walks every malloc zone and registers its own — the signature of Chromium's PartitionAlloc, Firefox's mozjemalloc, and similar custom allocators. This is a performance / security hardening feature, not a smoking gun.",
                    confidence: .high,
                    evidence: ["malloc_get_all_zones", "malloc_zone_register", "malloc_default_zone"]
                        .filter { symbols.contains($0) },
                    kbArticleID: "asm-partition-alloc"))
            } else if symbols.contains("malloc_zone_register") {
                out.append(Pattern(
                    kind: .mallocInterception,
                    title: "Custom malloc zone",
                    summary: "The binary registers its own malloc zone. This lets it intercept all heap allocations — usually for performance, sometimes for telemetry or anti-debugging.",
                    confidence: .medium,
                    evidence: ["malloc_zone_register"],
                    kbArticleID: "asm-malloc-interception"))
            }

            // C++ exception machinery. High confidence if we see `__cxa_throw`
            // **and** `_Unwind_RaiseException`; medium if just one.
            let cxaSeen = symbols.contains("__cxa_throw") || symbols.contains("__cxa_begin_catch")
            let unwindSeen = symbols.contains("_Unwind_RaiseException") || symbols.contains("_Unwind_Resume")
            if cxaSeen && unwindSeen {
                out.append(Pattern(
                    kind: .cppExceptions,
                    title: "C++ exception handling",
                    summary: "The binary throws and catches C++ exceptions. This is normal for any large native app written in C++; it is **not** an indicator of crashes — it just means the code uses `try`/`catch`.",
                    confidence: .high,
                    evidence: ["__cxa_throw", "_Unwind_RaiseException", "__cxa_begin_catch"]
                        .filter { symbols.contains($0) },
                    kbArticleID: "asm-cpp-exceptions"))
            } else if cxaSeen || unwindSeen {
                out.append(Pattern(
                    kind: .cppExceptions,
                    title: "C++ runtime support",
                    summary: "The binary links the C++ ABI runtime — typical for any C++ code, even if exceptions aren't actively thrown.",
                    confidence: .low,
                    evidence: ["__cxa_*", "_Unwind_*"].filter { _ in cxaSeen || unwindSeen },
                    kbArticleID: "asm-cpp-exceptions"))
            }

            if symbols.contains("SecItemCopyMatching") || symbols.contains("SecItemAdd")
                || symbols.contains("SecItemUpdate") || symbols.contains("SecItemDelete") {
                out.append(Pattern(
                    kind: .keychainAccess,
                    title: "Keychain access",
                    summary: "The binary reads or writes the macOS keychain. Expected in apps that store user credentials (email clients, password managers, browsers); worth noting in apps that have no obvious reason to need credentials.",
                    confidence: .high,
                    evidence: ["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete"]
                        .filter { symbols.contains($0) },
                    kbArticleID: "asm-keychain"))
            }

            if symbols.contains("system") || symbols.contains("popen") {
                out.append(Pattern(
                    kind: .shellExecution,
                    title: "Shell-command execution",
                    summary: "The binary calls `system(3)` or `popen(3)` — i.e. asks `/bin/sh` to run a shell command. Usually fine in installers and developer tools; suspicious in arbitrary apps because the command is often built from runtime-controlled strings.",
                    confidence: .high,
                    evidence: ["system", "popen"].filter { symbols.contains($0) },
                    kbArticleID: "asm-shell"))
            }

            if symbols.contains("connect") || symbols.contains("getaddrinfo") || symbols.contains("CFSocketCreate") {
                out.append(Pattern(
                    kind: .networkConnection,
                    title: "Outbound network capability",
                    summary: "The binary contains direct BSD-socket networking calls (`connect`, `getaddrinfo`, …). Most modern macOS apps use higher-level frameworks; seeing raw socket calls suggests a custom network stack.",
                    confidence: .medium,
                    evidence: ["connect", "getaddrinfo", "CFSocketCreate"].filter { symbols.contains($0) },
                    kbArticleID: nil))
            }

            if symbols.contains("CCCrypt") || symbols.contains("CCHmac") || symbols.contains("SecRandomCopyBytes") {
                out.append(Pattern(
                    kind: .cryptoUse,
                    title: "Uses cryptography",
                    summary: "The binary calls CommonCrypto / Security primitives — typical for apps that encrypt local data, sign requests, or talk TLS.",
                    confidence: .high,
                    evidence: ["CCCrypt", "CCHmac", "SecRandomCopyBytes"].filter { symbols.contains($0) },
                    kbArticleID: nil))
            }

            // DYLD insertion / mach_inject style — very strong signal.
            if lowerLiterals.contains(where: { $0.contains("dyld_insert_libraries") }) {
                out.append(Pattern(
                    kind: .dyldInjectionHooks,
                    title: "DYLD_INSERT_LIBRARIES reference",
                    summary: "The binary mentions `DYLD_INSERT_LIBRARIES` — the macOS environment variable used to inject a dylib into another process at launch. Sometimes legitimate (debuggers, testing tools); often a code-injection technique.",
                    confidence: .high,
                    evidence: ["DYLD_INSERT_LIBRARIES (literal)"],
                    kbArticleID: nil))
            }

            // Privilege escalation hints.
            if symbols.contains("AuthorizationExecuteWithPrivileges") {
                out.append(Pattern(
                    kind: .privilegeEscalation,
                    title: "Runs commands as root (deprecated API)",
                    summary: "Calls `AuthorizationExecuteWithPrivileges`, an Apple-deprecated API for running a tool as root after an admin prompt. Modern apps use `SMJobBless` / `SMAppService` instead. Worth scrutinising what command is being run.",
                    confidence: .high,
                    evidence: ["AuthorizationExecuteWithPrivileges"],
                    kbArticleID: nil))
            }

            // Heuristic: input-tap / keylogger smell — combination of
            // accessibility checks AND CGEvent tap creation strings.
            let accessibilityHit = symbols.contains(where: { $0.contains("AXIsProcessTrusted") || $0.contains("AXUIElementCopyAttributeValue") })
            let eventTapHit = lowerLiterals.contains(where: { $0.contains("cgeventtapcreate") })
            if accessibilityHit && eventTapHit {
                out.append(Pattern(
                    kind: .keyloggerLikely,
                    title: "Keyboard / input monitoring",
                    summary: "Combines an Accessibility-permission check with `CGEventTapCreate` references — the standard technique for system-wide keystroke or mouse monitoring. Legitimate in clipboard managers and macro tools; concerning in anything that doesn't advertise that purpose.",
                    confidence: .high,
                    evidence: ["AXIsProcessTrusted", "CGEventTapCreate"],
                    kbArticleID: nil))
            }

            return out
        }
    }

    // MARK: - Narrative builder

    fileprivate enum NarrativeBuilder {
        static func build(totalInstr: Int,
                          totalFns: Int,
                          architecture: String?,
                          calls: [ExternalCall],
                          patterns: [Pattern]) -> String {
            var sentences: [String] = []

            // Sentence 1: scale + arch.
            let arch = architecture.map { " (\($0))" } ?? ""
            sentences.append(
                "We disassembled \(formatted(totalInstr)) instruction\(totalInstr == 1 ? "" : "s") across \(formatted(totalFns)) function\(totalFns == 1 ? "" : "s")\(arch).")

            // Sentence 2: dominant categories.
            let byCat = Dictionary(grouping: calls, by: \.category)
                .mapValues { $0.reduce(0) { $0 + $1.callCount } }
                .sorted { $0.value > $1.value }
            if !byCat.isEmpty {
                let top = byCat.prefix(3).map { "\($0.key.rawValue.lowercased()) (\($0.value))" }
                sentences.append("Most external calls are in: \(top.joined(separator: ", ")).")
            }

            // Sentence 3+: one line per detected pattern, in confidence
            // order so the loudest signal lands first.
            let ordered = patterns.sorted { lhs, rhs in
                let order: [Pattern.Confidence] = [.high, .medium, .low]
                return (order.firstIndex(of: lhs.confidence) ?? 99)
                    < (order.firstIndex(of: rhs.confidence) ?? 99)
            }
            for p in ordered.prefix(5) {
                sentences.append("• \(p.title): \(p.summary)")
            }

            if patterns.isEmpty && calls.isEmpty {
                sentences.append("No external calls or recognisable patterns were detected — this might be a stripped or static-only fragment of the binary, or the disassembler output didn't include symbol annotations. Try `objdump -d --macho` or `otool -tV` for more detail.")
            }

            return sentences.joined(separator: "\n\n")
        }

        private static func formatted(_ n: Int) -> String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? String(n)
        }
    }
}
