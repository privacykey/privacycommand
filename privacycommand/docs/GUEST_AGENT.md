# Guest Agent

`privacycommand-guest` is a small daemon that runs **inside a macOS
guest VM** so the host can inspect a target app under isolation. The
host (the privacycommand app) connects over TCP, ships
`GuestCommand`s, and consumes the `GuestObservation`s the agent
emits.

## What runs where (read this first)

VM mode is **two binaries on two machines**, not two copies of the
same app:

| Machine | Binary                   | Has UI? | Role                                                         |
|---------|--------------------------|---------|--------------------------------------------------------------|
| Host    | `privacycommand` (the app) | Yes     | The GUI you're using right now. Where you see results.       |
| Guest   | `privacycommand-guest`     | No      | Tiny background daemon. Listens for commands, ships events. |

You install `privacycommand-guest` inside the VM once. After that you
keep using the privacycommand app on your real Mac the same way you
always have — same window, same Dashboard / Static / Files / Network /
Probes tabs. When VM mode is active, observations from the VM stream
into those same tabs (with a small "VM" badge so you can tell them
apart from anything you also run on the host).

You do **not** need a second copy of the privacycommand app inside
the VM. The agent has no UI; it's just a TCP daemon.

## How you actually run an inspection in VM mode

1. **One-time setup.** Build the installer DMG from Settings → VM
   agent, attach it to your VM, run `Install.command` inside the
   guest. The agent now boots automatically at every guest login.
2. **Start the VM** and find its IP (`ifconfig en0 | grep inet`).
   Plug that IP into the host's connection panel — the host runs a
   version handshake with the agent.
3. **Get the .app you want to inspect into the VM.** Drag the .app
   (or its .dmg) onto the VM window — every supported VM tool
   accepts drops as shared files. AirDrop, scp, or downloading the
   .app inside the VM directly all also work.
4. **Drop the same .app onto the privacycommand app on your host**
   the same way you always have. When VM mode is connected, the
   host UI shows a chooser: *Inspect on host* or *Inspect in VM*.
   Pick the VM.
5. **The host sends the in-VM path to the agent**, which launches
   the bundle inside the guest, captures process / network / file /
   live-probe activity, and streams every observation back. You
   watch the same tabs you'd watch on the host — they just fill in
   with VM-side data instead.
6. **Stop the run from the host's toolbar** when you're done. The
   agent terminates the process tree inside the VM and idles until
   the next command.

## Can privacycommand attach the installer DMG to my VM automatically?

**No — and we should be upfront about why.** VirtualBuddy, UTM, and
VMware Fusion all happily accept disk-image drops onto a running VM
window (the tool mounts the image as a shared disk inside the
guest), but none of them expose a public AppleScript verb or REST
endpoint for *outside apps* to do that programmatically. Their
automation surfaces cover VM lifecycle (start / stop / list) and
not much else. Reverse-engineering each tool's private IPC channel
to attach disk images would be brittle and break on every update.

What privacycommand does instead:

1. **Builds the installer DMG** for you (Settings → VM agent → Build
   installer disk image).
2. **Detects your VM tools** and lists their VMs in the same panel.
3. **Starts a chosen VM via AppleScript** if you click Start.
4. **Reveals the DMG in Finder** with the file pre-selected when you
   click Reveal installer.
5. **You drag the highlighted file onto your VM's window** — one
   action, takes a second. The VM tool mounts the DMG as a shared
   disk inside the guest, and from there the user double-clicks
   `Install.command` to set up the agent.

That manual drag is the only step privacycommand can't do for you.
It's a one-time action per VM (the agent is installed for good after
that — no need to re-attach the DMG on subsequent host launches).

### Parallels Desktop power users

If you prefer scripting it, Parallels' command-line tool can attach
disk images:

```bash
prlctl set "auditor-guest" --device-add cdrom \
    --image "$HOME/Library/Application Support/privacycommand/privacycommand-guest-installer.dmg"
```

VirtualBuddy and UTM don't ship an equivalent CLI for image attach.
The tools' devs may add automation surfaces in future versions; if
they do, privacycommand will pick those up and move attach behind a
button. For now: drag-and-drop.

## "Helpers" — keeping the components straight

