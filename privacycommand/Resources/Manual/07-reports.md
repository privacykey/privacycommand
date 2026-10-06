# Reports

Every report, static findings and dynamic events together, can be exported from the File menu once an app is open:

- **File ▸ Save Run Report (JSON)…** writes the full report as JSON, the same format the History tab stores.
- **File ▸ Save Run Report (HTML)…** writes a standalone page you can read in any browser or attach to a ticket.
- **File ▸ Save Run Report (PDF)…** renders the same report as a PDF.

Each item opens a save panel with a file name suggested from the app's name and version. The export reflects the report as it stands: export after a monitored run to include its events, or before one for the static findings alone.

## The command line

The repository also builds `auditctl`, a command-line front end over the same analyser, for scripting and CI. `auditctl <path or app name>` audits one app (`--short`, `--tree`, `--json`, `--warnings`), and `auditctl preview` inspects outdated Homebrew casks before you update them. Building and using it is covered in the repository's CONTRIBUTING.md.
