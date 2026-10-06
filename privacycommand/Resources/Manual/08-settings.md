# Settings

Open Settings with **privacycommand ▸ Settings…** (⌘,) or from the gear in the watch-mode popover. There are four tabs.

## General

- **Run history.** Whether every run is saved automatically (see [History and compare](06-history-and-compare.md)), how many runs are saved, **Show in Finder**, and **Delete All Runs…**. Deleting asks you to confirm and then to type DELETE: saved reports cannot be recovered.
- **Analysis cache.** Opening an app you have already analysed reuses its cached static report. The row shows how many reports are cached and their size; **Clear Cache…** asks once, then clears them. Nothing is lost: an app is simply analysed again the next time you open it.
- **Menu bar.** The glyph for the watch-mode menu bar item (eye, magnifier, binoculars, radar or shield) and whether a watch is active. The item is only shown while you watch an app; see [Monitored runs](03-monitored-runs.md).
- **About privacycommand** opens the About window.

## Helper

The privileged helper runs as a root daemon under launchd. It accepts XPC connections only from privacycommand, signed by the same Team ID, and its whole job is to run `fs_usage` for file events, read Background Task Management, and install the network kill switch's `pf` rules. It stops when a run ends and unloads after a few seconds idle. Without it the app still works; you lose file-event monitoring and the kill switch, and the Background Task Management audit asks before an admin prompt.

The tab shows the helper's status and the one action it needs next:

- **Not installed:** **Install Helper** registers it with macOS.
- **Awaiting approval:** macOS wants you to allow it. **Open System Settings** takes you to General ▸ Login Items & Extensions, where you turn privacycommand on. The status updates when you return.
- **Installed:** **Test Connection** checks the XPC link; **Uninstall Helper…** removes it after a confirmation.
- **Helper not bundled:** this copy of the app shipped without the helper. The tab shows the path it looked for; see [Troubleshooting](09-troubleshooting.md).

## VM agent

Builds the guest installer, starts VMs, connects to the guest agent, runs an app inside the VM and decompiles there. The whole flow is in [VM mode](04-vm-mode.md).

## Updates

privacycommand updates itself with Sparkle from a signed feed at `privacykey.github.io`. The tab shows the version you are running and when it last checked.

- **Check for updates automatically** is off until you turn it on. privacycommand contacts the feed only when this is on or when you check by hand. Pick **Daily**, **Weekly** or **Monthly** for the frequency.
- **Check Now** checks straight away; **privacycommand ▸ Check for Updates…** does the same from the menu bar.
- **Release Notes** opens the releases page on GitHub.

If this copy was installed with Homebrew Cask, the tab says so and shows the `brew upgrade --cask privacycommand` command with a **Copy** button. Homebrew stays in charge of the on-disk bundle: automatic checks are turned off at every launch, and a manual check still tells you when a new version exists.

## About

**privacycommand ▸ About privacycommand** opens the About window: the icon and wordmark, the version and build, what the app does, links to the source on GitHub and to report an issue, this manual, the Keyboard Shortcuts window, the acknowledgements for bundled third-party code, and the licence line.
