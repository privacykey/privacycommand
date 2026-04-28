import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Detects installed reverse-engineering tools and offers to open the
/// inspected app's main executable in them. We don't try to parse their
/// output yet — this is a launchpad. Future work could pipe Ghidra's headless
/// analysis through and surface findings inline.
struct DisassemblerLauncher: View {
    let executableURL: URL
    let bundleURL: URL

    @State private var detectedTools: [Tool] = []
    @State private var showingForensicSheet = false

    /// One detected disassembler / RE tool.
    struct Tool: Identifiable, Hashable {
        let id: String
        let label: String
        let icon: String
        let kind: Kind
        enum Kind: Hashable {
            /// Open the executable file directly with this app via NSWorkspace.
            case app(URL)
            /// Spawn `<cli> <leadingArgs...> [<binary>]` inside Terminal.
            /// `includesBinary == false` for tools whose launcher script
            /// doesn't accept a binary argument (Ghidra's `ghidraRun`).
            case cli(path: URL, leadingArgs: [String], includesBinary: Bool)
        }
    }

    var body: some View {
        GroupBox(label: HStack {
            Text("Reverse-engineering tools")
            InfoButton(articleID: "reverse-engineering")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(executableURL.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([executableURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }

                    // Always-available: in-app forensic summary. Doesn't
                    // require any third-party tool — it shells out to the
                    // bundled `objdump`/`otool` from Xcode CLT.
                    Button {
                        showingForensicSheet = true
                    } label: {
                        Label("Forensic summary", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Plain-English explanation of what this binary does, derived from its disassembly.")

                    if detectedTools.isEmpty {
                        Text("No reverse-engineering tools detected on PATH or /Applications.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(detectedTools) { tool in
                            Button {
                                launch(tool)
                            } label: {
                                Label(tool.label, systemImage: tool.icon)
                            }
                        }
                    }
                }

                if !detectedTools.isEmpty {
                    Text("These open the app's main executable in your local installation. Auditor never modifies the bundle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .task { detectedTools = Self.detectInstalledTools() }
        .sheet(isPresented: $showingForensicSheet) {
            DisassemblySummaryView(
                executableURL: executableURL,
                onClose: { showingForensicSheet = false }
            )
        }
    }

    // MARK: - Launching

    private func launch(_ tool: Tool) {
        switch tool.kind {
        case .app(let appURL):
            // Just open the executable file *with* the chosen app. Hopper,
            // Cutter, Binary Ninja, Hex Fiend all accept the binary path as
            // the document URL.
            NSWorkspace.shared.open(
                [executableURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }

        case .cli(let cliURL, let leadingArgs, let includesBinary):
            var parts: [String] = [Self.shellQuote(cliURL.path)]
            parts.append(contentsOf: leadingArgs.map(Self.shellQuote))
            if includesBinary {
                parts.append(Self.shellQuote(executableURL.path))
            }
            let cmd = parts.joined(separator: " ")
            Self.runInTerminal(cmd)
        }
    }

    /// Quote `s` for inclusion in a shell command. Single-quote everything
    /// containing anything outside [A-Za-z0-9._/=:@%+,-], escaping embedded
    /// single quotes the canonical way.
    private static func shellQuote(_ s: String) -> String {
        if s.range(of: #"[^A-Za-z0-9._/=:@%+,-]"#, options: .regularExpression) == nil {
            return s
        }
        return "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Run `cmd` (already shell-escaped) in Terminal.app via AppleScript.
    private static func runInTerminal(_ cmd: String) {
        // The AppleScript `do script` parameter is itself a string literal
        // — escape backslashes and quotes for that level too.
        let asEscaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\n  activate\n  do script \"\(asEscaped)\"\nend tell"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    // MARK: - Detection

    /// Look in /Applications + ~/Applications for known disassembler GUIs,
    /// and in standard PATH locations for CLI tools (Homebrew, MacPorts).
    static func detectInstalledTools() -> [Tool] {
        var tools: [Tool] = []
        let fm = FileManager.default

        // GUI apps under /Applications and ~/Applications.
        let appCandidates: [(name: String, label: String, icon: String, glob: String)] = [
            ("Hopper",    "Open in Hopper",   "hammer",
             "Hopper Disassembler"),
            ("Cutter",    "Open in Cutter",   "scissors",
             "Cutter"),
            ("Binary Ninja", "Open in Binary Ninja", "rectangle.split.3x1",
             "Binary Ninja"),
            ("Hex Fiend", "Open in Hex Fiend", "number",
             "Hex Fiend")
        ]
        let appRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        for (id, label, icon, prefix) in appCandidates {
            for root in appRoots {
                guard let entries = try? fm.contentsOfDirectory(at: root,
                                                                includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]) else { continue }
                if let match = entries.first(where: {
                    $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix)
                }) {
                    tools.append(Tool(id: id, label: label, icon: icon, kind: .app(match)))
                    break
                }
            }
        }

        // CLI tools — try /opt/homebrew/bin, /usr/local/bin, /usr/bin.
        // Each entry knows which leading args to pass and whether the
        // binary path is appended at the end.
        struct CLIEntry {
            let id: String
            let label: String
            let icon: String
            let exec: String
            let leadingArgs: [String]
            let includesBinary: Bool
        }
        let cliCandidates: [CLIEntry] = [
            // r2 / rizin: just `r2 <binary>` lands in their interactive prompt.
            CLIEntry(id: "radare2", label: "Open in r2 (Terminal)",
                     icon: "terminal", exec: "r2",
                     leadingArgs: [], includesBinary: true),
            CLIEntry(id: "rizin", label: "Open in rizin (Terminal)",
                     icon: "terminal", exec: "rizin",
                     leadingArgs: [], includesBinary: true),
            // objdump needs `-d` to actually disassemble; without it just prints help.
            CLIEntry(id: "objdump", label: "objdump -d (disassemble)",
                     icon: "doc.text", exec: "objdump",
                     leadingArgs: ["-d"], includesBinary: true),
            // otool ships with Apple's CLT and is the canonical Mach-O dumper.
            CLIEntry(id: "otool", label: "otool -tV (disassemble + symbols)",
                     icon: "doc.text", exec: "otool",
                     leadingArgs: ["-tV"], includesBinary: true),
            CLIEntry(id: "otool-L", label: "otool -L (linked dylibs)",
                     icon: "link.badge.plus", exec: "otool",
                     leadingArgs: ["-L"], includesBinary: true)
        ]
        let cliRoots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                        "/Library/Developer/CommandLineTools/usr/bin"]
        // De-dupe by exec name so we don't show two `otool` entries pointing
        // at different copies of the same binary.
        var seenExec: Set<String> = []
        for entry in cliCandidates {
            for root in cliRoots {
                let candidate = URL(fileURLWithPath: "\(root)/\(entry.exec)")
                if fm.isExecutableFile(atPath: candidate.path) {
                    if seenExec.contains(entry.id) { break }
                    seenExec.insert(entry.id)
                    tools.append(Tool(
                        id: entry.id,
                        label: entry.label,
                        icon: entry.icon,
                        kind: .cli(path: candidate,
                                   leadingArgs: entry.leadingArgs,
                                   includesBinary: entry.includesBinary)
                    ))
                    break
                }
            }
        }

        // Ghidra is delivered as a folder containing ghidraRun (a shell
        // script that boots the Java GUI). It doesn't accept a binary
        // argument — the user imports via the GUI — so we don't include
        // the binary path.
        let ghidraSearchRoots = appRoots + [URL(fileURLWithPath: "/opt"),
                                            URL(fileURLWithPath: "/usr/local"),
                                            fm.homeDirectoryForCurrentUser.appendingPathComponent("Tools")]
        for root in ghidraSearchRoots {
            if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
               let dir = entries.first(where: { $0.lastPathComponent.lowercased().hasPrefix("ghidra") && $0.hasDirectoryPath }) {
                let runScript = dir.appendingPathComponent("ghidraRun")
                if fm.isExecutableFile(atPath: runScript.path) {
                    tools.append(Tool(
                        id: "ghidra",
                        label: "Open Ghidra (import manually)",
                        icon: "g.circle.fill",
                        kind: .cli(path: runScript, leadingArgs: [], includesBinary: false)
                    ))
                    break
                }
            }
        }

        return tools
    }
}
