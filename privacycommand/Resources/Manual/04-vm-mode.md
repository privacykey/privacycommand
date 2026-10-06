# VM mode

VM mode runs the inspected app inside a separate macOS virtual machine, for apps you would rather not run on bare metal. Everything is set up in Settings ▸ VM agent.

## What runs where

Two binaries are involved, on two machines:

- **On your Mac (host):** the privacycommand app you are using. Same window, same tabs. When VM mode is active, observations from the VM stream into the same Summary, Files, Network and Probes tabs, tagged with a small VM badge.
- **Inside the VM (guest):** a small daemon called `privacycommand-guest`. It has no UI; it listens for commands from the host on TCP 49374 and ships observations back. You install it once and forget about it.

You do not need a second copy of the privacycommand app inside the VM, only the agent.

## The one manual step

privacycommand can start a VM and reveal the installer disk image in Finder for you, but it cannot attach the image to the VM: VirtualBuddy, UTM, Parallels Desktop and VMware Fusion expose no public way for outside apps to mount a disk image into a running guest. So once the image is built, drag it onto your VM's window. Every supported tool accepts the drop and mounts the image as a shared disk inside the guest. (Parallels users can alternatively run `prlctl set <vm> --device-add cdrom --image=...`.)

## Setting up, once

1. **Build the installer disk image.** Settings ▸ VM agent ▸ Installer disk image ▸ **Build Disk Image** compiles `privacycommand-guest` in release mode and packages it, with its LaunchAgent plist and `Install.command`, into a small `.dmg`. It takes about 30 seconds the first time. The image is kept in `~/Library/Application Support/privacycommand`; **Reveal** selects it in Finder and **Rebuild** makes a fresh one.
2. **Start the VM.** The VM tools section lists VirtualBuddy, UTM, Parallels Desktop and VMware Fusion when they are installed, with each tool's VMs and a **Start** button. VirtualBuddy can also start a VM by name when its library is not where the scan looks. If macOS blocks the Apple event that reads the VM list, enable the tool under privacycommand in System Settings ▸ Privacy & Security ▸ Automation and click **Refresh VMs**.
3. **Attach the image.** Drag the revealed `.dmg` onto the running VM window.
4. **Inside the VM:** open the **privacycommand-guest** volume in the guest's Finder, double-click **Install.command** and enter your password when `sudo` asks. Wait for the confirmation that the agent is listening on TCP 49374. The agent now starts automatically at every guest login.
5. **Note the VM's address:** `ifconfig en0 | grep inet` inside the guest.

## Running an app in the VM

1. In Settings ▸ VM agent ▸ Guest agent, enter the VM's IP address and port and click **Test Connection**. The status line reports the handshake: connected (with the guest's macOS and agent version), a version mismatch (rebuild the image and reinstall the agent), or not reachable (check the VM is running, the agent is installed, and the address is right).
2. Get the `.app` you want to inspect into the VM: drag it (or its `.dmg`) onto the VM window, AirDrop it, scp it, or download it inside the VM.
3. Type the path of the `.app` inside the VM, for example `/Users/you/Downloads/Foo.app`, and click **Run in VM**. The agent launches the app inside the guest, monitors its process tree, network, file activity and probes, and ships every observation back over the same socket.
4. Stop the run with **Stop VM Run**, or the usual Stop in the header. The agent terminates the process tree inside the VM and goes back to idle.

## Decompiling in the VM

The Decompile in VM section offloads a whole-app decompilation to the guest. Pick the scope (named classes or everything) and click **Decompile in VM**; the reconstructed classes stream back one at a time and open in the same class browser the local decompiler uses. The guest VM must have Ghidra installed (the agent looks in the same places the host does: `/Applications`, `~/Applications`, `/opt`, `/usr/local` and `~/Tools`). If it is not, the agent says so and nothing else happens.

## The helpers, told apart

privacycommand has a few helper components that do separate jobs:

- **privacycommand (the app).** The GUI on your real Mac. Always needed.
- **privacycommandHelper (the file-monitoring helper).** Settings ▸ Helper. A root daemon on your host Mac that wraps `fs_usage` for runs on the host. Unrelated to VM mode; if you only use VM mode you do not need it.
- **privacycommand-guest (the VM agent).** Settings ▸ VM agent. A daemon that runs inside the VM, not on your host. It is what makes VM mode work.
