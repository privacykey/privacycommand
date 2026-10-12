# Changelog

## 0.2.2

The command-line tool now shows what it's doing while it works, and its upgrade reports are easier to read.

### Command line

- `privacycommand preview` and `privacycommand upgrade` show a live progress board while they run. Each app gets a row with the step it's on, how many MB have downloaded (with `--fetch` and `upgrade`), and then its result. The board clears before the report prints. It only appears on a terminal, so piped output and `--json` are unchanged.
- The `preview` and `upgrade` report is now in colour, like a single-app audit. Each headline shows the app's risk tier, findings are tagged by severity, and held casks show in red. Versions leave out Homebrew's build hash. `--json` still has the full string.
- `--no-color` turns colour off for `preview` and `upgrade`. Setting `NO_COLOR` does the same.
- Auditing a single app now names the check it's running, such as "checking code signature". The interactive browser does the same while it analyses an app, so a slow app no longer looks stuck.

## 0.2.1

The command-line tool now ships inside the app, and it can check Homebrew upgrades before you install them.

### Command line

- The app now includes the `privacycommand` command-line tool. It was previously `auditctl`, which you had to build from source. Homebrew installs put it on your PATH. If you installed from the disk image, choose **privacycommand → Install Command Line Tool…**.
- `privacycommand <app>` audits one app by name or path, with `--short`, `--tree`, `--json` and `--warnings`. Run on its own, `privacycommand` opens an interactive app browser.
- `privacycommand preview` checks the apps `brew upgrade` would update. `privacycommand upgrade` downloads each new version and shows what it adds: permissions, entitlements, domains, network code, helpers and login items. It handles .dmg, .zip and .pkg casks, includes self-updating casks with `--greedy`, and lists anything it can't check.
- `--max-risk low|medium|high|critical` holds back upgrades above a risk level. With `upgrade`, it runs `brew upgrade` for the casks that pass and asks about the rest.
- Tab completion for zsh, bash and fish.

### In the app

- A permission matrix compares what an app asks for with what macOS has actually granted it, such as camera, Full Disk Access and Screen Recording.
- Optional whole-app decompilation with Ghidra, browsable by class, which can also run inside a VM. Ghidra now finds Java on its own when the app is opened from Finder.
- Import a Malimite project or a mac_apt TCC export, and browse a catalog of further security tools.
- New Settings, About window and menus, and a built-in manual under Help.
- The privacy-manifest check now reads the symbols an app actually imports. "Used but undeclared" findings now name real APIs, and the old false matches are gone.

### Before you update

- If you use VM mode, rebuild the guest agent after updating. Its protocol changed, and an older agent will report a mismatch.

## 0.2.0

The command-line tool now ships inside the app, and it can check Homebrew upgrades before you install them.

### Command line

- The app now includes the `privacycommand` command-line tool. It was previously `auditctl`, which you had to build from source. Homebrew installs put it on your PATH. If you installed from the disk image, choose **privacycommand → Install Command Line Tool…**.
- `privacycommand <app>` audits one app by name or path, with `--short`, `--tree`, `--json` and `--warnings`. Run on its own, `privacycommand` opens an interactive app browser.
- `privacycommand preview` checks the apps `brew upgrade` would update. `privacycommand upgrade` downloads each new version and shows what it adds: permissions, entitlements, domains, network code, helpers and login items. It handles .dmg, .zip and .pkg casks, includes self-updating casks with `--greedy`, and lists anything it can't check.
- `--max-risk low|medium|high|critical` holds back upgrades above a risk level. With `upgrade`, it runs `brew upgrade` for the casks that pass and asks about the rest.
- Tab completion for zsh, bash and fish.

### In the app

- A permission matrix compares what an app asks for with what macOS has actually granted it, such as camera, Full Disk Access and Screen Recording.
- Optional whole-app decompilation with Ghidra, browsable by class, which can also run inside a VM. Ghidra now finds Java on its own when the app is opened from Finder.
- Import a Malimite project or a mac_apt TCC export, and browse a catalog of further security tools.
- New Settings, About window and menus, and a built-in manual under Help.
- The privacy-manifest check now reads the symbols an app actually imports. "Used but undeclared" findings now name real APIs, and the old false matches are gone.

### Before you update

- If you use VM mode, rebuild the guest agent after updating. Its protocol changed, and an older agent will report a mismatch.

## Unreleased

Add approved release notes with `just version VERSION NOTES_FILE` before shipping.
