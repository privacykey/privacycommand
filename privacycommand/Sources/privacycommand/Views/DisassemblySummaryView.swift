import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Sheet that runs `objdump -d` (or `otool -tV` as a fallback) on the target
/// binary, feeds the output through `DisassemblyAnalyzer`, and renders a
/// plain-English forensic summary alongside the structured findings.
///
/// **Design principle:** raw assembly is intentionally hidden. Users who
/// want it can still hit "Open in objdump" from the launcher. This view is
/// for *audiences who don't speak `mov`* — it answers "what is this binary
/// asking the OS to do?" rather than "how is it implemented?".
struct DisassemblySummaryView: View {
    let executableURL: URL
    let onClose: () -> Void

    @StateObject private var runner = DisassemblyRunner()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .task { await runner.run(on: executableURL) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Forensic disassembly summary").font(.title2.bold())
                    InfoButton(articleID: "asm-forensic-summary")
                }
                Text(executableURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.escape)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .idle:
            VStack(spacing: 12) {
                ProgressView()
                Text(stageMessage(nil))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .running(let stage):
            VStack(spacing: 12) {
                ProgressView()
                Text(stageMessage(stage))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Couldn't disassemble").font(.headline)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .ready(let summary, let toolUsed):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow(summary, toolUsed: toolUsed)
                    narrativeCard(summary)
                    patternsCard(summary)
                    callsCard(summary)
                    literalsCard(summary)
                }
                .padding()
            }
        }
    }

    private func stageMessage(_ stage: DisassemblyRunner.Stage?) -> String {
        switch stage ?? .pickingTool {
        case .pickingTool:    return "Looking for objdump / otool…"
        case .runningTool(let exec): return "Running \(exec) — this can take a few seconds for large binaries."
        case .analysing:      return "Analysing the disassembly…"
        }
    }

    // MARK: - Sections

    private func statsRow(_ summary: DisassemblyAnalyzer.Summary, toolUsed: String) -> some View {
        HStack(spacing: 16) {
            statBox(value: "\(summary.totalInstructions)", label: "instructions")
            statBox(value: "\(summary.totalFunctions)", label: "functions")
            statBox(value: "\(summary.externalCalls.count)", label: "external symbols")
            statBox(value: "\(summary.detectedPatterns.count)", label: "patterns")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(summary.architecture ?? "—")
                    .font(.caption.monospaced())
                Text("disassembled with \(toolUsed)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func narrativeCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        GroupBox(label: HStack {
            Text("Plain-English narrative")
            InfoButton(articleID: "asm-forensic-summary")
        }) {
            Text(summary.narrative.isEmpty ? "(no narrative produced)" : summary.narrative)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    @ViewBuilder
    private func patternsCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        if !summary.detectedPatterns.isEmpty {
            GroupBox("Detected patterns") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.detectedPatterns) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: confidenceIcon(p.confidence))
                                    .foregroundStyle(confidenceColor(p.confidence))
                                Text(p.title).font(.headline)
                                Text("(\(p.confidence.rawValue) confidence)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if p.kbArticleID != nil {
                                    InfoButton(articleID: p.kbArticleID)
                                }
                                Spacer()
                            }
                            Text(p.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !p.evidence.isEmpty {
                                Text("Evidence: \(p.evidence.joined(separator: ", "))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                        if p.id != summary.detectedPatterns.last?.id { Divider() }
                    }
                }
                .padding(8)
            }
        }
    }

    private func confidenceIcon(_ c: DisassemblyAnalyzer.Pattern.Confidence) -> String {
        switch c {
        case .high:   return "checkmark.seal.fill"
        case .medium: return "questionmark.circle.fill"
        case .low:    return "circle"
        }
    }

    private func confidenceColor(_ c: DisassemblyAnalyzer.Pattern.Confidence) -> Color {
        switch c {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .secondary
        }
    }

    @ViewBuilder
    private func callsCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        if !summary.externalCalls.isEmpty {
            GroupBox("External calls (top 40 by frequency)") {
                let buckets = Dictionary(grouping: summary.externalCalls.prefix(40), by: \.category)
                let order = DisassemblyAnalyzer.Category.allCases.filter { buckets[$0] != nil }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(order, id: \.self) { cat in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(buckets[cat] ?? []) { call in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(call.callCount)×")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 36, alignment: .trailing)
                                        Text(call.symbol)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                        Text("— \(call.humanLabel)")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer()
                                        if call.kbArticleID != nil {
                                            InfoButton(articleID: call.kbArticleID)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 8)
                        } label: {
                            HStack {
                                Text(cat.rawValue).font(.subheadline.bold())
                                Spacer()
                                Text("\(buckets[cat]?.count ?? 0)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func literalsCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        if !summary.stringLiterals.isEmpty {
            GroupBox("Embedded string literals (sample)") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(summary.stringLiterals.prefix(50), id: \.self) { lit in
                        Text(lit)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if summary.stringLiterals.count > 50 {
                        Text("…and \(summary.stringLiterals.count - 50) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }
}

/// Drives the actual subprocess + analysis. Lives outside the view so we
/// can keep the view body declarative.
@MainActor
final class DisassemblyRunner: ObservableObject {

    enum Stage: Equatable {
        case pickingTool
        case runningTool(String)
        case analysing
    }

    enum Phase: Equatable {
        case idle
        case running(Stage?)
        case ready(DisassemblyAnalyzer.Summary, toolUsed: String)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.running(let l), .running(let r)): return l == r
            case (.ready(let l, let lt), .ready(let r, let rt)):
                return lt == rt && l.totalInstructions == r.totalInstructions
                    && l.totalFunctions == r.totalFunctions
                    && l.externalCalls.count == r.externalCalls.count
            case (.failed(let l), .failed(let r)): return l == r
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle

    /// Maximum bytes of disassembly text we keep. ~4 MB is enough for the
    /// most-used parts of even a large framework and stays comfortably
    /// inside main-thread analysis time.
    let maxOutputBytes = 4 * 1024 * 1024

    func run(on executable: URL) async {
        phase = .running(.pickingTool)
        guard let tool = await Self.pickTool() else {
            phase = .failed("Neither `objdump` nor `otool` were found on disk. Install Xcode Command Line Tools (`xcode-select --install`) and try again.")
            return
        }
        phase = .running(.runningTool(tool.label))

        do {
            let raw = try await Self.runDisassembler(tool: tool, target: executable, maxBytes: maxOutputBytes)
            phase = .running(.analysing)
            // The analyzer call is intentionally synchronous on the main
            // actor — typical inputs (a few MB of text) finish in well under
            // 100 ms. If we ever need to support multi-million-line dumps
            // we'd hop to a Task.detached here.
            let summary = DisassemblyAnalyzer.analyse(disassembly: raw)
            phase = .ready(summary, toolUsed: tool.label)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Tool picking

    struct ToolChoice {
        let url: URL
        /// Arguments BEFORE the binary path.
        let args: [String]
        let label: String
    }

    static func pickTool() async -> ToolChoice? {
        let fm = FileManager.default
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                     "/Library/Developer/CommandLineTools/usr/bin"]
        // Prefer objdump (LLVM, richer output) → fallback to otool.
        for root in roots {
            let p = "\(root)/objdump"
            if fm.isExecutableFile(atPath: p) {
                return ToolChoice(url: URL(fileURLWithPath: p),
                                  args: ["-d", "--no-show-raw-insn", "--macho"],
                                  label: "objdump -d --macho")
            }
        }
        for root in roots {
            let p = "\(root)/otool"
            if fm.isExecutableFile(atPath: p) {
                return ToolChoice(url: URL(fileURLWithPath: p),
                                  args: ["-tV"],
                                  label: "otool -tV")
            }
        }
        return nil
    }

    // MARK: - Subprocess

    enum RunnerError: LocalizedError {
        case nonZeroExit(Int32, String)
        case timedOut
        case empty

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code, let stderr):
                return "Disassembler exited with status \(code).\n\(stderr)"
            case .timedOut:
                return "Disassembler took longer than 30 seconds and was cancelled. The binary may be unusually large; try `otool -tV` directly in Terminal."
            case .empty:
                return "Disassembler produced no output."
            }
        }
    }

    static func runDisassembler(tool: ToolChoice, target: URL, maxBytes: Int) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let task = Process()
            task.executableURL = tool.url
            task.arguments = tool.args + [target.path]
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr

            // Capture stdout in chunks so we can cap memory usage cleanly
            // on very large binaries instead of buffering hundreds of MB.
            // Wrap the buffer in a class with internal locking — Swift 6
            // strict-concurrency rejects sharing a `var` across two
            // independently-running closures (the readability handler runs
            // on a Foundation queue; the termination handler on another).
            let collector = ByteCollector(cap: maxBytes)
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                collector.append(chunk)
            }

            // 30s wall-clock timeout: kills the process if it hangs (which
            // can happen when objdump trips over weird sections).
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if task.isRunning { task.terminate() }
            }

            task.terminationHandler = { proc in
                timeoutTask.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                let errData: Data = ((try? stderr.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                let outStr = String(data: collector.snapshot(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 || !outStr.isEmpty {
                    if outStr.isEmpty { cont.resume(throwing: RunnerError.empty); return }
                    cont.resume(returning: outStr)
                } else {
                    cont.resume(throwing: RunnerError.nonZeroExit(proc.terminationStatus, errStr))
                }
            }

            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Lock-protected, capped byte buffer. Used by `DisassemblyRunner` to share
/// stdout bytes between the `readabilityHandler` (writer) and the
/// `terminationHandler` (reader) closures, which Foundation invokes on
/// independent queues. A plain `var Data()` would compile under Swift 5
/// but is rejected by Swift 6 strict concurrency.
fileprivate final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count >= cap { return }
        data.append(chunk.prefix(cap - data.count))
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
