import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Plain-English forensic summary of a Mach-O binary.
///
/// **Design principle:** the summary is built from *structured facts that are
/// always readable* — the binary's import table, its linked libraries, its
/// embedded strings, and its Mach-O header (see `BinaryCapabilityAnalyzer`).
/// It answers "what is this binary asking the OS to do?" without depending on
/// a full text disassembly, which is fragile (format churns between toolchain
/// versions), slow, and impossible on encrypted App Store binaries.
///
/// A raw `objdump`/`otool` disassembly, when one is installed and succeeds, is
/// layered on top as *optional enrichment* (instruction counts, per-function
/// network call sites, and — with Ghidra installed — a Decompile affordance on
/// each network call site). Its absence or failure is a footnote, never the
/// "Couldn't disassemble" dead end the previous version showed.
struct DisassemblySummaryView: View {
    let executableURL: URL
    let onClose: () -> Void

    @StateObject private var runner = ForensicSummaryRunner()
    /// Whether a usable Ghidra `analyzeHeadless` was found — gates the
    /// per-function "Decompile" affordance so we never show a dead button.
    @State private var ghidraAvailable = false
    /// The function the user asked to decompile, driving the sheet.
    @State private var decompileTarget: DecompileTarget?

    /// A function (of `executableURL`) to decompile in the Ghidra sheet.
    private struct DecompileTarget: Identifiable {
        let id = UUID()
        let function: String
        let address: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .task { await runner.run(on: executableURL) }
        .task { ghidraAvailable = GhidraDecompiler.isAvailable() }
        .sheet(item: $decompileTarget) { target in
            GhidraDecompileSheet(binary: executableURL,
                                 function: target.function,
                                 address: target.address)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Forensic summary").font(.title2.bold())
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
        case .idle, .running:
            VStack(spacing: 12) {
                ProgressView()
                Text(runner.phase == .idle ? "Reading the binary…" : "Analysing capabilities…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready(let report):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsRow(report)
                    narrativeCard(report)
                    linkedCapabilitiesCard(report)
                    patternsCard(report.patterns)
                    importedCallsCard(report)
                    networkLiteralsCard(report)
                    disassemblyEnrichmentCard()
                }
                .padding()
            }
        }
    }

    // MARK: - Stats

