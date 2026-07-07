import Foundation

/// Drives **Ghidra headless** (`analyzeHeadless`) to decompile a single
/// function of a Mach-O binary to readable C, on demand.
///
/// This is the "Ghidra-decompiled" half of the network-provenance feature:
/// the `DisassemblyAnalyzer` tells us *which* functions are capable of opening
/// a connection; this turns one of those functions into pseudocode a human can
/// read ("this code calls `connect()` after building the string
/// `api.cloudflare.com`").
///
/// **Design constraints (deliberate):**
///   * Ghidra is a multi-gigabyte Java application — we can't bundle it. Like
///     the rest of the app's tooling (`lsof`, `objdump`, `codesign`), we shell
///     out to a *user-installed* copy and degrade gracefully when it's absent.
///   * The first decompilation of a binary pays Ghidra's full auto-analysis
///     cost (often minutes). We amortise that by caching one Ghidra **project
///     per binary** keyed by path; subsequent functions reuse it via
///     `-process … -noanalysis` and return in seconds.
///   * We never modify the target binary. Projects and scripts live under the
///     app's Caches directory.
///
/// What it does **not** do: attribute a *runtime* TCP request to a function.
/// That needs a captured backtrace at `connect()` time (a future
/// privileged-helper tier). This is static decompilation of a *candidate*
/// call site surfaced by `DisassemblyAnalyzer.networkCallSites`.
public actor GhidraDecompiler {

    public init() {}

    // MARK: - Public surface

    public enum DecompileError: LocalizedError, Equatable {
        /// No `analyzeHeadless` found in any known Ghidra install location.
        case ghidraNotInstalled
        /// Ghidra ran but couldn't find a function by that name.
        case functionNotFound(String)
        /// Ghidra found the function but the decompiler failed on it.
        case decompileFailed(String)
        /// `analyzeHeadless` itself errored (bad install, missing JDK, …).
        case headlessError(String)

        public var errorDescription: String? {
            switch self {
            case .ghidraNotInstalled:
                return "Ghidra isn't installed. Install Ghidra (e.g. unzip a release into /Applications) and try again — the app looks for `support/analyzeHeadless` inside any `ghidra*` folder under /Applications, ~/Applications, /opt, /usr/local, or ~/Tools."
            case .functionNotFound(let fn):
                return "Ghidra analysed the binary but found no function named “\(fn)”. The symbol may be stripped or named differently in Ghidra's view (e.g. `FUN_0001abcd`)."
            case .decompileFailed(let msg):
                return "Ghidra couldn't decompile that function: \(msg)"
            case .headlessError(let msg):
                return "Ghidra headless failed: \(msg)"
            }
        }
    }

    public struct Decompilation: Sendable, Equatable {
        public let function: String
        /// The decompiled C, verbatim from Ghidra's `getDecompiledFunction`.
        public let cCode: String
        public init(function: String, cCode: String) {
            self.function = function
            self.cCode = cCode
        }
    }

    /// Cheap synchronous check for the UI: should we offer the Decompile
    /// action at all? Mirrors the launcher's Ghidra detection.
    public nonisolated static func isAvailable(searchRoots: [URL]? = nil,
                                               fileManager: FileManager = .default) -> Bool {
        locateAnalyzeHeadless(searchRoots: searchRoots, fileManager: fileManager) != nil
    }

    /// Decompile `function` from `binary`. First call for a given binary runs
    /// full auto-analysis (slow); later calls reuse the cached project.
    ///
    /// `address` (hex, no `0x`) is an optional fallback: if Ghidra can't find
    /// the function by name (stripped/renamed symbols), it looks up the
    /// function containing that address instead.
    public func decompile(binary: URL,
                          function: String,
                          address: String? = nil,
                          timeout: TimeInterval = 600) async throws -> Decompilation {
        guard let headless = Self.locateAnalyzeHeadless() else {
            throw DecompileError.ghidraNotInstalled
        }
        let fm = FileManager.default

        let projectsDir = try Self.cacheSubdir("ghidra-projects", fm: fm)
        let scriptsDir  = try Self.cacheSubdir("ghidra-scripts", fm: fm)
        let outDir      = try Self.cacheSubdir("ghidra-out", fm: fm)

        // One project per binary *content* → analysis cost is paid once, and
        // replacing the binary at a path invalidates its stale project.
        let projectName  = "pc_\(Self.projectKey(for: binary, fm: fm))"
        let projectFile  = projectsDir.appendingPathComponent("\(projectName).gpr")
        let alreadyImported = fm.fileExists(atPath: projectFile.path)

        // Materialise the post-script next to where we point -scriptPath.
        let scriptURL = scriptsDir.appendingPathComponent(Self.postScriptName)
        try Self.postScriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)

        // The script writes the C (or a marker line) into this file; we read
        // it rather than scraping analyzeHeadless's noisy stdout.
        let outFile = outDir.appendingPathComponent(
            "\(projectName)_\(Self.stableHash(function)).c")
        try? fm.removeItem(at: outFile)

        var args = [projectsDir.path, projectName]
        if alreadyImported {
            // Reopen the analysed program without re-analysing it.
            args += ["-process", binary.lastPathComponent, "-noanalysis"]
        } else {
            args += ["-import", binary.path]
        }
        args += ["-scriptPath", scriptsDir.path,
                 "-postScript", Self.postScriptName, function, outFile.path, address ?? ""]

        let result = try await Self.runHeadless(launchPath: headless.path,
                                                arguments: args,
                                                timeout: timeout)

        guard let raw = try? String(contentsOf: outFile, encoding: .utf8) else {
            // No output file means the script never ran — headless itself died.
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DecompileError.headlessError(Self.tail(detail))
        }
        return try Self.parseOutput(raw, function: function)
    }

    // MARK: - Location

    /// Find `<ghidraDir>/support/analyzeHeadless` under the same roots the
    /// disassembler launcher searches for `ghidraRun`.
    public nonisolated static func locateAnalyzeHeadless(searchRoots: [URL]? = nil,
                                                         fileManager fm: FileManager = .default) -> URL? {
        let roots = searchRoots ?? defaultSearchRoots(fm)
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for entry in entries
            where entry.lastPathComponent.lowercased().hasPrefix("ghidra") {
                // Resolve through symlinks: a very common install shape is a link
                // into ~/Applications (or /opt) pointing at a Homebrew Ghidra, and
                // the URL's `hasDirectoryPath` is `false` for a symlink entry — so
                // use FileManager's symlink-following directory check instead.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let headless = entry.appendingPathComponent("support/analyzeHeadless")
                if fm.isExecutableFile(atPath: headless.path) { return headless }
            }
        }
        return nil
    }

    nonisolated static func defaultSearchRoots(_ fm: FileManager) -> [URL] {
        [URL(fileURLWithPath: "/Applications"),
         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/opt"),
         URL(fileURLWithPath: "/usr/local"),
         fm.homeDirectoryForCurrentUser.appendingPathComponent("Tools")]
    }

    // MARK: - Output parsing (deterministic — unit-tested)

    /// Turn the post-script's output file into a `Decompilation` or a typed
    /// error. The script emits one of: the raw C, or a `DECOMPILE_*:` marker.
    static func parseOutput(_ raw: String, function: String) throws -> Decompilation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("DECOMPILE_NOT_FOUND") {
            throw DecompileError.functionNotFound(function)
        }
        if trimmed.hasPrefix("DECOMPILE_FAILED") || trimmed.hasPrefix("DECOMPILE_ERROR") {
            let msg = trimmed.split(separator: ":", maxSplits: 1)
                .dropFirst().first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "unknown error"
            throw DecompileError.decompileFailed(msg)
        }
        guard !trimmed.isEmpty else {
            throw DecompileError.decompileFailed("Ghidra produced empty output.")
        }
        return Decompilation(function: function, cCode: raw)
    }

    // MARK: - Helpers

    static func cacheSubdir(_ name: String, fm: FileManager) throws -> URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("privacycommand/\(name)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// FNV-1a 64-bit — a small *stable* hash (unlike `Hasher`, whose seed
    /// changes per run) so a binary maps to the same project across launches.
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Last ~1 KB of a long log, for surfacing a useful tail in error text.
    static func tail(_ s: String, _ maxChars: Int = 1000) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t.isEmpty ? "(no output)" : t }
        return "…" + String(t.suffix(maxChars))
    }

    /// Project cache key from the binary's path + size + mtime, so replacing
    /// the file at a path invalidates its analysed project rather than reusing
    /// stale decompilation.
    static func projectKey(for binary: URL, fm: FileManager) -> String {
        let attrs = try? fm.attributesOfItem(atPath: binary.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = Int64((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return stableHash("\(binary.path)|\(size)|\(mtime)")
    }

    /// Run `analyzeHeadless` asynchronously and **cancellably**: if the
    /// awaiting Task is cancelled (the user closes the sheet), the process is
    /// terminated instead of running its multi-minute analysis to completion
    /// in the background. Also enforces a wall-clock `timeout`.
    static func runHeadless(launchPath: String,
                            arguments: [String],
                            timeout: TimeInterval) async throws -> ProcessRunner.SyncResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessRunner.SyncResult, Error>) in
                let collected = HeadlessCollector()
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { collected.appendOut(d) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { collected.appendErr(d) }
                }
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning { process.terminate() }
                }
                process.terminationHandler = { proc in
                    timeoutTask.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: ProcessRunner.SyncResult(
                        exitCode: proc.terminationStatus,
                        stdout: collected.outString(),
                        stderr: collected.errString()))
                }
                do { try process.run() }
                catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Embedded Ghidra post-script

    static let postScriptName = "PCDecompileFunction.java"

    /// Ghidra post-script as a **Java** GhidraScript. Ghidra 11.3+/12 route
    /// `.py` scripts through PyGhidra (CPython), which our headless launch
    /// doesn't enable — so a `.py` script fails with "Ghidra was not started
    /// with PyGhidra." A Java GhidraScript is compiled by Ghidra itself and
    /// works on every version. Receives `<functionName> <outputPath>
    /// [address-hex]`, finds the function (tolerating a leading-underscore
    /// mismatch, falling back to the containing address), decompiles it, and
    /// writes the C — or a `DECOMPILE_*:` marker — to the output path.
    static let postScriptSource = #"""
    // Auto-generated by privacycommand. Decompiles one function to C.
    // Args: <functionName> <outputPath> [address-hex]
    import ghidra.app.script.GhidraScript;
    import ghidra.app.decompiler.DecompInterface;
    import ghidra.app.decompiler.DecompileResults;
    import ghidra.program.model.address.Address;
    import ghidra.program.model.listing.Function;
    import ghidra.program.model.listing.FunctionIterator;
    import ghidra.program.model.listing.FunctionManager;
    import ghidra.util.task.ConsoleTaskMonitor;
    import java.io.FileWriter;
    import java.io.PrintWriter;

    public class PCDecompileFunction extends GhidraScript {
        @Override
        public void run() throws Exception {
            String[] args = getScriptArgs();
            if (args.length < 2) {
                println("PCDecompile: expected <functionName> <outputPath> [address-hex]");
                return;
            }
            String target = args[0];
            String outPath = args[1];
            String addrHex = args.length > 2 ? args[2] : "";

            // Ghidra may store the symbol with or without a leading underscore.
            String alt = target.startsWith("_") ? target.substring(1) : ("_" + target);

            FunctionManager fm = currentProgram.getFunctionManager();
            Function found = null;
            FunctionIterator it = fm.getFunctions(true);
            while (it.hasNext()) {
                Function f = it.next();
                String name = f.getName();
                if (name.equals(target) || name.equals(alt)) { found = f; break; }
            }

            // Fall back to the function containing an address when the symbol
            // isn't in Ghidra's view (stripped / renamed, e.g. FUN_0001abcd).
            if (found == null && !addrHex.isEmpty()) {
                try {
                    Address a = currentProgram.getAddressFactory()
                        .getDefaultAddressSpace().getAddress(Long.parseUnsignedLong(addrHex, 16));
                    found = fm.getFunctionContaining(a);
                } catch (Exception e) { found = null; }
            }

            if (found == null) {
                write(outPath, "DECOMPILE_NOT_FOUND: " + target);
                return;
            }
            DecompInterface decomp = new DecompInterface();
            decomp.openProgram(currentProgram);
            DecompileResults res = decomp.decompileFunction(found, 60, new ConsoleTaskMonitor());
            if (res != null && res.decompileCompleted()) {
                write(outPath, res.getDecompiledFunction().getC());
            } else {
                write(outPath, "DECOMPILE_FAILED: " + (res != null ? res.getErrorMessage() : "no result"));
            }
        }

        private void write(String path, String text) throws Exception {
            PrintWriter w = new PrintWriter(new FileWriter(path));
            w.print(text);
            w.close();
        }
    }
    """#
}

/// Lock-protected stdout/stderr accumulator for `runHeadless` — the readability
/// handlers and the termination handler run on independent Foundation queues,
/// which Swift 6 strict concurrency won't let share a plain `var`.
private final class HeadlessCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func outString() -> String { lock.lock(); defer { lock.unlock() }; return String(data: out, encoding: .utf8) ?? "" }
    func errString() -> String { lock.lock(); defer { lock.unlock() }; return String(data: err, encoding: .utf8) ?? "" }
}
