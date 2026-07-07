import Foundation

/// Drives **Ghidra headless** to decompile a *whole binary* — every function
/// in a named class (or every function, capped) — into a browsable
/// `DecompilationIndex`. This is the "see how the app works" companion to
/// `GhidraDecompiler`, which decompiles one function on demand.
///
/// **Shares the single-function decompiler's project cache.** It reuses
/// `GhidraDecompiler`'s `locateAnalyzeHeadless`, `projectKey`, `cacheSubdir`,
/// and `runHeadless`, and opens the same `pc_<projectKey>.gpr` project — so the
/// expensive Ghidra auto-analysis is paid once and shared between the two
/// features (whichever runs first imports + analyses; the other reuses it with
/// `-noanalysis`).
///
/// One Ghidra run decompiles everything post-analysis (bounded by the scope's
/// cap), which is far cheaper than paying JVM start-up per class. The result is
/// cached by `DecompilationIndexStore` keyed by `projectKey` + scope, so
/// re-opening an app is instant.
public actor GhidraProgramDump {

    public init() {}

    public enum DumpError: LocalizedError, Equatable {
        case ghidraNotInstalled
        case headlessError(String)
        case dumpFailed(String)

        public var errorDescription: String? {
            switch self {
            case .ghidraNotInstalled:
                return "Ghidra isn't installed. Install Ghidra (e.g. unzip a release into /Applications) and try again — the app looks for `support/analyzeHeadless` inside any `ghidra*` folder under /Applications, ~/Applications, /opt, /usr/local, or ~/Tools."
            case .headlessError(let msg):
                return "Ghidra headless failed: \(msg)"
            case .dumpFailed(let msg):
                return "Ghidra couldn't dump the program: \(msg)"
            }
        }
    }

    /// Mirrors `GhidraDecompiler.isAvailable` — should we offer the
    /// "Decompile whole app" action at all?
    public nonisolated static func isAvailable(searchRoots: [URL]? = nil,
                                               fileManager: FileManager = .default) -> Bool {
        GhidraDecompiler.locateAnalyzeHeadless(searchRoots: searchRoots, fileManager: fileManager) != nil
    }

    /// Cache identity for a (binary, scope) pair — the same `projectKey` the
    /// single-function decompiler uses, plus the scope. `DecompilationIndexStore`
    /// keys on this.
    public nonisolated static func cacheKey(for binary: URL, scope: DecompileScope,
                                            fileManager: FileManager = .default) -> String {
        "pc_\(GhidraDecompiler.projectKey(for: binary, fm: fileManager))_\(scope.key)"
    }

    /// Decompile `binary` and return a `DecompilationIndex`. Pure compute (no
    /// cache read/write) — the caller consults `DecompilationIndexStore`. First
    /// run for a binary pays full auto-analysis; later runs reuse the project.
    public func dump(binary: URL,
                     scope: DecompileScope = .namedClasses,
                     timeout: TimeInterval = 1800) async throws -> DecompilationIndex {
        guard let headless = GhidraDecompiler.locateAnalyzeHeadless() else {
            throw DumpError.ghidraNotInstalled
        }
        let fm = FileManager.default

        let projectsDir = try GhidraDecompiler.cacheSubdir("ghidra-projects", fm: fm)
        let scriptsDir  = try GhidraDecompiler.cacheSubdir("ghidra-scripts", fm: fm)
        let outDir      = try GhidraDecompiler.cacheSubdir("ghidra-out", fm: fm)

        let projectName = "pc_\(GhidraDecompiler.projectKey(for: binary, fm: fm))"
        let projectFile = projectsDir.appendingPathComponent("\(projectName).gpr")
        let alreadyImported = fm.fileExists(atPath: projectFile.path)

        let scriptURL = scriptsDir.appendingPathComponent(Self.dumpScriptName)
        try Self.dumpScriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)

        let outFile = outDir.appendingPathComponent("\(projectName)_dump_\(scope.key).jsonl")
        try? fm.removeItem(at: outFile)

        var args = [projectsDir.path, projectName]
        if alreadyImported {
            args += ["-process", binary.lastPathComponent, "-noanalysis"]
        } else {
            args += ["-import", binary.path]
        }
        args += ["-scriptPath", scriptsDir.path,
                 "-postScript", Self.dumpScriptName,
                 outFile.path, scope.kind.rawValue, String(scope.cap)]

        let result = try await GhidraDecompiler.runHeadless(launchPath: headless.path,
                                                            arguments: args,
                                                            timeout: timeout)

        guard let raw = try? String(contentsOf: outFile, encoding: .utf8) else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DumpError.headlessError(GhidraDecompiler.tail(detail))
        }
        return try Self.parse(jsonl: raw, binaryPath: binary.path, scope: scope)
    }

    // MARK: - Parsing (deterministic — unit-tested)

    /// Parse the post-script's JSON-Lines output into a `DecompilationIndex`.
    /// Each line is either a function object, a `{"__meta__": …}` summary line,
    /// or a `DUMP_ERROR:` marker. Unparseable lines (stray analyzer noise) are
    /// skipped rather than failing the whole dump.
    static func parse(jsonl: String, binaryPath: String, scope: DecompileScope) throws -> DecompilationIndex {
        var functionsByClass: [String: [DecompiledFunction]] = [:]
        var order: [String] = []
        var truncated = false
        var count = 0

        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("DUMP_ERROR") {
                let msg = line.split(separator: ":", maxSplits: 1)
                    .dropFirst().first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? "unknown error"
                throw DumpError.dumpFailed(msg)
            }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if obj["__meta__"] != nil {
                truncated = (obj["truncated"] as? Bool) ?? truncated
                continue
            }
            guard let fname = obj["function"] as? String,
                  let cCode = obj["c"] as? String else { continue }

            let className = obj["class"] as? String
            let fn = DecompiledFunction(
                className: className,
                name: fname,
                signature: obj["signature"] as? String,
                entryHex: obj["entryHex"] as? String,
                cCode: cCode)

            let key = className ?? "(global)"
            if functionsByClass[key] == nil { order.append(key) }
            functionsByClass[key, default: []].append(fn)
            count += 1
        }

        let classes = order
            .map { DecompiledClass(name: $0, functions: functionsByClass[$0] ?? []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let note = truncated ? "Capped at \(scope.cap) functions — some were not decompiled." : nil
        return DecompilationIndex(
            source: .ghidra,
            binaryPath: binaryPath,
            scope: scope.key,
            classes: classes,
            functionCount: count,
            truncated: truncated,
            note: note)
    }

    // MARK: - Embedded Ghidra post-script

    static let dumpScriptName = "PCDumpProgram.java"

    /// Ghidra post-script as a **Java** GhidraScript (not Python). Ghidra 11.3+
    /// / 12.x route `.py` scripts through PyGhidra (CPython), which needs a
    /// separate `pip install pyghidra` and a PyGhidra-enabled launch our
    /// headless invocation doesn't do — so a `.py` script fails with "Ghidra was
    /// not started with PyGhidra." A Java GhidraScript is compiled by Ghidra
    /// itself and works on every version, no Python required.
    ///
    /// Enumerates every function, filters by scope, decompiles each to C, and
    /// writes one JSON object per line plus a final `{"__meta__": …}` summary.
    /// Skips external functions and thunks. Reuses one `DecompInterface`.
    static let dumpScriptSource = #"""
    // Auto-generated by privacycommand. Dumps decompiled functions to JSON Lines.
    // Args: <outputPath> <scopeKind: namedClasses|everything> <cap:int>
    import ghidra.app.script.GhidraScript;
    import ghidra.app.decompiler.DecompInterface;
    import ghidra.app.decompiler.DecompileResults;
    import ghidra.app.decompiler.DecompiledFunction;
    import ghidra.program.model.listing.Function;
    import ghidra.program.model.listing.FunctionIterator;
    import ghidra.program.model.listing.FunctionManager;
    import ghidra.program.model.symbol.Namespace;
    import ghidra.util.task.ConsoleTaskMonitor;
    import java.io.FileWriter;
    import java.io.PrintWriter;

    public class PCDumpProgram extends GhidraScript {
        @Override
        public void run() throws Exception {
            String[] args = getScriptArgs();
            if (args.length < 3) {
                println("PCDump: expected <outputPath> <scopeKind> <cap>");
                return;
            }
            String outPath = args[0];
            String scope = args[1];
            int cap;
            try { cap = Integer.parseInt(args[2]); } catch (Exception e) { cap = 1500; }

            PrintWriter fh = null;
            try {
                fh = new PrintWriter(new FileWriter(outPath));
                DecompInterface decomp = new DecompInterface();
                decomp.openProgram(currentProgram);
                ConsoleTaskMonitor monitor = new ConsoleTaskMonitor();
                FunctionManager fm = currentProgram.getFunctionManager();
                FunctionIterator it = fm.getFunctions(true);
                int count = 0;
                boolean truncated = false;
                while (it.hasNext()) {
                    Function f = it.next();
                    if (f.isExternal() || f.isThunk()) continue;
                    Namespace ns = f.getParentNamespace();
                    boolean isGlobal = ns.isGlobal();
                    if (scope.equals("namedClasses") && isGlobal) continue;
                    if (count >= cap) { truncated = true; break; }
                    String cls = isGlobal ? null : ns.getName(true);
                    String sig;
                    try { sig = f.getPrototypeString(false, false); } catch (Exception e) { sig = null; }
                    String entry = f.getEntryPoint().toString();
                    String cCode = "";
                    try {
                        DecompileResults res = decomp.decompileFunction(f, 45, monitor);
                        if (res != null && res.decompileCompleted()) {
                            DecompiledFunction df = res.getDecompiledFunction();
                            if (df != null) cCode = df.getC();
                        }
                    } catch (Exception e) { cCode = ""; }
                    fh.println(obj(cls, f.getName(), sig, entry, cCode));
                    count++;
                }
                fh.println("{\"__meta__\": true, \"truncated\": " + (truncated ? "true" : "false")
                    + ", \"functionCount\": " + count + "}");
            } catch (Exception e) {
                if (fh != null) {
                    fh.println("DUMP_ERROR: " + e.getMessage());
                } else {
                    try {
                        PrintWriter ew = new PrintWriter(new FileWriter(outPath));
                        ew.println("DUMP_ERROR: " + e.getMessage());
                        ew.close();
                    } catch (Exception ignore) {}
                }
            } finally {
                if (fh != null) fh.close();
            }
        }

        // Build one JSON object; null class/signature emit JSON null.
        private String obj(String cls, String func, String sig, String entry, String c) {
            return "{\"class\": " + val(cls)
                + ", \"function\": " + val(func)
                + ", \"signature\": " + val(sig)
                + ", \"entryHex\": " + val(entry)
                + ", \"c\": " + val(c) + "}";
        }

        // Minimal JSON string encoder with proper escaping.
        private String val(String s) {
            if (s == null) return "null";
            StringBuilder sb = new StringBuilder("\"");
            for (int i = 0; i < s.length(); i++) {
                char ch = s.charAt(i);
                switch (ch) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
                        else sb.append(ch);
                }
            }
            sb.append("\"");
            return sb.toString();
        }
    }
    """#
}
