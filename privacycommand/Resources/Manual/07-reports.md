# Reports

Every report, static findings and dynamic events together, can be exported from the File menu once an app is open:

- **File ▸ Save Run Report (JSON)…** writes the full report as JSON, the same format the History tab stores.
- **File ▸ Save Run Report (HTML)…** writes a standalone page you can read in any browser or attach to a ticket.
- **File ▸ Save Run Report (PDF)…** renders the same report as a PDF.

Each item opens a save panel with a file name suggested from the app's name and version. The export reflects the report as it stands: export after a monitored run to include its events, or before one for the static findings alone.

## The command line

privacycommand carries `auditctl`, a command-line front end over the same analyser, for scripting and CI. `auditctl <path or app name>` audits one app (`--short`, `--tree`, `--json`, `--warnings`), and `auditctl preview` inspects outdated Homebrew casks before you update them. `auditctl --help` lists every command.

- **Installed with Homebrew:** the cask has already put `auditctl` on your `PATH`.
- **Installed from the disk image:** choose **privacycommand ▸ Install Command Line Tool…**. It links the copy inside the app into `/usr/local/bin`, so the tool updates with the app. If that folder needs administrator rights, the alert shows the `sudo` command to run in Terminal instead, with a button that copies it. Choose **Uninstall Command Line Tool…** from the same place to remove the link.

Run privacycommand from the Applications folder before installing the tool: a link into a copy that is still on the disk image stops working when the image is ejected, so the item asks you to move the app first.
