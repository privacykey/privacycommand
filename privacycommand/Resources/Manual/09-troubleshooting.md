# Troubleshooting

## The Files tab stays empty during a run

File events come from the privileged helper. Check Settings ▸ Helper: install it, or approve it in System Settings ▸ General ▸ Login Items & Extensions if it is awaiting approval. Once the status reads Installed, start the run again.

## "Helper not bundled"

This copy of privacycommand shipped without the helper executable or its LaunchDaemon plist. The Helper tab shows the path it looked for (`Contents/Library/LaunchDaemons` inside the app). Release builds from GitHub and the Homebrew cask include it; if you built the app yourself, make sure the privacycommandHelper target was built and embedded.

## The helper refuses the connection

The helper validates callers by Team ID. The app and the helper must be signed by the same team; a self-built app with mismatched signing identities fails here. The reporting address in SECURITY.md covers anything that looks like a real security issue.

## "Block network" does nothing

The network kill switch needs the privileged helper and at least one captured destination. Let the run gather some traffic first, then try again. New destinations are not added to the block automatically: lift it and apply it again.

## The VM is "not reachable"

- Is the VM running, and has the guest finished logging in? The agent starts at login.
- Was `Install.command` run inside the guest, and did it report that the agent is listening on TCP 49374?
- Is the address right? Run `ifconfig en0 | grep inet` inside the guest; addresses change when the VM's network does.
- A version mismatch means the agent inside the VM is older or newer than this app. Rebuild the installer disk image and reinstall the agent.

## No VMs are listed for a VM tool

macOS blocked the Apple event used to read the VM list. In System Settings ▸ Privacy & Security ▸ Automation, enable the VM tool under privacycommand, then click Refresh VMs. If the tool has not finished launching, open it and refresh again. VirtualBuddy can start a VM by its exact name even when its library was not found.

## "Decompile in VM" says Ghidra is not installed

Ghidra must be installed inside the guest, not on the host. The agent looks for `support/analyzeHeadless` inside any `ghidra*` folder under `/Applications`, `~/Applications`, `/opt`, `/usr/local` or `~/Tools` in the VM.

## A ZIP archive is refused

privacycommand opens `.app` bundles and `.dmg` disk images only. Extract the archive and open the `.app` inside it.

## A monitored run fails after ejecting a disk image

The app was opened from a `.dmg` that has since been ejected, so its executable is gone. Open the image again and start the run before ejecting.

## Updates

- "This build cannot check for updates" means the build has no feed URL: a local development build, not a release.
- On a Homebrew install, update with `brew upgrade --cask privacycommand`; the Updates tab shows the command. Automatic checks stay off so Homebrew keeps control of the bundle.
- If a check fails, the feed at `privacykey.github.io` could not be reached. Check your connection and try **Check Now** again.

## Reporting a problem

Choose **privacycommand ▸ About privacycommand ▸ Report an Issue** to open the issue tracker. Include the version shown in the About window. For anything that looks like a security issue, use the private address in the repository's SECURITY.md instead of a public issue.
