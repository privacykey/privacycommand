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

    static let dumpScriptName = "PCDumpProgram.py"

    /// Ghidra/Jython post-script. Enumerates every function, filters by scope,
    /// decompiles each to C, and writes one JSON object per line to the output
    /// path — plus a final `{"__meta__": …}` summary. Skips external functions
    /// and thunks (no meaningful body). Reuses one `DecompInterface` so the
    /// analysis cost isn't repaid per function.
    static let dumpScriptSource = """
    # Auto-generated by privacycommand. Dumps decompiled functions to JSON Lines.
    # Args: <outputPath> <scopeKind: namedClasses|everything> <cap:int>
    from ghidra.app.decompiler import DecompInterface
    from ghidra.util.task import ConsoleTaskMonitor
    import json

    args = getScriptArgs()
    if len(args) < 3:
        print("PCDump: expected <outputPath> <scopeKind> <cap>")
    else:
        out_path = str(args[0])
        scope = str(args[1])
        try:
            cap = int(str(args[2]))
        except:
            cap = 1500

        fh = open(out_path, "w")
        try:
            decomp = DecompInterface()
            decomp.openProgram(currentProgram)
            monitor = ConsoleTaskMonitor()
            fm = currentProgram.getFunctionManager()
            it = fm.getFunctions(True)
            count = 0
            truncated = False
            while it.hasNext():
                f = it.next()
                if f.isExternal() or f.isThunk():
                    continue
                ns = f.getParentNamespace()
                is_global = ns.isGlobal()
                if scope == "namedClasses" and is_global:
                    continue
                if count >= cap:
                    truncated = True
                    break
                cls = None if is_global else str(ns.getName(True))
                try:
                    sig = str(f.getPrototypeString(False, False))
                except:
                    sig = None
                entry = str(f.getEntryPoint())
                c_code = ""
                try:
                    res = decomp.decompileFunction(f, 45, monitor)
                    if res is not None and res.decompileCompleted():
                        df = res.getDecompiledFunction()
                        if df is not None:
                            c_code = df.getC()
                except:
                    c_code = ""
                rec = {"class": cls, "function": str(f.getName()),
                       "signature": sig, "entryHex": entry, "c": c_code}
                fh.write(json.dumps(rec))
                fh.write("\\n")
                count += 1
            meta = {"__meta__": True, "truncated": truncated, "functionCount": count}
            fh.write(json.dumps(meta))
            fh.write("\\n")
        except Exception as e:
            try:
                fh.write("DUMP_ERROR: " + str(e) + "\\n")
            except:
                pass
        finally:
            fh.close()
    """
}
