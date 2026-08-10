# Contributing to privacycommand

Issues and pull requests are welcome. This file holds the setup detail that used
to sit in the top-level [`README.md`](README.md).

## Two build paths

The repository builds the same sources two ways. `Package.swift` and the Xcode
project both live under `privacycommand/`, not at the repository root.

**Swift Package Manager** builds the headless pieces — the `privacycommandCore`
analyser, the `auditctl` CLI and its `auditctlKit` half, the guest agent, and the
shared guest protocol. This is the fast iteration loop and it is what CI runs:

```sh
cd privacycommand
swift build
swift test
```

From the repository root, [`just`](https://github.com/casey/just) wraps the same
commands: `just build`, `just test`, `just clean`.

**Xcode** is the only path that builds and ships the GUI app, because the SwiftUI
app target and the privileged-helper target exist only in the project file:

```sh
cd privacycommand
open privacycommand.xcodeproj
```

On a fresh checkout you need to do two things once:

1. **File → Add Package Dependencies…** → `https://github.com/sparkle-project/Sparkle`,
   Up to Next Major from `2.9.1` (the version the project file pins). Tick the
   `Sparkle` product on the `privacycommand` target.
2. Select the **privacycommand** and **privacycommandHelper** targets in turn →
   Signing & Capabilities → set Team. Both must match, or the helper will refuse
   the app's XPC connection at runtime.

Then ⌘B. Everything else — the Copy Files phases that place the helper and its
LaunchDaemon plist inside the bundle, the entitlements, the target dependency —
is already wired in the project.

Deeper references live next to the sources:

- [`privacycommand/README.md`](privacycommand/README.md) — source-tree map, why
  each target exists, signing and entitlements quick reference, troubleshooting.
- [`privacycommand/HELPER.md`](privacycommand/HELPER.md) — privileged helper
  bundling, signing and the verification recipe.
- [`privacycommand/docs/GUEST_AGENT.md`](privacycommand/docs/GUEST_AGENT.md) —
  building and deploying the in-VM guest agent.
- [`.github/ARCHITECTURE.md`](.github/ARCHITECTURE.md) — how the pieces fit
  together and how data moves between them.

## The auditctl CLI

`auditctl` is a command-line front end over the same analyser, useful for
scripting and CI. Build it once, then call the binary directly:

```sh
cd privacycommand
swift build -c release
BIN=.build/release/auditctl
```

A one-shot static audit takes a path or an installed-app name:

```sh
$BIN /System/Applications/Calculator.app
$BIN slack --short          # one-line verdict
$BIN slack --tree           # frameworks / XPC / helpers / login-item tree
$BIN slack --json           # machine-readable
$BIN slack --warnings       # findings section only
$BIN slack --exact          # exact name match instead of substring
$BIN slack --warn-exit      # exit 1 when there are warn/error findings
```

Exit codes: `0` analysed cleanly · `1` analysis failed, or `--warn-exit` with
findings · `2` bad arguments or target not found · `4` ambiguous name.

The `preview` command inspects app updates before you take them. With no
arguments it checks your outdated Homebrew casks:

```sh
$BIN preview
$BIN preview --all-apps --only-noteworthy --min-tier warn
$BIN preview --json
$BIN preview --fetch firefox   # download the incoming build and diff it
```

`preview` is inform-only: it never runs `brew`, never blocks an update, and
always exits 0. It understands `.dmg` and `.zip` cask artifacts; `.pkg` is
skipped. With `--fetch`, an incoming build is analysed *before* Gatekeeper has
cleared it, so a one-off notarization difference can simply be a fresh-download
artifact — the output flags this when it happens.

Running `auditctl` with no arguments opens an interactive browser when stdin and
stdout are a terminal, and prints usage otherwise so CI callers do not hang.

## What CI runs

Two workflows run on every pull request against `main`:

- [`ci.yml`](.github/workflows/ci.yml) — builds every SPM target, runs the full
  test suite, then runs the built `auditctl` against `Calculator.app` as an
  end-to-end smoke test of the analyser's exit-code contract.
- [`app-ci.yml`](.github/workflows/app-ci.yml) — an unsigned Xcode build and test
  of the app target, through a reusable workflow in `privacykey/gh-workflows`.
  This one also runs on pushes to `main`.

Run `swift test` from `privacycommand/` before opening a pull request and confirm
it passes.

## Before you open a pull request

- For UI changes, attach a before/after screenshot.
- For a new analysis signal, add a Knowledge Base entry alongside the detector.
  privacycommand explains what every finding means in plain English, and that
  contract is worth keeping.
- Releases are cut by tagging: `just release <version>`, where the tag must match
  `MARKETING_VERSION` in the Xcode project. The pipeline itself lives in
  `privacykey/gh-workflows`; [`.github/workflows/release.yml`](.github/workflows/release.yml)
  is a thin caller and documents the secrets it needs.

## Security issues

Do not open a public issue for a vulnerability. [`.github/SECURITY.md`](.github/SECURITY.md)
has the reporting address, the response times I aim for, and what is in and out
of scope.
