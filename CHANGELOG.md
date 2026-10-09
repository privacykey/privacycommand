# Changelog

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
