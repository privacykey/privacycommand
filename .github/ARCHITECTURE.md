# privacycommand — Architecture

A high-level orientation. The user-facing pitch is in [`README.md`](README.md); the source-tree map is in [`privacycommand/README.md`](privacycommand/README.md). This doc sits between them — what the boxes are, why they're separate, and how data moves between them.

The deeper design docs referenced from the project `README.md` sit alongside this one:
[`HELPER.md`](../privacycommand/HELPER.md) for the privileged helper,
[`BUILDING.md`](../privacycommand/BUILDING.md) for the two build paths, and
[`docs/GUEST_AGENT.md`](../privacycommand/docs/GUEST_AGENT.md) for VM mode.

> **One-line model.** A SwiftUI app drops a `.app` bundle onto a pure-Swift analyzer library, optionally launches the inspected app under a privileged XPC helper for dynamic monitoring, and optionally ships a guest agent into a macOS VM to do the same work in isolation.

> **Scale note.** The codebase is substantial: 225 Swift files. The analyzer
> (`Sources/privacycommandCore/Analysis/`) has 41 detector files, monitoring has 12, and
> the app target has 63 SwiftUI files. The [`README.md`](../README.md) carries the
> user-facing pitch; this file covers the internals.

---

## The targets, and why each pulls its weight

```
┌──────────────────────────────────────────────────────────────────────┐
│                       privacycommand.app                             │
│  ┌────────────────────┐    ┌────────────────────┐                    │
│  │  privacycommand    │    │ privacycommandCore │  pure Swift,       │
│  │  (SwiftUI + AppKit)│───▶│   (analyzer)       │  no AppKit         │
│  └─────────┬──────────┘    └────────────────────┘                    │
│            │                         ▲                               │
│            │ XPC                     │ analyze(bundleAt:)            │
│            ▼                         │                               │
│  ┌──────────────────────┐            │                               │
│  │ privacycommandHelper │  privileged: fs_usage, sfltool,            │
│  │ (root, SMAppService) │  pfctl. Validates clients by Team ID.      │
│  └──────────────────────┘                                            │
└──────────────────────────────────────────────────────────────────────┘

         ┌──────────────────────────┐  ┌────────────────────────┐
         │ auditctl (CLI)           │  │ privacycommandGuestAgent│
         │ smallest end-to-end smoke│  │ runs in a macOS VM,    │
         │ test for the analyzer    │  │ ships observations back│
         │                          │  │ via shared protocol    │
         └──────────────────────────┘  └────────────────────────┘
                  ▲                              ▲
                  └────── Sources/privacycommandGuestProtocol/ ────┘
                          (zero-dep wire format)
```

Each target is intentional:

| Target | Path | Role |
|---|---|---|
| `privacycommandCore` | `privacycommand/Sources/privacycommandCore/` | Pure-Swift analyzer. AppKit-free. Runs from CLI, tests, GUI, and helper without dragging UI deps into builds that don't need them. |
| `privacycommand` (app) | `privacycommand/Sources/privacycommand/` | SwiftUI app target. Views + view-models only. |
| `privacycommandHelper` | `privacycommand/privacycommandHelper/` | Privileged XPC service installed via `SMAppService.daemon`. Minimal API surface — 5 Swift files (`main`, `HelperToolService`, `CodeSignValidator`, `FsUsageRunner`, `PfctlKillSwitch`). Validates clients by Team ID on connect. **Note the path**: this sits beside `Sources/`, not inside it — it is an Xcode-only target and `Package.swift` does not declare it. |
| `privacycommandGuestProtocol` | `privacycommand/Sources/privacycommandGuestProtocol/` | Wire format shared between host and guest agent. Lives in its own zero-dependency target so the agent can build without compiling Core. |
| `privacycommandGuestAgent` | `privacycommand/Sources/privacycommandGuestAgent/` | The binary that runs inside a macOS VM and ships observations back to the host. |
| `auditctl` | `privacycommand/Sources/auditctl/` | CLI front-end for the analyzer, with a witr-style interface. `auditctl <name-or-path>` audits one app (`--short` / `--tree` / `--json` / `--warnings`); a bare `auditctl` (or `-i`) opens an interactive TUI browser of installed apps. Still the fastest end-to-end smoke test. The executable is a thin termios / poll-loop / IO shell — its logic lives in `auditctlKit`. |
| `auditctlKit` | `privacycommand/Sources/auditctlKit/` | Pure, testable CLI/TUI logic: ANSI styling, terminal input decoding, the browser state model + reducer, and frame rendering. Split out of the executable so `auditctlKitTests` can cover it without a real terminal. |

