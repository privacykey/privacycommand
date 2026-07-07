import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Settings tab that walks the user through getting privacycommand-
/// guest installed on a macOS VM.
///
/// Three sections:
///   1. Build the installer DMG (calls Scripts/build-guest-installer.sh)
///   2. Detected VM tools — VirtualBuddy / UTM / Parallels / VMware
///   3. Per-tool VM list with Start + Reveal-installer buttons
struct GuestAgentSettingsView: View {

    @EnvironmentObject private var coordinator: AnalysisCoordinator
    /// Path to the .app *inside the guest* to launch for a VM run. The host
    /// can't enumerate the guest's filesystem, so the user types it.
    @State private var guestBundlePath = ""
    @State private var detectedTools: [VMHostDetection.Tool] = []
    @State private var vmsByTool: [VMHostDetection.Tool.Kind: VMHostDetection.VMQueryOutcome] = [:]
    /// VM name the user typed for a tool whose VM list is `.unsupported`
    /// but that can still start a VM by name (e.g. VirtualBuddy). Keyed
    /// by tool kind so each tool's field is independent.
    @State private var manualVMName: [VMHostDetection.Tool.Kind: String] = [:]
    @State private var installerURL: URL? = Self.existingInstallerURL()
    @State private var isBuilding = false
    @State private var buildError: String?
    @State private var buildLog: String = ""
    /// Scope for a VM-offloaded whole-app decompilation, and whether the
    /// result browser sheet is open.
    @State private var vmDecompileScopeKind: DecompileScope.Kind = .namedClasses
    @State private var showingVMDecompileResult = false

