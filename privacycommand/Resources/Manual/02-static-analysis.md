# Static analysis

Static analysis reads the bundle without running it. It is what fills the window the moment you open an app, and it never needs the helper.

## What is read

- **Info.plist and entitlements.** The usage-description keys the app declares (camera, microphone, contacts and so on), its URL schemes and document types, and every entitlement it claims. Declared permissions are compared with what the binary appears able to use.
- **Code signing.** Whether the bundle is signed, by which Team ID, and the developer name expanded from the signing certificate (or the App Store seller name for App Store builds).
- **Notarisation.** A deep dive through the stapled ticket, `spctl` and the bundle's SHA-256.
- **Hard-coded domains and URLs.** Hosts and URL literals found in the binary, classified by category (analytics, advertising, cloud and so on), with false positives filtered out.
- **SDK fingerprints.** Which analytics, advertising and attribution SDKs the bundle ships, with a heat-graded count and a per-category breakdown.
- **Outbound call sites.** Functions that can open a connection, the networking symbols they reach for (BSD sockets, `getaddrinfo`, CFNetwork, `nw_*`), and any host or URL literal sitting next to them.
- **Embedded launch agents and helpers.** LaunchAgents, LaunchDaemons, XPC services, login items and privileged helpers packaged inside the bundle.
- **Feature flags, trial state, secrets and licence keys.** String scans for flag names, trial counters, API-key shapes and licence-key names.
- **Anti-analysis signals.** Debugger, VM and jailbreak checks, and obfuscation markers.
- **Dylib hijacking surface.** `@rpath` entries and library load paths that could be hijacked.
- **Privacy manifest.** Apple's `PrivacyInfo.xcprivacy`, checked against what the binary actually uses.
- **Frameworks and resources.** Embedded frameworks and bundles, and the resources the app ships.
- **App Store privacy labels.** For Mac App Store bundles, the developer's declared Privacy Nutrition Labels are fetched and shown beside the static findings so you can see whether the claims match the binary. This is the one static lookup that goes to the network, keyed by the inspected app's bundle identifier only.

## Background Task Management

The Static tab also lists every login item, launch agent, daemon and helper the app has registered with macOS. Reading that registry needs administrator rights: with the privileged helper installed it happens silently; without it, privacycommand asks before triggering an admin prompt.

## Decompiling

Any outbound call site can be decompiled on demand if Ghidra is installed on your Mac, and the Static tab can reconstruct the app's classes and functions with a local Ghidra install (the first run analyses the binary; results are cached). privacycommand looks for `support/analyzeHeadless` inside any `ghidra*` folder under `/Applications`, `~/Applications`, `/opt`, `/usr/local` or `~/Tools`. To keep the heavy work off your Mac, decompile inside a VM instead; see [VM mode](04-vm-mode.md).

## The risk score

The Summary tab aggregates the static findings (and, after a run, the dynamic ones) into a risk tier with explainable contributors. Every contributor and every finding has an ⓘ button that opens its knowledge base entry.