The split is enforced by Swift Package Manager — `Package.swift` declares each as a separate target with an explicit dependency graph. You can't accidentally pull AppKit into Core because Core's manifest doesn't depend on it.

## What gets analyzed

Three layers of signal, each with a different cost:

| Layer | Where | Privilege |
|---|---|---|
| **Static** — entitlements, code-signing, notarization (stapler/spctl/SHA-256), URL schemes, document types, hard-coded domains, embedded launch agents, third-party SDK fingerprints (LaunchDarkly, Firebase, Mixpanel, AdMob, …), feature flags / trial-state strings, secrets and license-key names, anti-analysis signals, dylib hijacking surface, Privacy Manifest cross-check | `Sources/privacycommandCore/Analysis/` (41 detector files: `StaticAnalyzer`, `EntitlementsReader`, `MachOInspector`, `BundleSigningAuditor`, `NotarizationDeepDive`, `SDKFingerprintDetector`, `SecretsScanner`, `RPathAuditor`, `AntiAnalysisDetector`, `PrivacyManifestReader`, …) | **None.** Runs on the user's data without ever touching Apple-granted entitlements. |
| **Dynamic** — file events, network destinations, child processes, pasteboard / camera / microphone / screen-recording activity, USB device interactions, resource usage | `Sources/privacycommandCore/Monitoring/` (12 files: `DynamicMonitor`, `LiveProbeMonitor`, `NetworkMonitor`, `ProcessTracker`, `USBDeviceMonitor`, `ResourceMonitor`, `DeviceUsageProbe`, `VMHostDetection`, `GuestObservationStream`, …) | **Helper required** for `fs_usage`-based file events; Background Task Management audit also goes via the helper to skip the admin prompt. |
| **App Store cross-reference** — Mac App Store privacy labels fetched from `apps.apple.com`, displayed next to the static-analysis findings | `Sources/privacycommandCore/Analysis/AppStoreLookup.swift` + `AppStorePrivacyLabelFetcher.swift` | None. Network call is keyed on bundle ID, never user data. |

The privacy-stance contract: **all analysis runs locally**. The inspected app's contents never leave the machine. The only outbound traffic is bounded — DNS reverse lookups for destinations the inspected app contacts, App Store privacy-label lookups against `itunes.apple.com`/`apps.apple.com`, and Sparkle appcast fetch from `privacykey.github.io`.

## How an audit runs (current shape)

```
User drags App.app onto privacycommand
        │
        ▼
ContentView → AnalysisCoordinator (view-model)
        │
        ▼
StaticAnalyzer().analyze(bundleAt:) ─── runs purely in-process
        │
        ▼
StaticReport (Codable) ─── feeds Dashboard, Static, Telemetry, Background-tasks tabs
        │
        ▼
[Optional] Dynamic monitoring                       [Optional] VM mode
   │                                                    │
   ▼                                                    ▼
HelperToolService over XPC                       Guest agent in VM
   ├── FsUsageRunner (file events)                  ├── runs same analyzer locally
   ├── BackgroundTaskAuditor (sfltool)              └── ships observations via
   └── PfctlKillSwitch (pf-anchor                       privacycommandGuestProtocol
       network kill switch)
        │
        ▼
Live observations stream into the Monitoring tab
        │
        ▼
Reporting (JSON / HTML / PDF) ─── Sources/privacycommandCore/Reporting/
```

## Sandbox & entitlements

Two distinct entitlement surfaces, both deliberately small.

**App** (`Resources/privacycommand.entitlements`):

- App Sandbox: **OFF** — the app launches arbitrary inspected apps and shells out.
- Hardened Runtime: **ON**.
- `com.apple.security.network.client`: **ON** — DNS reverse lookups, App Store privacy-label fetches, Sparkle appcast.
- No `allow-jit`, no `disable-library-validation`, no Apple-granted entitlements.

**Helper** (`Resources/privacycommandHelper.entitlements`):

- App Sandbox: **OFF** — must spawn `/usr/bin/fs_usage`, `/usr/bin/sfltool`, `/sbin/pfctl`.
- Hardened Runtime: **ON**.
- `com.apple.developer.service-management.managed-by-main-app`: **ON** — required for `SMAppService.daemon` lifecycle.