`privacycommand` has accumulated a few daemons. They're not
interchangeable:

- **`privacycommand`** (the app) — the GUI on your real Mac. Always
  needed.
- **`privacycommandHelper`** — the optional *host-side* root daemon
  for file-system monitoring of runs that happen on your host. It
  wraps `fs_usage`. Lives under Settings → Helper. **Unrelated to
  VM mode.** If you only ever inspect inside a VM, you can skip
  installing it.
- **`privacycommand-guest`** — a small daemon that runs *inside the
  VM*. This is the one that powers VM mode. Lives under Settings →
  VM agent.

Installing the helper does not install the agent and vice versa.

## Status

This is a **wire-protocol scaffold**. It builds, the host can
connect, the handshake works, and commands round-trip. The
`launchAndMonitor` flow currently only logs and acks — it doesn't
yet run the inspected app or hook up the in-guest monitors. The
intent is to link `privacycommandCore` into the guest target in a
later step so that the existing `ProcessTracker`, `NetworkMonitor`,
`ResourceMonitor`, `LiveProbeMonitor`, and `DeviceUsageProbe` classes
can be reused as-is — they're all libproc / lsof / Core-API queries
that work the same inside a guest as on the host.

## Architecture

```
                  ┌────────────────────────────────────────┐
                  │ Host: privacycommand app                │
                  │                                        │
   GuestCommand ──┤ GuestObservationStream  (Core)         │
                  │   • opens TCP socket                   │
                  │   • length-prefixed JSON frames        │
                  │   • exposes AsyncStream<Observation>   │
                  └─────────────────┬──────────────────────┘
                                    │ TCP   (default port 49374)
                                    │
                  ┌─────────────────┴──────────────────────┐
                  │ Guest VM: privacycommand-guest          │
                  │                                        │
                  │ GuestAgent  (privacycommandGuestAgent)  │
                  │   • single-tenant TCP listener         │
                  │   • dispatches GuestCommand → action   │
                  │   • streams GuestObservation back      │
                  └────────────────────────────────────────┘
```

Both sides depend on `privacycommandGuestProtocol` for the Codable
types and the length-prefixed JSON framing.

## Wire format

Every message is a `GuestEnvelope` serialised as JSON, then framed:

```
[ 4 bytes: payload length, big-endian UInt32 ]
[ N bytes: JSON-encoded GuestEnvelope        ]
```

Messages are bidirectional. Hosts send `.command(GuestCommand)`,
guests send `.observation(GuestObservation)`. See
`Sources/privacycommandGuestProtocol/GuestProtocol.swift` for the
full type list.

## Building the guest agent

From the project root, *inside the guest VM*:

```bash
swift build -c release --product privacycommand-guest
sudo cp .build/release/privacycommand-guest /usr/local/bin/
```

Cross-compiling on the host and copying in via shared folder also
works on Apple Silicon — both sides are arm64.

## Running

```bash
privacycommand-guest                 # listens on 49374
privacycommand-guest --port 50000    # custom port
```

The agent logs to stderr. To run as a launchd job at login, drop a
plist into `~/Library/LaunchAgents/org.privacykey.privacycommand.guest.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>org.privacykey.privacycommand.guest</string>
  <key>ProgramArguments</key> <array>
    <string>/usr/local/bin/privacycommand-guest</string>
  </array>
  <key>RunAtLoad</key>       <true/>
  <key>KeepAlive</key>       <true/>
  <key>StandardErrorPath</key> <string>/var/log/privacycommand-guest.err</string>
</dict>
</plist>
```

Then `launchctl load ~/Library/LaunchAgents/org.privacykey.privacycommand.guest.plist`.

## Connecting from the host

```swift
let stream = GuestObservationStream()
try await stream.connect(to: .init(host: "192.168.64.4", port: 49374))
try await stream.performHandshake()

try await stream.send(.launchAndMonitor(
    bundlePathInGuest: "/Users/auditor/Apps/Foo.app"))

for await obs in await stream.observations {
    switch obs {
    case .processEvent(let pid, _, _, let path, _):
        print("guest pid=\(pid) → \(path)")
    case .networkEvent(let pid, let name, let host, _, _, _, _, _, _):
        print("\(name) [\(pid)] → \(host ?? "?")")
    case .targetExited(let code, _):
        print("target exited code=\(code)")
        break
    default: continue
    }
}
```

