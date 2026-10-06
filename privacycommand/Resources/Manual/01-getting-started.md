# Getting started

privacycommand takes a `.app` bundle (or a `.dmg` disk image) and reports what the app actually touches: the entitlements it claims, the permissions it will ask for, the domains and URLs compiled into its binary, the third-party SDKs it ships, the login items and helpers it registers and, if you let it, what it does while it runs.

Every finding carries a plain-English explanation from the in-app knowledge base, so a report is readable without a reverse-engineering background. All analysis happens on your Mac; the app ships no analytics of its own.

## What you need

- macOS 14 or later.
- Nothing else for static analysis and network monitoring. File-event monitoring, the Background Task Management audit and the network kill switch need the optional privileged helper. See [Settings](08-settings.md).

## First launch

The first time privacycommand runs it opens **Welcome to privacycommand**, a five-step tour:

1. **Welcome.** What the app does.
2. **Static analysis.** What is read from the bundle without running it.
3. **Network monitoring.** How destinations are captured during a run.
4. **File monitoring (optional).** Installs the privileged helper if you want file events.
5. **You're all set.**

You can skip it at any step. To see it again later choose **Help ▸ Welcome to privacycommand**.

## Opening an app

- Drag a `.app` bundle or a `.dmg` onto the main window, or
- choose **File ▸ Open .app…** (⌘O) and pick one.

A disk image is mounted read-only, the first `.app` inside is analysed, and an eject button appears in the header until you dismiss it. ZIP archives are not supported: extract them first.

Static analysis runs straight away and the window fills with the report. Analysing an app you have opened before reuses the cached report; see [Settings](08-settings.md) for the cache.

## The main window

The header shows the app's name and bundle identifier, its risk tier, the signing team (click it for the developer name and Team ID) and the run controls. Below it the report is split into tabs:

- **Summary.** The executive summary, the risk score and its contributors, the SDK heat map, App Store privacy labels, declared and inferred permissions, and the findings.
- **Static.** Everything read from the bundle. See [Static analysis](02-static-analysis.md).
- **Files.** File events from a monitored run (needs the helper).
- **Network.** Destinations contacted during a run, with reverse-DNS labels.
- **Resources.** What the app is holding open right now during a run: files, sockets and other resources, refreshed every poll cycle and filterable by kind, process and name.
- **Probes.** Camera, microphone, screen-recording and pasteboard activity during a run.
- **Timeline.** Every event of the run in order.
- **History.** Saved runs, with compare. See [History and compare](06-history-and-compare.md).

Monitored runs are covered in [Monitored runs](03-monitored-runs.md).

## The knowledge base

Every ⓘ button in a report opens the knowledge base entry for that finding. To browse the whole thing, choose **View ▸ Knowledge Base…** (⇧⌘K): a searchable window of every article, grouped by category.
