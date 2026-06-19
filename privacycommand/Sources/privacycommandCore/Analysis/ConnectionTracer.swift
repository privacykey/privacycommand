import Foundation

/// **Tier 2 runtime attribution.** Captures a userspace backtrace at the exact
/// moment a process opens a connection, so a network event can be traced to the
/// function that initiated it — the "this code made the call to cloudflare"
/// answer that static analysis can only approximate.
///
/// How: it compiles a tiny **DYLD interposer** dylib (embedded C, built with
/// `clang` at runtime — we can't ship a prebuilt one for every arch/OS) that
/// hooks `connect()` and `getaddrinfo()`, and relaunches the target with
/// `DYLD_INSERT_LIBRARIES` pointed at it. Each intercepted call writes its
/// arguments + `backtrace_symbols()` output to a log we then parse.
///
/// **Hard limits (be honest about these):**
///   * Only works on binaries you can relaunch *and* that don't use the
///     hardened runtime — macOS ignores `DYLD_INSERT_LIBRARIES` for
///     hardened/SIP-protected/platform binaries. So this targets unsigned /
///     ad-hoc tools and your own builds, not notarized App Store apps.
///   * For JIT/interpreted runtimes (Node, Electron, the JVM) the captured
///     native frames are the *runtime's* (libuv/V8), not the script that
///     triggered the call.
public actor ConnectionTracer {

    public init() {}

    // MARK: - Public types

    public struct TracedConnection: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case connect, getaddrinfo }
        public let pid: Int32
        public let kind: Kind
        /// For `connect`: `host:port` (or `[ipv6]:port`). For `getaddrinfo`:
        /// the hostname being resolved.
        public let detail: String
        /// The captured backtrace, frame 0 closest to the syscall.
        public let stack: [StackFrame]

        public init(pid: Int32, kind: Kind, detail: String, stack: [StackFrame]) {
            self.pid = pid; self.kind = kind; self.detail = detail; self.stack = stack
        }
    }

    public enum TraceError: LocalizedError, Equatable {
        case clangMissing
        case compileFailed(String)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .clangMissing:
                return "The C toolchain (clang) isn't available. Install the Xcode Command Line Tools (`xcode-select --install`)."
            case .compileFailed(let m):
                return "Couldn't build the connection interposer: \(m)"
            case .launchFailed(let m):
                return "Couldn't launch the target under tracing: \(m)"
            }
        }
    }

    /// True when we can build the interposer (clang present).
    public nonisolated static func isSupported(fileManager: FileManager = .default) -> Bool {
        clangPath(fileManager: fileManager) != nil
    }

    // MARK: - Tracing

    /// Run `executable` (with `arguments`) under the interposer and return the
    /// connections it opened, each with a symbolicated backtrace. The process
    /// is allowed up to `timeout` seconds, then terminated.
    public func trace(executable: URL,
                      arguments: [String] = [],
                      timeout: TimeInterval = 20) async throws -> [TracedConnection] {
        let dylib = try Self.compileInterposer()
        let fm = FileManager.default
        let logURL = fm.temporaryDirectory
            .appendingPathComponent("pc-trace-\(UUID().uuidString).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        defer { try? fm.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = dylib.path
        env["PC_TRACE_LOG"] = logURL.path
        process.environment = env
        process.standardOutput = Pipe()    // discard child stdout/stderr
        process.standardError = Pipe()

        do { try process.run() }
        catch { throw TraceError.launchFailed("\(error)") }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return Self.parseLog(text)
    }

    /// Map a traced `connect` to a `NetworkEvent` (with its call stack) so it
    /// can be merged into the timeline. Returns nil for non-`connect` events or
    /// unparseable endpoints.
    public nonisolated static func networkEvent(from c: TracedConnection,
                                                processName: String,
                                                processPath: String?,
                                                now: Date = Date()) -> NetworkEvent? {
        guard c.kind == .connect, let ep = parseEndpoint(c.detail) else { return nil }
        return NetworkEvent(
            firstSeen: now, lastSeen: now,
            pid: c.pid, processName: processName, processPath: processPath,
            netProto: .tcp,
            localEndpoint: .init(address: "0.0.0.0", port: 0),
            remoteEndpoint: .init(address: ep.host, port: ep.port),
            remoteHostname: nil,
            bytesSent: 0, bytesReceived: 0, tlsSNI: nil, payloadSamples: [],
            risk: .expected, callStack: c.stack)
    }

    // MARK: - Log parsing (deterministic — unit-tested)

    /// Parse the interposer's log into traced connections. Format per event:
    ///   `EVENT\t<pid>\t<connect|getaddrinfo>\t<detail>`
    ///   `FRAME\t<backtrace_symbols line>`  (repeated)
    ///   `END`
    static func parseLog(_ text: String) -> [TracedConnection] {
        var out: [TracedConnection] = []
        var pid: Int32 = 0
        var kind: TracedConnection.Kind? = nil
        var detail = ""
        var frames: [StackFrame] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("EVENT\t") {
                let parts = line.components(separatedBy: "\t")
                // EVENT, pid, kind, detail
                pid = parts.count > 1 ? (Int32(parts[1]) ?? 0) : 0
                kind = parts.count > 2 ? TracedConnection.Kind(rawValue: parts[2]) : nil
                detail = parts.count > 3 ? parts[3] : ""
                frames = []
            } else if line.hasPrefix("FRAME\t") {
                let body = String(line.dropFirst("FRAME\t".count))
                if let f = parseFrame(body, index: frames.count) { frames.append(f) }
            } else if line == "END", let k = kind {
                out.append(TracedConnection(pid: pid, kind: k, detail: detail, stack: frames))
                kind = nil; frames = []
            }
        }
        return out
    }

    /// Parse one `backtrace_symbols()` line, e.g.
    /// `2   myprog   0x000000010abcd1f0 main + 64`
    /// into a `StackFrame` (offset normalised to hex). `index` overrides the
    /// frame's own counter so callers control ordering.
    static func parseFrame(_ line: String, index: Int) -> StackFrame? {
        let re = try? NSRegularExpression(
            pattern: #"^\s*\d+\s+(.+?)\s+0x[0-9a-fA-F]+\s+(.+?)\s+\+\s+(\d+)\s*$"#)
        let r = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = re?.firstMatch(in: line, range: r), m.numberOfRanges == 4,
              let mod = Range(m.range(at: 1), in: line),
              let sym = Range(m.range(at: 2), in: line),
              let off = Range(m.range(at: 3), in: line) else { return nil }
        let offHex = String(Int(line[off]) ?? 0, radix: 16)
        return StackFrame(index: index,
                          module: String(line[mod]),
                          symbol: String(line[sym]),
                          offset: offHex)
    }

    /// Parse `host:port` / `[ipv6]:port`.
    static func parseEndpoint(_ s: String) -> (host: String, port: UInt16)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            guard let close = t.firstIndex(of: "]") else { return nil }
            let host = String(t[t.index(after: t.startIndex)..<close])
            let after = t[t.index(after: close)...]
            guard after.hasPrefix(":"), let port = UInt16(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = t.lastIndex(of: ":"), let port = UInt16(t[t.index(after: colon)...]) else { return nil }
        return (String(t[..<colon]), port)
    }

    // MARK: - Interposer build

    static func compileInterposer() throws -> URL {
        guard let clang = clangPath() else { throw TraceError.clangMissing }
        let fm = FileManager.default
        let dir = try cacheDir(fm)
        let src = dir.appendingPathComponent("pc_connect_tracer.c")
        let dylib = dir.appendingPathComponent("pc_connect_tracer.dylib")
        try interposerSource.write(to: src, atomically: true, encoding: .utf8)
        // Always (re)compile — the source is small and embedding it in the app
        // means a stale cached dylib could outlive a source change.
        let r = ProcessRunner.runSync(
            launchPath: clang,
            arguments: ["-dynamiclib", "-O2", "-o", dylib.path, src.path],
            timeout: 60)
        guard r.success, fm.fileExists(atPath: dylib.path) else {
            throw TraceError.compileFailed(r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        return dylib
    }

    nonisolated static func clangPath(fileManager fm: FileManager = .default) -> String? {
        for p in ["/usr/bin/clang", "/opt/homebrew/opt/llvm/bin/clang", "/usr/local/bin/clang"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static func cacheDir(_ fm: FileManager) throws -> URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("privacycommand/tracer", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Embedded interposer source

    /// DYLD interposer. Calling `connect`/`getaddrinfo` by name inside the
    /// replacement reaches the real function — dyld does not apply an interpose
    /// to references within the image that defines it, so there's no recursion.
    static let interposerSource = """
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <execinfo.h>
    #include <pthread.h>
    #include <unistd.h>
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <netdb.h>

    #define DYLD_INTERPOSE(_replacement,_replacee) \\
      __attribute__((used)) static struct { const void* replacement; const void* replacee; } \\
      _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \\
      { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

    static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
    static FILE* g_log = NULL;

    static FILE* trace_log(void) {
      if (g_log) return g_log;
      const char* p = getenv("PC_TRACE_LOG");
      if (!p) return NULL;
      g_log = fopen(p, "a");
      return g_log;
    }

    static void emit(const char* event, const char* detail) {
      FILE* f = trace_log();
      if (!f) return;
      void* frames[64];
      int n = backtrace(frames, 64);
      char** syms = backtrace_symbols(frames, n);
      pthread_mutex_lock(&g_lock);
      fprintf(f, "EVENT\\t%d\\t%s\\t%s\\n", getpid(), event, detail ? detail : "");
      /* skip frame 0 (emit) and 1 (the interposed wrapper) */
      for (int i = 2; i < n; i++) {
        fprintf(f, "FRAME\\t%s\\n", syms ? syms[i] : "?");
      }
      fprintf(f, "END\\n");
      fflush(f);
      pthread_mutex_unlock(&g_lock);
      if (syms) free(syms);
    }

    int pc_connect(int s, const struct sockaddr* addr, socklen_t len) {
      char detail[300]; detail[0] = 0;
      if (addr && addr->sa_family == AF_INET) {
        const struct sockaddr_in* a = (const struct sockaddr_in*)addr;
        char ip[INET_ADDRSTRLEN]; ip[0] = 0;
        inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
        snprintf(detail, sizeof(detail), "%s:%d", ip, ntohs(a->sin_port));
      } else if (addr && addr->sa_family == AF_INET6) {
        const struct sockaddr_in6* a = (const struct sockaddr_in6*)addr;
        char ip[INET6_ADDRSTRLEN]; ip[0] = 0;
        inet_ntop(AF_INET6, &a->sin6_addr, ip, sizeof(ip));
        snprintf(detail, sizeof(detail), "[%s]:%d", ip, ntohs(a->sin6_port));
      }
      emit("connect", detail);
      return connect(s, addr, len);
    }
    DYLD_INTERPOSE(pc_connect, connect)

    int pc_getaddrinfo(const char* node, const char* service,
                       const struct addrinfo* hints, struct addrinfo** res) {
      emit("getaddrinfo", node ? node : "");
      return getaddrinfo(node, service, hints, res);
    }
    DYLD_INTERPOSE(pc_getaddrinfo, getaddrinfo)
    """
}