    private func statsRow(_ r: BinaryCapabilityAnalyzer.Report) -> some View {
        HStack(spacing: 16) {
            statBox(value: "\(r.linkedLibraryCount)", label: "linked libraries")
            statBox(value: "\(r.importedSymbolCount)", label: "imported symbols")
            statBox(value: "\(r.linkedCapabilities.count)", label: "capabilities")
            statBox(value: "\(r.patterns.count)", label: "patterns")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(r.architectures.isEmpty ? "—" : r.architectures.joined(separator: " · "))
                    .font(.caption.monospaced())
                Text(fidelityNote(r))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fidelityNote(_ r: BinaryCapabilityAnalyzer.Report) -> String {
        if r.isEncrypted { return "encrypted — header-only" }
        if r.isStripped  { return "stripped symbols" }
        return "from import table"
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

    // MARK: - Narrative

    private func narrativeCard(_ r: BinaryCapabilityAnalyzer.Report) -> some View {
        GroupBox(label: HStack {
            Text("What this binary can do")
            InfoButton(articleID: "asm-forensic-summary")
        }) {
            Text(r.narrative.isEmpty ? "(no narrative produced)" : r.narrative)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    // MARK: - Linked capabilities

    @ViewBuilder
    private func linkedCapabilitiesCard(_ r: BinaryCapabilityAnalyzer.Report) -> some View {
        if !r.linkedCapabilities.isEmpty {
            GroupBox(label: Label("Capabilities (from linked frameworks)", systemImage: "shippingbox")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(r.linkedCapabilities) { cap in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: cap.privacySensitive ? "exclamationmark.shield.fill" : "puzzlepiece.extension")
                                    .foregroundStyle(cap.privacySensitive ? .orange : .secondary)
                                Text(cap.title).font(.headline)
                                if cap.kbArticleID != nil { InfoButton(articleID: cap.kbArticleID) }
                                Spacer()
                            }
                            Text(cap.detail)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Links: \(cap.evidence.joined(separator: ", "))")
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        if cap.id != r.linkedCapabilities.last?.id { Divider() }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Patterns

    @ViewBuilder
    private func patternsCard(_ patterns: [DisassemblyAnalyzer.Pattern]) -> some View {
        if !patterns.isEmpty {
            GroupBox("Detected patterns") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(patterns) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: confidenceIcon(p.confidence))
                                    .foregroundStyle(confidenceColor(p.confidence))
                                Text(p.title).font(.headline)
                                Text("(\(p.confidence.rawValue) confidence)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if p.kbArticleID != nil { InfoButton(articleID: p.kbArticleID) }
                                Spacer()
                            }
                            Text(p.summary)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !p.evidence.isEmpty {
                                Text("Evidence: \(p.evidence.joined(separator: ", "))")
                                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                        if p.id != patterns.last?.id { Divider() }
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

    // MARK: - Imported calls

    @ViewBuilder
    private func importedCallsCard(_ r: BinaryCapabilityAnalyzer.Report) -> some View {
        if !r.importedCalls.isEmpty {
            GroupBox(label: HStack {
                Text("Notable imported functions")
                Text("(\(r.importedCalls.count) recognised)")
                    .font(.caption).foregroundStyle(.secondary)
            }) {
                let buckets = Dictionary(grouping: r.importedCalls, by: \.category)
                let order = DisassemblyAnalyzer.Category.allCases.filter { buckets[$0] != nil }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(order, id: \.self) { cat in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(buckets[cat] ?? []) { call in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(call.symbol)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text("— \(call.humanLabel)")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail)
                                        Spacer()
                                        if call.kbArticleID != nil { InfoButton(articleID: call.kbArticleID) }
                                    }
                                }
                            }
                            .padding(.leading, 8)
                        } label: {
                            HStack {
                                Text(cat.rawValue).font(.subheadline.bold())
                                Spacer()
                                Text("\(buckets[cat]?.count ?? 0)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Network destinations (string literals)

    @ViewBuilder
    private func networkLiteralsCard(_ r: BinaryCapabilityAnalyzer.Report) -> some View {
        if !r.urls.isEmpty || !r.domains.isEmpty {
            GroupBox(label: Label("Embedded URLs & domains", systemImage: "link")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hostnames and URLs found in the binary's strings — candidate network destinations, not proof any were contacted.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !r.urls.isEmpty {
                        literalList(title: "URLs", items: r.urls)
                    }
                    if !r.domains.isEmpty {
                        literalList(title: "Domains", items: r.domains)
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func literalList(title: String, items: [String]) -> some View {
        DisclosureGroup("\(title) (\(items.count))") {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(items.prefix(60), id: \.self) { s in
                    Text(s).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if items.count > 60 {
                    Text("…and \(items.count - 60) more").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .font(.callout)
    }

    // MARK: - Optional disassembly enrichment

    @ViewBuilder
    private func disassemblyEnrichmentCard() -> some View {
        GroupBox(label: Label("Instruction-level disassembly", systemImage: "chevron.left.forwardslash.chevron.right")) {
            VStack(alignment: .leading, spacing: 6) {
                switch runner.disassembly {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Running objdump / otool in the background…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .ready(let summary, let tool):
                    HStack(spacing: 16) {
                        statBox(value: "\(summary.totalInstructions)", label: "instructions")
                        statBox(value: "\(summary.totalFunctions)", label: "functions")
                        statBox(value: "\(summary.externalCalls.count)", label: "call symbols")
                        statBox(value: "\(summary.networkCallSites.count)", label: "network sites")
                    }
                    Text("Disassembled with \(tool). This is supplementary detail; the summary above stands on its own.")
                        .font(.caption2).foregroundStyle(.tertiary)
                    networkCallSitesCard(summary)
                    literalsCard(summary)
                case .unavailable(let why):
                    Text(why)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .idle:
                    EmptyView()
                }
            }
            .padding(8)
        }
    }

    /// Per-function networking call sites, each with a Ghidra "Decompile"
    /// affordance when a headless Ghidra is installed. objdump `--macho`
    /// doesn't emit function labels, so this typically populates only from the
    /// `otool -tV` fallback — but when present it's the bridge to decompilation.
    @ViewBuilder
    private func networkCallSitesCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        if !summary.networkCallSites.isEmpty {
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Label("Outbound network call sites", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.bold())
                InfoButton(articleID: "asm-network-call-sites")
            }
            Text("Functions containing code capable of opening outbound connections — a **static capability** map, not proof a specific request came from here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !ghidraAvailable {
                Label("Install Ghidra to decompile any of these functions to C. The app looks for `support/analyzeHeadless` in any `ghidra*` folder under /Applications, ~/Applications, /opt, /usr/local, or ~/Tools.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(summary.networkCallSites.prefix(100)) { site in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(site.function)
                            .font(.callout.monospaced().bold())
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        if let addr = site.address {
                            Text("0x\(addr)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        if ghidraAvailable {
                            Button {
                                decompileTarget = DecompileTarget(function: site.function,
                                                                  address: site.address)
                            } label: {
                                Label("Decompile", systemImage: "curlybraces")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Decompile \(site.function) to C with Ghidra")
                        }
                    }
                    Text(site.calls.map { $0.callCount > 1 ? "\($0.symbol) ×\($0.callCount)" : $0.symbol }
                        .joined(separator: "  ·  "))
                        .font(.caption2.monospaced()).foregroundStyle(.blue)
                    if !site.hostHints.isEmpty {
                        Text("Nearby literals: \(site.hostHints.prefix(5).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .truncationMode(.tail).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
                if site.id != summary.networkCallSites.prefix(100).last?.id { Divider() }
            }
            if summary.networkCallSites.count > 100 {
                Text("…and \(summary.networkCallSites.count - 100) more functions")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func literalsCard(_ summary: DisassemblyAnalyzer.Summary) -> some View {
        if !summary.stringLiterals.isEmpty {
            Divider().padding(.vertical, 2)
            DisclosureGroup("Embedded string literals from disassembly (\(summary.stringLiterals.count))") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(summary.stringLiterals.prefix(50), id: \.self) { lit in
                        Text(lit)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    if summary.stringLiterals.count > 50 {
                        Text("…and \(summary.stringLiterals.count - 50) more")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .font(.caption)
        }
    }
}

// MARK: - Runner

/// Drives the analysis. The primary capability `Report` is produced first and
/// fast (pure Mach-O parsing); an optional disassembly pass then fills in the
/// enrichment section without blocking the main content.
@MainActor
final class ForensicSummaryRunner: ObservableObject {

    // Equatable is auto-synthesised — `Report` and `Summary` are both
    // `Hashable`, so the compiler compares every field. (A partial hand-rolled
    // `==` would silently treat two differing reports as equal.)
    enum Phase: Equatable {
        case idle
        case running
        case ready(BinaryCapabilityAnalyzer.Report)
    }

    enum Disassembly: Equatable {
        case idle
        case running
        case ready(DisassemblyAnalyzer.Summary, tool: String)
        case unavailable(String)
    }

    @Published var phase: Phase = .idle
    @Published var disassembly: Disassembly = .idle

    /// Cap on disassembly text we keep (~4 MB). The capability report does
    /// not depend on this — only the optional enrichment does.
    private let maxOutputBytes = 4 * 1024 * 1024

    func run(on executable: URL) async {
        phase = .running
        // Primary: structured capability report. Off the main actor because
        // it mmaps + scans the whole binary.
        let report = await Task.detached(priority: .userInitiated) {
            BinaryCapabilityAnalyzer.analyse(executable: executable)
        }.value
        phase = .ready(report)

        // Enrichment: best-effort disassembly. Never surfaced as a hard error.
        disassembly = .running
        guard let tool = await Self.pickTool() else {
            disassembly = .unavailable("No `objdump` or `otool` found on disk, so instruction-level detail isn't available. Install Xcode Command Line Tools (`xcode-select --install`) for the extra detail — the capability summary above doesn't need it.")
            return
        }
        do {
            let raw = try await Self.runDisassembler(tool: tool, target: executable, maxBytes: maxOutputBytes)
            let summary = DisassemblyAnalyzer.analyse(disassembly: raw)
            if summary.totalInstructions == 0 && summary.externalCalls.isEmpty {
                disassembly = .unavailable("The disassembler ran but produced no analysable instructions (the binary may be encrypted or in a format the tool doesn't decode). The capability summary above is derived from the import table and is unaffected.")
            } else {
                disassembly = .ready(summary, tool: tool.label)
            }
        } catch {
            disassembly = .unavailable("Instruction-level disassembly is unavailable: \(error.localizedDescription) The capability summary above doesn't depend on it.")
        }
    }

    // MARK: - Tool picking

    struct ToolChoice {
        let url: URL
        let args: [String]
        let label: String
    }

    static func pickTool() async -> ToolChoice? {
        let fm = FileManager.default
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                     "/Library/Developer/CommandLineTools/usr/bin"]
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
        case empty

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code, let stderr):
                return "the disassembler exited with status \(code) (\(stderr.prefix(120)))."
            case .empty:
                return "the disassembler produced no output."
            }
        }
    }

    /// Run the disassembler and collect stdout **by reading the pipe to EOF**
    /// on background threads, capping bytes as we go. Notes:
    ///
    /// * `nonisolated` so the blocking subprocess I/O (`waitUntilExit`, the
    ///   pipe reads) never runs on the `@MainActor` — the UI must not freeze.
    /// * This deliberately does NOT use the `readabilityHandler` +
    ///   `terminationHandler` pair the old code used: those run on independent
    ///   queues with no ordering guarantee, so the termination handler
    ///   frequently observed an empty buffer and reported "produced no output"
    ///   even when the tool had written megabytes. Reading to EOF is race-free.
    /// * stdout **and** stderr are drained concurrently — if we left stderr
    ///   undrained a tool that wrote >64 KB of warnings would fill the stderr
    ///   pipe, block on the write, and never close stdout, deadlocking the
    ///   stdout read until the 30s timeout.
    nonisolated static func runDisassembler(tool: ToolChoice, target: URL, maxBytes: Int) async throws -> String {
        let task = Process()
        task.executableURL = tool.url
        task.arguments = tool.args + [target.path]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()

        // 30s wall-clock guard: terminating the process closes the pipes,
        // which unblocks the read loops below with EOF. `defer` guarantees it
        // is cancelled on every exit path (including parent-task cancellation
        // when the sheet is dismissed mid-run).
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if task.isRunning { task.terminate() }
        }
        defer { timeoutTask.cancel() }

        // Drain a pipe to EOF, capping retained bytes but still consuming the
        // rest so a >cap writer never blocks on a full pipe.
        func drain(_ pipe: Pipe, cap: Int) -> Task<Data, Never> {
            Task.detached(priority: .userInitiated) {
                let handle = pipe.fileHandleForReading
                var collected = Data()
                while true {
                    let chunk = handle.readData(ofLength: 1 << 16)
                    if chunk.isEmpty { break }   // EOF: write end closed
                    if collected.count < cap {
                        collected.append(chunk.prefix(cap - collected.count))
                    }
                }
                return collected
            }
        }
        let outTask = drain(stdout, cap: maxBytes)
        let errTask = drain(stderr, cap: 64 * 1024)
        let outData = await outTask.value
        let errData = await errTask.value

        task.waitUntilExit()

        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        if task.terminationStatus != 0 && outStr.isEmpty {
            throw RunnerError.nonZeroExit(task.terminationStatus, errStr)
        }
        if outStr.isEmpty { throw RunnerError.empty }
        return outStr
    }
}

// MARK: - Ghidra decompile sheet

/// Decompiles a single function with Ghidra headless and shows the C. The
/// first decompilation of a binary runs Ghidra's full auto-analysis (minutes);
/// subsequent functions of the same binary return in seconds (cached project).
struct GhidraDecompileSheet: View {
    let binary: URL
    let function: String
    var address: String? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GhidraDecompileModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.run(binary: binary, function: function, address: address) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Decompiled function").font(.title3.bold())
                Text(function)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if case .ready(let c) = model.phase {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            Button("Close") { dismiss() }.keyboardShortcut(.escape)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .running:
            VStack(spacing: 12) {
                ProgressView()
                Text("Running Ghidra…").font(.callout)
                Text("The first decompilation of a binary runs full auto-analysis and can take several minutes. Later functions of the same binary are fast.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40)).foregroundStyle(.orange)
                Text("Couldn't decompile").font(.headline)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 560)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()

        case .ready(let c):
            ScrollView([.vertical, .horizontal]) {
                Text(c.isEmpty ? "(empty)" : c)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

@MainActor
final class GhidraDecompileModel: ObservableObject {
    enum Phase {
        case running
        case ready(String)
        case failed(String)
    }

    @Published var phase: Phase = .running
    private let decompiler = GhidraDecompiler()

    func run(binary: URL, function: String, address: String? = nil) async {
        phase = .running
        do {
            let result = try await decompiler.decompile(binary: binary,
                                                        function: function,
                                                        address: address)
            phase = .ready(result.cCode)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(msg)
        }
    }
}
