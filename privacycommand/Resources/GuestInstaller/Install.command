#!/bin/bash
#
# Run inside the macOS guest VM to install privacycommand-guest as a
# user launch agent. Idempotent — safe to re-run after a guest reboot
# or to upgrade to a newer build.
#
# This script is shipped on the installer DMG built by
# `Scripts/build-guest-installer.sh`. The user double-clicks it from
# inside their VM after attaching the DMG.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$SCRIPT_DIR/privacycommand-guest"
PLIST_SRC="$SCRIPT_DIR/org.privacykey.privacycommand.guest.plist"
BIN_DEST="/usr/local/bin/privacycommand-guest"
PLIST_DEST="$HOME/Library/LaunchAgents/org.privacykey.privacycommand.guest.plist"
LABEL="org.privacykey.privacycommand.guest"

cyan="\033[1;36m"; green="\033[1;32m"; red="\033[1;31m"; reset="\033[0m"
info()  { echo -e "${cyan}==>${reset} $*"; }
ok()    { echo -e "${green}✓${reset} $*"; }
fail()  { echo -e "${red}✗${reset} $*" >&2; exit 1; }

# Sanity checks ─────────────────────────────────────────────────────────────
[[ -f "$BIN_SRC"   ]] || fail "Couldn't find privacycommand-guest next to this installer."
[[ -f "$PLIST_SRC" ]] || fail "Couldn't find org.privacykey.privacycommand.guest.plist next to this installer."

# Stop any previous instance so the binary copy doesn't fail on busy file ─
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    info "Found existing agent — bootout first…"
    launchctl bootout "gui/$(id -u)/$LABEL" || true
fi

# Copy the binary into /usr/local/bin (sudo prompt) ─────────────────────────
info "Installing binary to $BIN_DEST (sudo will prompt)…"
sudo install -m 755 "$BIN_SRC" "$BIN_DEST"
ok   "Binary installed."

# Drop the LaunchAgent plist into the user's LaunchAgents folder ────────────
info "Installing LaunchAgent at $PLIST_DEST"
mkdir -p "$HOME/Library/LaunchAgents"
install -m 644 "$PLIST_SRC" "$PLIST_DEST"
ok   "Plist installed."

# Bootstrap the agent into the user's launchd domain ────────────────────────
info "Loading the agent into launchd…"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
ok   "Agent loaded."

# Verify it's listening ─────────────────────────────────────────────────────
sleep 1
if lsof -nP -iTCP:49374 -sTCP:LISTEN | grep -q privacycommand-guest; then
    ok "privacycommand-guest is listening on TCP 49374."
else
    echo
    echo -e "${red}Agent isn't listening on 49374 yet.${reset}"
    echo "Check $HOME/Library/LaunchAgents/org.privacykey.privacycommand.guest.plist and the logs at /tmp/privacycommand-guest.log"
    echo "and re-run this installer."
    exit 1
fi

cat <<EOF

────────────────────────────────────────────
  privacycommand-guest installed.
────────────────────────────────────────────

The agent is now running and will start at every login.

From your host, point the privacycommand app at this VM's IP and
port 49374 to connect. Run \`ifconfig en0 | grep inet\` inside this
VM if you don't already know the address.

To uninstall:
    launchctl bootout gui/\$(id -u)/$LABEL
    rm $PLIST_DEST
    sudo rm $BIN_DEST

EOF
