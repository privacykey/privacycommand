privacycommand-guest agent installer
====================================

This disk image installs the privacycommand-guest daemon inside a
macOS virtual machine. After install, the host privacycommand app
can connect to the VM over TCP and observe whatever apps you launch
inside it — without those apps running on your real Mac.

To install
----------
1. Double-click Install.command.
2. Enter your password when sudo asks (we copy the binary to
   /usr/local/bin and load a user LaunchAgent).
3. Wait for the "✓ privacycommand-guest is listening on TCP 49374"
   confirmation.

That's it. The agent starts at every login from now on.

Connecting from the host
-----------------------
Find the VM's IP:

    ifconfig en0 | grep "inet "

Then point the privacycommand app at that IP, port 49374. The host
will perform a version handshake with the agent and stream
observations back across the VM boundary.

Uninstalling
------------

    launchctl bootout gui/$(id -u)/org.privacykey.privacycommand.guest
    rm ~/Library/LaunchAgents/org.privacykey.privacycommand.guest.plist
    sudo rm /usr/local/bin/privacycommand-guest

Compatibility
-------------
- Works inside any macOS 13+ guest (Apple Silicon or Intel).
- Tested with VirtualBuddy and UTM. Parallels and VMware Fusion
  guests should work too — the agent is just a TCP daemon.
- The installer is signed by the same Team ID as the host app; if
  Gatekeeper complains, right-click → Open the first time.
