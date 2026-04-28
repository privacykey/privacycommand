# privacycommand — source tree

This folder is the source tree for the privacycommand macOS app. The
top-level [`README.md`](../README.md) is what end-users read; this
README is for contributors hacking on the codebase.

## Two ways in

```sh
# 1. Open the Xcode project — supported way to build / ship the GUI.
open privacycommand.xcodeproj

# 2. Build the analyzer + CLI from the command line.
swift build           # compiles privacycommandCore + auditctl + the
                      # guest agent + the helper
swift test            # runs Tests/privacycommandCoreTests
```

Both share the same `Sources/`. The Xcode project takes everything and
adds a SwiftUI app target plus a privileged-helper target on top; SPM
builds the headless pieces.

## What's already wired in the Xcode project

You don't need to do any of the manual target-creation / Copy-Files
fiddling that earlier versions of this README walked through. The
`privacycommand.xcodeproj` already contains:

- The **privacycommand** app target with all of `Sources/privacycommand/`,
  the JSON resources, and the asset catalog.
- The **privacycommandHelper** target compiling the privileged helper,
  signed with the same Team ID as the app, hardened runtime on,
  entitlements pointed at `Resources/privacycommandHelper.entitlements`,
  and CFBundleIdentifier baked into the Mach-O via
  `GENERATE_INFOPLIST_FILE`.
- A target dependency from the app to the helper, plus two **Copy
  Files** phases that drop the helper executable into
  `Contents/MacOS/` and the LaunchDaemon plist into
  `Contents/Library/LaunchDaemons/`.
- Sparkle 2 wired in for in-app updates (you have to add it once via
  **File → Add Package Dependencies…** — see the top-level README).

The one thing you do need to do on first checkout:

1. Open `privacycommand.xcodeproj`.
2. Select the **privacycommand** and **privacycommandHelper** targets
   in turn → Signing & Capabilities → set Team. Both must match.
3. ⌘B.

See [`HELPER.md`](HELPER.md) for the full helper-bundling story and
verification recipe.

## Folder layout

```
privacycommand/
├── Package.swift                         # SPM manifest (Sparkle dep + 4 targets)
├── privacycommand.xcodeproj/             # GUI build, see top of this README
├── HELPER.md                             # Privileged helper bundling + signing
├── docs/
│   └── GUEST_AGENT.md                    # VirtualBuddy / UTM / Parallels walkthroughs
├── Resources/
│   ├── Info.plist                        # App's Info.plist — Sparkle keys live here
│   ├── privacycommand.entitlements       # App entitlements (sandbox OFF, network client ON)
│   ├── privacycommandHelper.entitlements # Helper entitlements (SMAppService managed-by-main-app)
│   ├── org.privacykey.privacycommand.HelperTool.plist  # LaunchDaemon plist
│   ├── PrivacyKeyDatabase.json           # NSCameraUsageDescription → "Camera" etc.
│   ├── PathClassifier.json               # path-prefix rules
│   ├── RiskRules.json                    # risk classifier rules
│   └── Assets.xcassets/                  # AppIcon
├── Scripts/
│   └── build-guest-installer.sh          # Builds the guest-agent installer DMG
├── Sources/
│   ├── privacycommandCore/               # Pure-Swift logic. NO AppKit / SwiftUI.
│   │   ├── Models/                       # Codable types (StaticReport, AppStoreInfo, …)
│   │   ├── Analysis/                     # Static analyzers (40+ files)
│   │   ├── Monitoring/                   # Dynamic monitors (network, file, USB, …)
│   │   ├── Classification/               # Path / domain / risk classifiers
│   │   ├── Reporting/                    # JSON / HTML / PDF / diff exporters
│   │   ├── IPC/                          # XPC protocol shared with the helper
│   │   ├── Persistence/                  # Run-report on-disk format
│   │   ├── KnowledgeBase/                # In-app explanations (single source of truth)
│   │   ├── Search/                       # Run search index
│   │   └── Updates/                      # Sparkle preferences + Homebrew detector
│   ├── privacycommand/                   # SwiftUI app target — UI only.
│   │   ├── privacycommandApp.swift
│   │   ├── ContentView.swift
│   │   ├── ViewModels/                   # AnalysisCoordinator, HelperInstaller, UpdateController, …
│   │   ├── Views/                        # All the SwiftUI surfaces
│   │   └── Reporting/                    # PDF exporter (uses AppKit)
│   ├── privacycommandHelper/             # Privileged XPC helper.
│   │   ├── main.swift
│   │   ├── HelperToolService.swift       # XPC implementation
│   │   ├── CodeSignValidator.swift       # Team-ID match check on connect
│   │   ├── FsUsageRunner.swift           # /usr/bin/fs_usage wrapper
│   │   └── PfctlKillSwitch.swift         # pf-anchor network kill switch
│   ├── privacycommandGuestProtocol/      # Wire format shared by host + guest agent.
│   │   └── GuestProtocol.swift
│   ├── privacycommandGuestAgent/         # In-VM agent.
│   │   └── main.swift
│   └── auditctl/                         # CLI smoke test for the static analyzer.
│       └── main.swift
└── Tests/
    └── privacycommandCoreTests/
```