The helper rejects clients whose Team ID doesn't match its own — see `CodeSignValidator.swift`. This is the load-bearing piece of the trust model: the helper runs as root, accepts XPC connections only from binaries signed with the same Team ID.

## The guest agent

privacycommand can analyze apps you'd rather not run on your bare-metal machine by booting a macOS VM (VirtualBuddy, UTM, or Parallels), installing the guest agent inside, and treating the VM as a remote worker.

- Wire format: `privacycommandGuestProtocol/GuestProtocol.swift` — a single `Codable` schema both sides import.
- Host side: `privacycommand` GUI ships requests across the VM boundary and renders observations as they come in.
- Guest side: `privacycommandGuestAgent/main.swift` listens for commands, runs the same `privacycommandCore` analyzer locally inside the VM, and replies.
- Walkthroughs per VM platform: [`privacycommand/docs/GUEST_AGENT.md`](privacycommand/docs/GUEST_AGENT.md).

The VM mode reuses the analyzer; it doesn't reimplement it. Hardened-runtime entitlements landed on the guest helper today (commit `e48fee6`) — that's what unlocks distributing it as a signed binary.

## Reporting

Every finding is exportable as JSON, HTML, or PDF. Live in `Sources/privacycommandCore/Reporting/`. The PDF exporter is the one place AppKit creeps into otherwise-pure code, so it lives in the **app** target (`privacycommand/Sources/privacycommand/Reporting/`), not Core. JSON and HTML export are AppKit-free and live in Core.

## Persistence

Run reports are persisted on disk for diffing across audits — `Sources/privacycommandCore/Persistence/`. The format is the canonical Codable types from `privacycommandCore/Models/` (e.g., `StaticReport`, `AppStoreInfo`). Run search index lives alongside in `Sources/privacycommandCore/Search/`.

## Updates and distribution

| Channel | How updates work |
|---|---|
| **Direct download** | DMG with Sparkle 2 in-app updater. Auto-checks **off by default**; user opts in via Settings → Updates. |
| **Homebrew cask** | `brew upgrade --cask privacycommand`. privacycommand detects Cask installs and disables Sparkle's installer to stay out of brew's way — see `Sources/privacycommandCore/Updates/`. |

The appcast feed lives on `gh-pages` at `https://privacykey.github.io/privacycommand/appcast.xml`, signed with EdDSA. The Sparkle keypair is per-app, **never shared with another product** — leaking one shouldn't compromise another product's update channel. The pipeline itself lives in [privacykey/gh-workflows](https://github.com/privacykey/gh-workflows); [`.github/workflows/release.yml`](workflows/release.yml) is the thin caller and documents the secret layout.

## Knowledge Base (in-app)

`Sources/privacycommandCore/KnowledgeBase/` is intended as the single source of truth for "what does this finding mean?" — the goal is that every detector has a paired KB entry with a plain-English explanation. Today the directory contains a single Swift file (`PrivacyKeyDatabase.swift` actually lives in `Analysis/`, alongside the detectors that read from it) — most detector explanations are inline string constants today rather than centralised entries.



## Testing

`Tests/privacycommandCoreTests/` holds the analyzer test suite. Run with `swift test` from `privacycommand/`. Static analysis is straightforward to test against a corpus of `.app` bundles; dynamic monitoring needs more thought (the helper-required tests can't run in CI without `SMAppService` permissions).

The smallest end-to-end smoke test is `auditctl /System/Applications/Calculator.app` — exits non-zero if `StaticAnalyzer` fails to parse anything.

## Where to look next

| Question | Doc |
|---|---|
| Source-tree map (contributor-facing) | [`privacycommand/README.md`](privacycommand/README.md) |
| Privileged helper bundling + signing + verification | [`privacycommand/HELPER.md`](privacycommand/HELPER.md) |
| Guest agent walkthroughs | [`privacycommand/docs/GUEST_AGENT.md`](privacycommand/docs/GUEST_AGENT.md) |
| Build workflow (Xcode + SPM) | [`privacycommand/BUILDING.md`](privacycommand/BUILDING.md) |
| Release pipeline + secrets | [`.github/workflows/release.yml`](workflows/release.yml) + [privacykey/gh-workflows](https://github.com/privacykey/gh-workflows) |

**Last reviewed:** 29 April 2026.
