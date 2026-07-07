import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Whole-app decompilation browser — the visible half of Feature A. Drives
/// `GhidraProgramDump` (a user-installed Ghidra) to reconstruct the app's
/// classes and their pseudo-C, caches the result via `DecompilationIndexStore`,
/// and presents the shared `DecompilationBrowser`.
///
/// The first run for a binary pays Ghidra's full auto-analysis (minutes) and is
/// cancellable; re-opening is instant from the cache.
struct DecompiledClassesView: View {
    let executableURL: URL
    let onClose: () -> Void

    private enum Phase: Equatable { case idle, running, loaded, failed(String) }

    @State private var phase: Phase = .idle
    @State private var index: DecompilationIndex?
    @State private var scopeKind: DecompileScope.Kind = .namedClasses
    @State private var runTask: Task<Void, Never>?

    private let dumper = GhidraProgramDump()

    private var scope: DecompileScope { DecompileScope(kind: scopeKind) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { loadCacheForCurrentScope() }
        .onDisappear { runTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Decompiled classes").font(.headline)
                    InfoButton(articleID: "decompile-whole-app")
                }
                Text(executableURL.lastPathComponent)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Picker("Scope", selection: $scopeKind) {
                Text("Named classes").tag(DecompileScope.Kind.namedClasses)
                Text("Everything").tag(DecompileScope.Kind.everything)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(phase == .running)
            .onChange(of: scopeKind) { _ in loadCacheForCurrentScope() }

            if phase == .running {
                Button(role: .cancel) { runTask?.cancel() } label: { Text("Cancel") }
            } else {
                Button {
                    startDump()
                } label: {
                    Label(index == nil ? "Decompile" : "Re-decompile", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!GhidraProgramDump.isAvailable())
            }

            Button("Close", action: onClose)
        }
        .padding(12)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            idleView
        case .running:
            runningView
        case .failed(let message):
            failedView(message)
        case .loaded:
            if let index { DecompilationBrowser(index: index) } else { idleView }
        }
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "curlybraces.square").font(.system(size: 40)).foregroundStyle(.secondary)
            if GhidraProgramDump.isAvailable() {
                Text("Decompile the whole app").font(.title3.bold())
                Text("Reconstructs the app's classes and functions with Ghidra. The first run analyses the binary (this can take a few minutes); it's cached afterwards, and you can cancel any time.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                Button { startDump() } label: {
                    Label("Decompile whole app", systemImage: "wand.and.stars")
                }.buttonStyle(.borderedProminent)
            } else {
                Text("Ghidra isn't installed").font(.title3.bold())
                Text("Whole-app decompilation uses a local Ghidra install. Unzip a Ghidra release into /Applications (or ~/Applications, /opt, /usr/local, ~/Tools) and reopen this window.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Spacer()
        }
        .padding()
    }

    private var runningView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Decompiling \(executableURL.lastPathComponent)…").font(.headline)
            Text("First run analyses the binary in Ghidra — this can take a few minutes. Later runs are instant. You can cancel and come back.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            Spacer()
        }
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text("Decompilation failed").font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520).textSelection(.enabled)
            Button("Try again") { startDump() }.buttonStyle(.bordered)
            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    /// Show a cached index for the current scope if we have one, without running Ghidra.
    private func loadCacheForCurrentScope() {
        guard let store = try? DecompilationIndexStore(),
              let cached = store.load(binary: executableURL, scope: scope) else {
            index = nil
            phase = .idle
            return
        }
        index = cached
        phase = .loaded
    }

    private func startDump() {
        runTask?.cancel()
        phase = .running
        let exec = executableURL
        let scope = self.scope
        runTask = Task {
            do {
                let store = try? DecompilationIndexStore()
                if let cached = store?.load(binary: exec, scope: scope) {
                    await MainActor.run { index = cached; phase = .loaded }
                    return
                }
                let produced = try await dumper.dump(binary: exec, scope: scope)
                if Task.isCancelled { return }
                try? store?.save(produced, key: GhidraProgramDump.cacheKey(for: exec, scope: scope))
                await MainActor.run { index = produced; phase = .loaded }
            } catch is CancellationError {
                await MainActor.run { phase = index == nil ? .idle : .loaded }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { phase = .failed(message) }
            }
        }
    }
}

/// Reusable class → function → pseudo-C browser over a `DecompilationIndex`.
/// Shared by the local decompile sheet (`DecompiledClassesView`) and the
/// VM-offload result sheet (`GuestAgentSettingsView`), so both sources render
/// identically.
struct DecompilationBrowser: View {
    let index: DecompilationIndex

    @State private var searchText = ""
    @State private var selectedFunctionID: String?

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            HSplitView {
                classList
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                codePane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 8) {
            Text("\(index.classCount) classes · \(index.functionCount) functions")
                .font(.caption).foregroundStyle(.secondary)
            if index.truncated {
                Label(index.note ?? "Truncated", systemImage: "scissors")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var classList: some View {
        VStack(spacing: 0) {
            TextField("Filter classes & functions", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selectedFunctionID) {
                ForEach(filteredClasses) { klass in
                    Section(klass.name) {
                        ForEach(klass.functions) { fn in
                            Text(fn.displayName)
                                .font(.callout.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .tag(fn.id)
                        }
                    }
                }
            }
        }
    }

    private var codePane: some View {
        Group {
            if let fn = selectedFunction {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fn.displayName).font(.callout.monospaced().bold())
                            .textSelection(.enabled).lineLimit(2)
                        if let sig = fn.signature {
                            Text(sig).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        Text(fn.cCode.isEmpty ? "// Ghidra produced no body for this function." : fn.cCode)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a function to view its decompiled C.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var filteredClasses: [DecompiledClass] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return index.classes }
        return index.classes.compactMap { klass in
            if klass.name.lowercased().contains(query) { return klass }
            let matches = klass.functions.filter {
                $0.displayName.lowercased().contains(query) || $0.name.lowercased().contains(query)
            }
            return matches.isEmpty ? nil : DecompiledClass(name: klass.name, functions: matches)
        }
    }

    private var selectedFunction: DecompiledFunction? {
        guard let id = selectedFunctionID else { return nil }
        for klass in index.classes {
            if let fn = klass.functions.first(where: { $0.id == id }) { return fn }
        }
        return nil
    }
}