    var body: some View {
        Form {
            Section("How VM mode works") {
                howItWorksSection
            }
            Section("Step 1 · Installer disk image") {
                buildSection
            }
            Section("Step 2 · Detected VM tools") {
                if detectedTools.isEmpty {
                    Text("No supported VM tools found on this Mac. Install VirtualBuddy, UTM, Parallels Desktop, or VMware Fusion first.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Spacer()
                        Button {
                            refreshVMs()
                        } label: {
                            Label("Refresh VMs", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Re-query each VM tool. Use this after granting Automation access so the lists repopulate without restarting privacycommand.")
                    }
                    ForEach(detectedTools, id: \.kind) { tool in
                        toolSection(tool)
                    }
                }
            }
            Section("Step 3 · Inside the VM") {
                Text("Once the installer disk image is mounted in your guest VM:")
                    .font(.callout)
                Text("1.  Open the **privacycommand-guest** volume in the guest's Finder.")
                Text("2.  Double-click **Install.command**. Enter your password when sudo asks.")
                Text("3.  Wait for the confirmation that the agent is listening on TCP 49374.")
                Text("4.  Note the VM's IP address: `ifconfig en0 | grep inet`. Plug that IP into the connection panel below.")
                    .font(.callout)
            }
            Section("Step 3½ · Connect to the guest agent & run") {
                connectionSection
            }
            Section("Step 4 · Picking an app to inspect") {
                pickAppSection
            }
            Section("Common confusion") {
                glossarySection
            }
        }
        .formStyle(.grouped)
        .task {
            detectedTools = VMHostDetection.detectInstalled()
            refreshVMs()
        }
    }

    /// Re-query every detected tool for its VM list. Called on first
    /// appear and from the Refresh button — the latter matters because
    /// granting Automation access mid-session won't retroactively change
    /// an already-rendered "not authorised" state until we ask again.
    private func refreshVMs() {
        for tool in detectedTools {
            vmsByTool[tool.kind] = VMHostDetection.listVMs(for: tool)
        }
    }

    /// Deep-link into System Settings → Privacy & Security → Automation,
    /// where the user toggles which apps privacycommand may control.
    private func openAutomationSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Build section

    @ViewBuilder
    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = installerURL, FileManager.default.fileExists(atPath: url.path) {
                LabeledContent("Installer DMG") {
                    HStack(spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle)
                        Button("Reveal") {
                            VMHostDetection.revealInstallerInFinder(at: url)
                        }
                        Button("Rebuild") { Task { await build() } }
                            .disabled(isBuilding)
                    }
                }
                Text("Drag this DMG onto a running VM window — VirtualBuddy, UTM, Parallels and VMware all accept disk-image drops. Or attach it via your VM tool's menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    Task { await build() }
                } label: {
                    Label("Build installer disk image",
                          systemImage: "hammer")
                }
                .disabled(isBuilding)
                .buttonStyle(.borderedProminent)
                Text("Compiles privacycommand-guest in release mode and packages it (plus the LaunchAgent plist and Install.command) into a small .dmg. Takes about 30 seconds the first time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isBuilding {
                ProgressView("Building…").controlSize(.small)
            }
            if let err = buildError {
                Label(err, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption)
            }
            if !buildLog.isEmpty {
                DisclosureGroup("Build log") {
                    ScrollView {
                        Text(buildLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    // MARK: - Per-tool section

    @ViewBuilder
    private func toolSection(_ tool: VMHostDetection.Tool) -> some View {
        let outcome = vmsByTool[tool.kind] ?? .ok([])
        let vms = outcome.vms
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "macwindow.badge.plus").foregroundStyle(.blue)
                Text(tool.displayName).font(.subheadline.bold())
                Spacer()
                if case .ok = outcome {
                    Text("\(vms.count) VM\(vms.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Important caveat — explained once per tool so the user
            // doesn't expect a one-click attach. None of the VM
            // front-ends expose a public AppleScript verb for "attach
            // this disk image"; the universally-supported path is
            // drag-and-drop onto the VM's window, which is what
            // Reveal-installer is for.
            Text("**privacycommand can start a VM and reveal the installer DMG in Finder for you, but it can't attach the DMG to the VM automatically — \(tool.displayName) doesn't expose an attach-image API. Drag the highlighted file onto the running \(tool.displayName) window once; the tool mounts it as a shared disk inside the guest.**")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch outcome {
            case .notAuthorized:
                VStack(alignment: .leading, spacing: 4) {
                    Label("privacycommand isn't allowed to control \(tool.displayName).",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.orange)
                    Text("macOS blocked the Apple event used to read the VM list. Enable **\(tool.displayName)** under **privacycommand** in System Settings → Privacy & Security → Automation, then click Refresh VMs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Automation settings") { openAutomationSettings() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            case .scriptError(let code, let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn't read VMs from \(tool.displayName).",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    Text("\(message) (error \(code)). Open \(tool.displayName), make sure it has finished launching, then click Refresh VMs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unsupported:
                Text("\(tool.displayName) doesn't expose a VM-list API privacycommand can read. Start the VM yourself, then drag the installer DMG onto its window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok where vms.isEmpty:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No VMs found for \(tool.displayName). Create or import a VM in \(tool.displayName), then click Refresh VMs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // For tools we can start by name even without a list
                    // (VirtualBuddy, whose library scan may come up empty
                    // if it's in a non-default location), let the user
                    // start a VM by typing its exact name.
                    if VMHostDetection.supportsStartByName(tool.kind) {
                        manualStartField(tool)
                    }
                }
            case .ok:
                ForEach(vms, id: \.name) { vm in
                    HStack {
                        Image(systemName: "rectangle.on.rectangle")
                            .foregroundStyle(.secondary)
                        Text(vm.name).font(.callout)
                        Spacer()
                        Button("Start") {
                            _ = VMHostDetection.startVM(named: vm.name, tool: tool)
                        }
                        .controlSize(.small)
                        if let url = installerURL {
                            Button("Reveal installer") {
                                VMHostDetection.revealInstallerInFinder(at: url)
                            }
                            .controlSize(.small)
                            .help("Selects the installer DMG in Finder. Drag it onto the running \(tool.displayName) window to attach it as a shared disk inside the guest. We can't do this automatically — \(tool.displayName) doesn't expose an attach-image API.")
                        }
                    }
                }
            }
        }
    }

    /// Text field + Start (+ Reveal-installer) for starting a VM by a
    /// name the user types. Used as a fallback for tools we can start by
    /// name (`supportsStartByName`) but whose VM list we couldn't
    /// enumerate — e.g. VirtualBuddy when its library scan finds nothing.
    @ViewBuilder
    private func manualStartField(_ tool: VMHostDetection.Tool) -> some View {
        let trimmed = (manualVMName[tool.kind] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("VM name", text: Binding(
                    get: { manualVMName[tool.kind] ?? "" },
                    set: { manualVMName[tool.kind] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { startManually(name: trimmed, tool: tool) }
                Button("Start") { startManually(name: trimmed, tool: tool) }
                    .controlSize(.small)
                    .disabled(trimmed.isEmpty)
                if let url = installerURL {
                    Button("Reveal installer") {
                        VMHostDetection.revealInstallerInFinder(at: url)
                    }
                    .controlSize(.small)
                    .help("Selects the installer DMG in Finder. Drag it onto the running \(tool.displayName) window to attach it as a shared disk inside the guest.")
                }
            }
            if tool.kind == .virtualBuddy {
                Text("The first time, VirtualBuddy asks you to allow privacycommand to control it — approve that prompt once and later starts go straight through.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Start a VM by the name the user typed, ignoring blank input.
    private func startManually(name: String, tool: VMHostDetection.Tool) {
        guard !name.isEmpty else { return }
        _ = VMHostDetection.startVM(named: name, tool: tool)
    }

    // MARK: - Connect & run-in-VM

    /// The connection panel: VM address + port, a Test button with a live
    /// status badge, and (once reachable) a control to launch a run inside
    /// the guest. The run's observations stream into the normal tabs.
    @ViewBuilder
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Point privacycommand at the guest agent running inside your VM, then launch the app there. The run shows up in the Dashboard / Network / Files / Probes tabs, just tagged as a VM run.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("VM IP address (e.g. 192.168.64.5)", text: $coordinator.vmHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                TextField("Port", value: $coordinator.vmPort,
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 70)
                Button("Test connection") {
                    Task { await coordinator.testVMConnection() }
                }
                .controlSize(.small)
                .disabled(coordinator.vmConnection == .checking)
            }

            connectionStatusBadge

            Divider().padding(.vertical, 2)

            Text("Path to the .app **inside the VM** to launch (you transfer it in via drag-drop / AirDrop / scp first):")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("/Users/you/Downloads/Foo.app", text: $guestBundlePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                if coordinator.isVMRun && coordinator.isMonitoring {
                    Button("Stop VM run") {
                        Task { await coordinator.stopMonitoredRun() }
                    }
                    .controlSize(.small)
                    .tint(.red)
                } else {
                    Button("Run in VM") {
                        Task { await coordinator.startMonitoredRunInVM(guestBundlePath: guestBundlePath) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.canStartVMRun
                              || guestBundlePath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !coordinator.canStartVMRun
                && !(coordinator.isVMRun && coordinator.isMonitoring) {
                Text("Test the connection first — “Run in VM” enables once the guest agent answers.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)
            vmDecompileControls
        }
    }

    /// Offload a whole-app decompilation to the guest VM (needs Ghidra in the
    /// guest). Reuses the same guest bundle path + connection as a VM run, and
    /// shows the result in the shared `DecompilationBrowser`.
    @ViewBuilder
    private var vmDecompileControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or decompile the app **inside the VM** (needs Ghidra installed in the guest):")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Scope", selection: $vmDecompileScopeKind) {
                    Text("Named classes").tag(DecompileScope.Kind.namedClasses)
                    Text("Everything").tag(DecompileScope.Kind.everything)
                }
                .pickerStyle(.segmented).fixedSize()
                .disabled(coordinator.vmDecompiling)

                if coordinator.vmDecompiling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Decompiling in VM…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Decompile in VM") {
                        Task {
                            await coordinator.decompileInVM(
                                guestBundlePath: guestBundlePath,
                                scope: DecompileScope(kind: vmDecompileScopeKind))
                            if coordinator.vmDecompileResult != nil { showingVMDecompileResult = true }
                        }
                    }
                    .controlSize(.small)
                    .disabled(!coordinator.canStartVMRun
                              || guestBundlePath.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let result = coordinator.vmDecompileResult {
                    Button("View \(result.classCount) classes") { showingVMDecompileResult = true }
                        .controlSize(.small)
                }
            }
            if let error = coordinator.vmDecompileError {
                Text(error).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingVMDecompileResult) {
            if let index = coordinator.vmDecompileResult {
                VStack(spacing: 0) {
                    HStack {
                        Text("Decompiled in VM — \(guestBundlePath)")
                            .font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Close") { showingVMDecompileResult = false }
                    }
                    .padding(12)
                    Divider()
                    DecompilationBrowser(index: index)
                }
                .frame(minWidth: 900, minHeight: 560)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch coordinator.vmConnection {
        case .idle:
            Label("Not checked yet.", systemImage: "circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Contacting the guest agent…").font(.caption).foregroundStyle(.secondary)
            }
        case .connected(let host, let macOS, let version):
            Label("Connected — \(host), macOS \(macOS) (agent v\(version)).",
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .versionMismatch(let guestVersion, let hostVersion):
            Label("Guest agent is v\(guestVersion) but this host speaks v\(hostVersion). Rebuild the installer DMG and reinstall the agent inside the VM.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable(let why):
            Label("Not reachable — \(why) Check the VM is running, the agent is installed, and the IP/port are right.",
                  systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Explanatory sections

    /// Architecture explainer at the top of the panel — sets
    /// expectations before the user starts clicking buttons.
    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VM mode runs the inspected app inside a separate macOS VM. Two binaries are involved:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            architectureRow(
                icon: "macbook",
                title: "On your Mac (host)",
                text: "The privacycommand app you're using right now. Same UI, same Dashboard / Static / Files / Network / Probes tabs. You don't need a second window — when VM mode is active, observations from the VM stream into the same tabs.")

            architectureRow(
                icon: "macwindow.on.rectangle",
                title: "Inside the VM (guest)",
                text: "A small daemon called **privacycommand-guest**. No UI — it's a background process that listens for commands from the host on TCP 49374 and ships observations back. You install it once with the DMG built below, then forget about it.")

            Text("**You do not need a second copy of the privacycommand app inside the VM.** Just the agent.")
                .font(.callout)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)

            Text("**One thing privacycommand can't do for you:** automatically attach the installer DMG to your VM. VirtualBuddy, UTM, and VMware Fusion don't expose a public way for outside apps to mount disk images into a running guest. So the workflow has one manual step — once the DMG is built, drag it onto your VM's window. Every supported VM tool accepts this drop and mounts the image as a shared disk inside the guest. Parallels Desktop users can alternatively shell out to `prlctl set <vm> --device-add cdrom --image=...`, but the drag-drop path is uniform.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Step 4" — actually walking the user through using VM mode
    /// after the agent is installed.
    private var pickAppSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Once the agent is installed and you've connected the host to the VM:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            instructionRow("1", "Get a copy of the .app you want to inspect into the VM. The easiest path is to drag the .app (or the .dmg it came on) onto the VM window — VirtualBuddy / UTM / Parallels all accept drops as a shared file. You can also AirDrop, or scp, or download it inside the VM directly.")

            instructionRow("2", "Note the path to the .app inside the VM. Usually somewhere like /Users/<your-vm-user>/Downloads/Foo.app or /Applications/Foo.app once the user drags it there.")

            instructionRow("3", "On the host, drag a .app or .dmg onto privacycommand's window the same way you always have. When VM mode is active, the host UI shows a chooser asking whether to inspect on the host or in the connected VM. Pick the VM.")

            instructionRow("4", "If you picked the VM, the host sends the bundle path you typed (or one we propose, like /tmp/privacycommand/inspect.app) to the agent. The agent launches the app inside the VM, monitors its process tree / network / file activity / live probes, and ships every observation back over the same TCP socket. The host UI shows it all in the existing tabs — just labelled with a small \"VM\" badge so you know the events came from the guest, not your real Mac.")

            Text("Stop a VM run the same way you'd stop a host run — Stop button in the toolbar. The agent terminates the process tree inside the VM and goes back to idle, ready for the next launch.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Glossary of the various "helper" things — privacycommand has
    /// accumulated a few daemons and it's easy to confuse them.
    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("privacycommand has a few \"helper\" components. They're separate things that do separate jobs:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            glossaryRow(
                title: "privacycommand (the app)",
                desc: "What you're looking at. The GUI on your real Mac. You always need this; the other components are optional.")

            glossaryRow(
                title: "privacycommandHelper (the file-monitoring helper)",
                desc: "Tab next to this one. A root daemon on your **host** Mac that wraps fs_usage to capture file-system events for runs that happen on your host. **Unrelated to VM mode.** If you only use VM mode, you don't need this helper installed.")

            glossaryRow(
                title: "privacycommand-guest (this tab)",
                desc: "A small daemon that runs **inside the VM**, not on your host. It's what makes VM mode work. Installed via the DMG built below.")
        }
    }

    private func architectureRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func instructionRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n)
                .font(.subheadline.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text).font(.callout).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func glossaryRow(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.subheadline.bold())
            Text(desc).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Build action

    private func build() async {
        isBuilding = true
        buildError = nil
        buildLog = ""

        let scriptPath = Self.scriptURL()
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            buildError = """
                Couldn't find build-guest-installer.sh.
                The script should ship inside the app bundle at \
                Contents/Resources/build-guest-installer.sh — if it's missing, \
                this build is broken; please reinstall privacycommand. Last \
                lookup path: \(scriptPath.path)
                """
            isBuilding = false
            return
        }
        let outDir = Self.installerDirectory()
        try? FileManager.default.createDirectory(at: outDir,
                                                 withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath.path, outDir.path]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do { try task.run() }
        catch {
            buildError = error.localizedDescription
            isBuilding = false
            return
        }

        // Capture output without blocking the main actor — read on a
        // detached task and post results back when done.
        let result: (status: Int32, log: String) = await Task.detached {
            task.waitUntilExit()
            let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let log = (String(data: out, encoding: .utf8) ?? "")
                + (String(data: err, encoding: .utf8) ?? "")
            return (task.terminationStatus, log)
        }.value

        buildLog = result.log
        if result.status == 0 {
            installerURL = outDir.appendingPathComponent("privacycommand-guest-installer.dmg")
        } else {
            buildError = "Build script exited with status \(result.status). See the log below for details."
        }
        isBuilding = false
    }

    // MARK: - Path helpers

    private static func installerDirectory() -> URL {
        // Match RunStore.init's defensive lookup — see the comment
        // there for why `.first!` is unsafe on TCC-restricted Macs.
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        return root.appendingPathComponent("privacycommand", isDirectory: true)
    }

    private static func existingInstallerURL() -> URL? {
        let url = installerDirectory()
            .appendingPathComponent("privacycommand-guest-installer.dmg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Locate `build-guest-installer.sh`. Three lookup paths, in
    /// order of preference:
    ///
    ///   1. **Inside the running .app bundle.** The Xcode app target
    ///      ships `Scripts/build-guest-installer.sh` as a resource,
    ///      so a notarised release build finds it at
    ///      `<App>/Contents/Resources/build-guest-installer.sh`.
    ///      This is the path users actually hit.
    ///   2. **Source-tree walk.** `swift run` and unsealed Xcode
    ///      builds run out of DerivedData, where the executable's
    ///      ancestors include the repo root with `Scripts/` next to
    ///      `Sources/`. Walking up six levels covers both layouts.
    ///   3. **Application Support fallback.** If the user has
    ///      manually dropped the script into
    ///      `~/Library/Application Support/privacycommand/`, use it.
    ///      Kept as an escape hatch for users who want to patch the
    ///      script without rebuilding the app.
    ///
    /// We invoke the result via `/bin/bash <script> <outdir>` (see
    /// `build()`), so the script doesn't need its `+x` bit set — the
    /// shell reads it regardless.
    private static func scriptURL() -> URL {
        let fm = FileManager.default

        // 1. Inside the .app bundle (the shipping case).
        if let bundled = Bundle.main.url(
            forResource: "build-guest-installer",
            withExtension: "sh"
        ), fm.fileExists(atPath: bundled.path) {
            return bundled
        }

        // 2. Source-tree walk — covers dev builds.
        var candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let try1 = candidate
                .appendingPathComponent("Scripts")
                .appendingPathComponent("build-guest-installer.sh")
            if fm.fileExists(atPath: try1.path) { return try1 }
            candidate.deleteLastPathComponent()
        }

        // 3. Application Support fallback (manual user copy).
        return installerDirectory()
            .appendingPathComponent("build-guest-installer.sh")
    }
}
