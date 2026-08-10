# Privacy and telemetry posture

privacycommand is a privacy tool and behaves like one. This page states exactly
what it sends and what it does not, so you can check the claim rather than take
it. This content used to live in the top-level [`README.md`](../README.md).

## No analytics

privacycommand ships no analytics SDKs. There is no telemetry endpoint, no
install counter, and no crash-report bucket. The Swift package manifest declares
no third-party dependencies at all, and the Xcode project adds exactly one —
[Sparkle 2](https://sparkle-project.org), for in-app updates.

## All analysis runs locally

The contents of the app you inspect never leave your machine. Static analysis,
disassembly, decompilation, monitoring and report generation all happen on the
host (or, in VM mode, inside your own virtual machine).

## The network calls it does make

They are explicit and bounded:

- **Reverse DNS lookups** for the destinations the inspected app contacts, so the
  Network tab can label `8.8.8.8` as `dns.google`.
- **Mac App Store privacy-label lookups** against `itunes.apple.com` and
  `apps.apple.com`, keyed by the inspected app's bundle identifier — never by
  anything about you.
- **The Sparkle appcast fetch** from `privacykey.github.io` when you check for
  updates. Automatic checks are off by default; you opt in under
  Settings → Updates. Homebrew Cask installs suppress the in-app updater
  entirely.
- **Incoming-build downloads**, only when you explicitly ask for them: the
  `auditctl preview --fetch` path retrieves a cask artifact from its own
  publisher so it can be diffed against the version you have installed.

`com.apple.security.network.client` is the only entitlement covering outbound
network access. The app also holds `com.apple.security.automation.apple-events`,
which is not network access: it lets the guest-agent panel ask installed VM
front-ends (VirtualBuddy, UTM, Parallels, VMware) over AppleScript which VMs
exist. The hardened-runtime escapes are deliberately absent — no `allow-jit`, no
`allow-dyld-environment-variables`, no `disable-library-validation`.

## The privileged helper is opt-in

Without the helper, privacycommand still works — you lose file-event monitoring,
and the Background Task Management audit asks before triggering an admin prompt.
The helper is a minimal XPC service installed through `SMAppService.daemon`; it
validates callers by Team ID on connect, and its whole job is to run
`fs_usage`, `sfltool` and `pfctl` on the app's behalf. See
[`privacycommand/HELPER.md`](../privacycommand/HELPER.md).