## VirtualBuddy

[VirtualBuddy](https://github.com/insidegui/VirtualBuddy) is the
easiest path on Apple Silicon — it's open-source, has a clean
SwiftUI front-end, and ships a working AppleScript dictionary.

1. **Install VirtualBuddy** (`brew install --cask virtualbuddy`) and
   create a macOS guest in the standard wizard. Boot it, finish the
   guest's first-run setup, and create your auditor user account.
2. **In privacycommand**, open Settings → "VM agent" and click
   **Build installer disk image**. The DMG lands in
   `~/Library/Application Support/privacycommand/`.
3. The settings panel auto-detects VirtualBuddy and lists every VM
   it knows about. Click **Start** next to your auditor VM, then
   **Reveal installer** — the DMG file will be selected in Finder.
4. **Drag the DMG onto the VirtualBuddy window** of the running VM.
   VirtualBuddy auto-mounts the image into the guest.
5. Inside the guest, double-click **Install.command** from the
   mounted volume.

VirtualBuddy automation surface used:

```applescript
tell application "VirtualBuddy"
    set vmList to {}
    repeat with vm in (every virtual machine)
        set end of vmList to (name of vm)
    end repeat
    return vmList

    start virtual machine named "auditor-guest"
end tell
```

## UTM

[UTM](https://mac.getutm.app) works on both Intel and Apple Silicon,
which is the relevant difference. Setup is the same shape as
VirtualBuddy but UTM's mounted-image attach is via the menu bar
inside the guest's UTM window (USB devices → Removable Drives →
attach the DMG path).

1. Install UTM and create a macOS guest. UTM's "macOS Quickstart"
   wizard handles the IPSW download.
2. Build the installer DMG from privacycommand's Settings → VM agent.
3. Click **Start** next to your VM in the panel; UTM brings the VM up.
4. In the running UTM VM window, **Removable Drives → Mount image…**
   and pick the DMG. (Alternatively drag-drop also works — UTM accepts
   `.dmg` drops as removable media.)
5. Inside the guest, double-click **Install.command**.

If you've enabled UTM Server (UTM 4.5+, for remote control from the
iOS UTM app), the AppleScript path still works the same — UTM Server
is just an additional control surface, not a replacement.

## Parallels Desktop / VMware Fusion

Both work because the agent is just a TCP daemon and the installer
is a stock DMG. Their AppleScript dictionaries are sparser, so the
Settings panel might not auto-list their VMs — just drag the DMG
onto the running VM window manually. The Install.command flow
inside the guest is identical.

## Connecting after install

Inside the VM:

```bash
ifconfig en0 | grep "inet "
# inet 192.168.64.5 netmask 0xffffff00 broadcast ...
```

Back on the host, plug `192.168.64.5:49374` into privacycommand's
connect panel. The host runs the version handshake, and you're
streaming.

## What's still TODO

1. **Link `privacycommandCore` into the guest agent.** The monitors
   already work on any macOS — they just need to be wired into
   `GuestAgent.handleEnvelope` so `launchAndMonitor` actually
   launches the bundle and starts streaming events.
2. **Bundle transfer.** The host needs a way to ferry the .app into
   the guest. Easy options: shared folder via `VZSharedDirectory`,
   guest-side scp from the host, or a host-served static fileshare
   the guest mounts.
3. **VM lifecycle wrapper.** A `VirtualMachineCoordinator` host-side
   class that uses Virtualization.framework to boot a guest from a
   stored macOS image, wait for the agent to come online, and tear
   the VM down on disconnect. This is non-trivial — Apple Silicon
   only, requires a 15+ GB macOS guest image, license-acceptance
   flow, etc.
4. **Reconnection.** Today if the guest reboots or the network
   blips, the host has to manually re-`connect()`. A retry-with-
   backoff loop would be friendlier.
5. **Bundle path mapping.** Paths inside the guest aren't the same
   as on the host. The UI needs to label these clearly so users
   don't get confused when the Files tab shows
   `/Users/auditor/Apps/Foo.app` (guest) instead of the path they
   dropped on the host.
