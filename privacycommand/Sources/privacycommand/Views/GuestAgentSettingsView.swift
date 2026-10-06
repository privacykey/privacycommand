import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// The VM agent pane of Settings: the sections that get privacycommand-guest
/// installed on a macOS VM and a run started inside it.
///
/// Four sections:
///   1. Build the installer DMG (calls Scripts/build-guest-installer.sh)
///   2. Detected VM tools — VirtualBuddy / UTM / Parallels / VMware — with
///      a per-tool VM list and Start + Reveal-installer buttons
///   3. Connect to the guest agent and run an app inside the VM
///   4. Decompile an app inside the VM
///
/// The walkthrough itself (what runs where, the steps inside the guest, the
/// helper glossary) is the VM mode chapter of the manual.
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

    private static let overview = "VM mode runs the inspected app inside a separate macOS virtual machine. A small daemon, privacycommand-guest, runs inside the VM with no UI of its own: it listens for commands from this app on TCP 49374 and ships its observations back, so they appear in the same Summary, Files, Network and Probes tabs with a VM badge. You do not need a second copy of privacycommand inside the VM. The manual's VM mode chapter walks through the whole setup."

    private static let buildInfo = "Compiles privacycommand-guest in release mode and packages it, with its LaunchAgent plist and Install.command, into a small .dmg. Takes about 30 seconds the first time. Then drag the disk image onto the running VM's window (VirtualBuddy, UTM, Parallels and VMware all accept disk-image drops), open the privacycommand-guest volume inside the guest and double-click Install.command."

    private static let addressInfo = "Once Install.command has finished, find the VM's address inside the guest with `ifconfig en0 | grep inet` and enter it here. Test Connection runs a version handshake with the agent; Run in VM enables once it answers."

    private static let appPathInfo = "The path of the .app inside the VM, for example /Users/you/Downloads/Foo.app. Copy the app into the guest first: drag it (or its .dmg) onto the VM window, AirDrop it, or scp it."

    private static let decompileInfo = "Runs Ghidra inside the guest and streams the reconstructed classes back, so the CPU-heavy analysis never touches your Mac. Ghidra must be installed in the VM; if it is not, the agent says so and nothing else happens."

    var body: some View {
        Section("Installer disk image") {
            buildSection
        }
        .task {
            detectedTools = VMHostDetection.detectInstalled()
            refreshVMs()
        }
        Section("VM tools") {
            if detectedTools.isEmpty {
                Text("No supported VM tools found on this Mac. Install VirtualBuddy, UTM, Parallels Desktop or VMware Fusion first.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LabeledContent {
                    Button("Refresh VMs") { refreshVMs() }
                        .help("Re-query each VM tool. Use this after granting Automation access so the lists repopulate without restarting privacycommand.")
                } label: {
                    SurfaceInfoLabel("Detected", info: "\(detectedTools.count) VM tool\(detectedTools.count == 1 ? "" : "s") installed. privacycommand can start a VM and reveal the installer for you, but no VM tool exposes a way to attach a disk image from outside, so that one step is a drag onto the VM window.")
                }
                ForEach(detectedTools, id: \.kind) { tool in
                    toolSection(tool)
                }
            }
        }
        Section("Guest agent") {
            connectionSection
        }
        Section("Decompile in VM") {
            vmDecompileControls
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
        if let url = installerURL, FileManager.default.fileExists(atPath: url.path) {
            LabeledContent {
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
            } label: {
                SurfaceInfoLabel("Disk image", info: Self.buildInfo)
            }
        } else {
            LabeledContent {
                Button {
                    Task { await build() }
                } label: {
                    Label("Build Disk Image", systemImage: "hammer")
                }
                .disabled(isBuilding)
                .buttonStyle(.borderedProminent)
            } label: {
                SurfaceInfoLabel("Disk image", info: Self.overview + "\n\n" + Self.buildInfo)
            }
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

    // MARK: - Per-tool section

    @ViewBuilder
    private func toolSection(_ tool: VMHostDetection.Tool) -> some View {
        let outcome = vmsByTool[tool.kind] ?? .ok([])
        let vms = outcome.vms
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "macwindow.badge.plus").foregroundStyle(.blue)
                // None of the VM front-ends expose a public AppleScript verb
                // for "attach this disk image"; the universally-supported
                // path is drag-and-drop onto the VM's window, which is what
                // Reveal Installer is for.
                SurfaceInfoLabel(tool.displayName,
                                 info: "privacycommand can start a VM and reveal the installer disk image in Finder, but it cannot attach the image to the VM: \(tool.displayName) does not expose an attach-image API. Drag the revealed file onto the running \(tool.displayName) window once; the tool mounts it as a shared disk inside the guest.")
                    .font(.subheadline.bold())
                Spacer()
                if case .ok = outcome {
                    Text("\(vms.count) VM\(vms.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch outcome {
            case .notAuthorized:
                VStack(alignment: .leading, spacing: 4) {
                    Label("privacycommand isn't allowed to control \(tool.displayName).",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.orange)
                    Text("macOS blocked the Apple event used to read the VM list. Enable **\(tool.displayName)** under **privacycommand** in System Settings → Privacy & Security → Automation, then click Refresh VMs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Automation Settings") { openAutomationSettings() }
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
                Text("\(tool.displayName) doesn't expose a VM list privacycommand can read. Start the VM yourself, then drag the installer disk image onto its window.")
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
                            Button("Reveal Installer") {
                                VMHostDetection.revealInstallerInFinder(at: url)
                            }
                            .controlSize(.small)
                            .help("Selects the installer disk image in Finder. Drag it onto the running \(tool.displayName) window to attach it as a shared disk inside the guest.")
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
                    Button("Reveal Installer") {
                        VMHostDetection.revealInstallerInFinder(at: url)
                    }
                    .controlSize(.small)
                    .help("Selects the installer disk image in Finder. Drag it onto the running \(tool.displayName) window to attach it as a shared disk inside the guest.")
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

    /// The connection rows: VM address + port with a Test button and a live
    /// status line, then the guest app path with the control that launches
    /// a run inside the guest. The run's observations stream into the
    /// normal tabs.
    @ViewBuilder
    private var connectionSection: some View {
        LabeledContent {
            HStack {
                TextField("VM IP address (e.g. 192.168.64.5)", text: $coordinator.vmHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                TextField("Port", value: $coordinator.vmPort,
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 64)
                Button("Test Connection") {
                    Task { await coordinator.testVMConnection() }
                }
                .controlSize(.small)
                .disabled(coordinator.vmConnection == .checking)
            }
        } label: {
            SurfaceInfoLabel("Address", info: Self.addressInfo)
        }

        connectionStatusBadge

        LabeledContent {
            HStack {
                TextField("/Users/you/Downloads/Foo.app", text: $guestBundlePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if coordinator.isVMRun && coordinator.isMonitoring {
                    Button("Stop VM Run") {
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
        } label: {
            SurfaceInfoLabel("App inside the VM", info: Self.appPathInfo)
        }
        if !coordinator.canStartVMRun
            && !(coordinator.isVMRun && coordinator.isMonitoring) {
            Text("Test the connection first — Run in VM enables once the guest agent answers.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Offload a whole-app decompilation to the guest VM (needs Ghidra in the
    /// guest). Reuses the same guest bundle path + connection as a VM run, and
    /// shows the result in the shared `DecompilationBrowser`.
    @ViewBuilder
    private var vmDecompileControls: some View {
        LabeledContent {
            HStack {
                Picker("Scope", selection: $vmDecompileScopeKind) {
                    Text("Named classes").tag(DecompileScope.Kind.namedClasses)
                    Text("Everything").tag(DecompileScope.Kind.everything)
                }
                .labelsHidden()
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
                    Button("View \(result.classCount) Classes") { showingVMDecompileResult = true }
                        .controlSize(.small)
                }
            }
        } label: {
            SurfaceInfoLabel("Scope", info: Self.decompileInfo)
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
        if let error = coordinator.vmDecompileError {
            Text(error).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
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
            Label("Guest agent is v\(guestVersion) but this host speaks v\(hostVersion). Rebuild the installer disk image and reinstall the agent inside the VM.",
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
