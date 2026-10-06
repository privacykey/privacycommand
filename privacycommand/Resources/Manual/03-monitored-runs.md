# Monitored runs

A monitored run launches the inspected app under privacycommand and records what it does, live, until you stop it.

## Starting and stopping

- **Run ▸ Start Monitored Run** (⌘R), or the **Start run** button in the header.
- **Run ▸ Stop Monitored Run** (⌘.), or **Stop run** in the header. Stopping terminates the inspected app's process tree; so does quitting privacycommand while a run is active, so nothing is left running orphaned.

An app opened from a disk image must stay mounted for the run: ejecting the image keeps the static report readable but a run will fail because the executable is gone.

## What is captured

- **Network destinations.** Polled with `lsof` and `nettop`, with reverse-DNS labels, so the Network tab can name `8.8.8.8` as `dns.google`. No special permission needed.
- **File events.** Every file the app opens, reads, writes or creates, streamed from `fs_usage` by the privileged helper. Without the helper the Files tab stays empty. See [Settings](08-settings.md) for installing it.
- **Child processes.** Helpers and tools the app spawns, tracked as part of its process tree.
- **Probes.** Pasteboard reads, and the camera, microphone and screen-recording in-use indicators. privacycommand reads the indicators only; it never captures audio or video.
- **USB devices.** Devices connected and disconnected during the run.
- **Resource usage.** CPU and memory samples, with spikes flagged.
- **Anomalies.** Periodic beacons, bursts and undeclared hosts, derived from the captured traffic.

Everything lands in the Files, Network, Resources, Probes and Timeline tabs, and the dynamic findings join the risk score on the Summary tab.

## Pausing the app

**Run ▸ Pause App (Kill Switch)** (⇧⌘P), or **Pause** in the header, freezes the inspected app's whole process tree with SIGSTOP. While paused it cannot network, write files or run code at all. Choose the item again (**Resume App**) to continue it.

## Blocking the network

**Block network** in the header asks the privileged helper to install a `pf` anchor that drops outbound traffic to every address the app has contacted so far. The app keeps running, so you can watch how it copes with connection failures. Click again to lift the block.

Limitations: `pf` cannot filter by process, so the block is system-wide for those addresses; destinations the app has not visited yet are not blocked; and new destinations are not added automatically. Lift the block and apply it again to refresh the address set. Let the run gather some traffic first, or there is nothing to block.

## Watch mode

**Run ▸ Start Watching…** (⇧⌘W), or the eye button in the header, keeps the run alive in the menu bar. If no run is active one is started first. While watching:

- A menu bar item appears. Click it for a popover: the app's mark and name with the elapsed time, which app is being watched, and a log of what has changed since you started: new hosts contacted, new anomalies, surprising file and network events, probe activity and resource spikes. The icon fills in and shows a count while there are unread changes; opening the popover marks them read.
- **Clear Log** empties the list. **Stop Watching** (⌘↩ while the popover is open) ends the watch and the run.
- The footer has **Open privacycommand**, a gear that opens Settings (⌘,) and **Quit privacycommand** (⌘Q).
- Closing the main window does not quit the app while a watch is active; the menu bar item is your handle on the run.

The item's glyph is chosen in Settings ▸ General ▸ Menu bar. Removing the item from the menu bar (⌘-drag) stops the watch, the same as choosing **Stop Watching**.
