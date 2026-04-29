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

    @State private var detectedTools: [VMHostDetection.Tool] = []
    @State private var vmsByTool: [VMHostDetection.Tool.Kind: [VMHostDetection.VMSummary]] = [:]
    @State private var installerURL: URL? = Self.existingInstallerURL()
    @State private var isBuilding = false
    @State private var buildError: String?
    @State private var buildLog: String = ""

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
                Text("4.  Note the VM's IP address: `ifconfig en0 | grep inet`. Plug that IP into the host's connection panel.")
                    .font(.callout)
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
            for tool in detectedTools {
                vmsByTool[tool.kind] = VMHostDetection.listVMs(for: tool)
            }
        }
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
        let vms = vmsByTool[tool.kind] ?? []
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "macwindow.badge.plus").foregroundStyle(.blue)
                Text(tool.displayName).font(.subheadline.bold())
                Spacer()
                Text("\(vms.count) VM\(vms.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
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

            if vms.isEmpty {
                Text("No VMs found, or AppleScript dictionary not yet authorised. Open \(tool.displayName) once and try again.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
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
