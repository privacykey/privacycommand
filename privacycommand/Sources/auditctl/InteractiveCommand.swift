import Foundation
import privacycommandCore
import auditctlKit

/// `auditctl -i` / `auditctl interactive` (and a bare `auditctl` on a terminal)
/// — the witr-style interactive browser: pick an installed app from a filterable
/// list and its static audit renders live in the detail pane.
enum InteractiveCommand {

    static func run() -> Never {
        guard isatty(FileHandle.standardInput.fileDescriptor) != 0,
              isatty(FileHandle.standardOutput.fileDescriptor) != 0 else {
            die("interactive mode needs a terminal (stdin and stdout must both be a TTY).\n"
                + "For scripts, use `auditctl <app> --json` instead.", code: 2)
        }

        let apps = HomebrewCaskInventory
            .installedApps(in: AuditCommand.searchDirectories())
            .map { AppEntry(name: $0.displayName, url: $0.bundleURL) }

        guard !apps.isEmpty else {
            die("no apps found in /Applications, ~/Applications, or /System/Applications.", code: 2)
        }

        TerminalDriver(model: AppBrowserModel(apps: apps)).run()
        exit(0)
    }
}