## Why so many targets

Each pulls its weight:

- **privacycommandCore** is the analyzer. Pure-Swift, no UI deps, so it
  runs from `swift test` in CI, the helper, and the guest agent
  without dragging AppKit in.
- **privacycommandHelper** is the only thing that runs as root.
  Minimal API surface (file events, kill-switch, sfltool dump).
  Validates clients by Team ID.
- **privacycommandGuestProtocol** is the wire format the host and the
  in-VM guest agent share. Lives in its own zero-dependency target so
  the guest agent can be built without compiling Core.
- **privacycommandGuestAgent** is the binary that runs inside a macOS
  VM, listens for commands from the host, and ships observations
  back across the VM boundary. See [`docs/GUEST_AGENT.md`](docs/GUEST_AGENT.md).
- **auditctl** is a tiny CLI that runs `StaticAnalyzer().analyze(...)`
  against a path and prints the result. Fastest smoke test you can
  write.

## Signing & entitlements quick reference

App (`Resources/privacycommand.entitlements`):

- App Sandbox: **OFF** — we launch arbitrary apps and shell out.
- Hardened Runtime: **ON**.
- `com.apple.security.network.client`: **ON** — DNS reverse lookups
  for inspected-app destinations + Sparkle appcast + App Store
  privacy-label fetches. No other outbound traffic.
- No `allow-jit`, no `disable-library-validation`, no
  Apple-granted entitlements.

Helper (`Resources/privacycommandHelper.entitlements`):

- App Sandbox: **OFF** — must spawn `/usr/bin/fs_usage`,
  `/usr/bin/sfltool`, `/sbin/pfctl`.
- Hardened Runtime: **ON**.
- `com.apple.developer.service-management.managed-by-main-app`:
  **ON** — required for `SMAppService.daemon` lifecycle.

## Building from the command line

```sh
swift build -c release
.build/release/auditctl /System/Applications/Calculator.app
```

`auditctl` is the smallest end-to-end smoke test for the analyzer —
it runs `StaticAnalyzer().analyze(bundleAt:)` and pretty-prints the
resulting `StaticReport`. Exits non-zero on parse failure.

## Troubleshooting

**`proc_listallpids` / `proc_pidinfo` not found on `import Darwin`.**
On most macOS SDK versions, `import Darwin` exposes `<libproc.h>`. If
Xcode complains, add a one-line bridging header:

```c
#include <libproc.h>
#include <sys/sysctl.h>
```

…and point Build Settings → "Objective-C Bridging Header" at it.

**Test target can't see `LSOFEntry`.** The tests use
`@testable import privacycommandCore`. If you've moved the tests
into a different target without `@testable`, make
`NetworkMonitor.LSOFEntry` and `parseLSOFLine` `public`.

**Helper installs but XPC connection is refused.** The helper rejects
clients whose Team ID doesn't match its own. Confirm both targets
have the same Team set in Signing & Capabilities. See `HELPER.md`'s
verification recipe.

**Build fails resolving Sparkle.** The Xcode project depends on
Sparkle via SPM. First-time contributors need to do **File → Add
Package Dependencies…** once for `https://github.com/sparkle-project/Sparkle`
(Up to Next Major from `2.9.0`). After that, `Package.resolved`
caches the version for everyone.
