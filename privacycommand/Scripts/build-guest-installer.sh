#!/bin/bash
#
# Builds the privacycommand-guest installer DMG. The DMG bundles a
# pre-built `privacycommand-guest` Mach-O alongside its LaunchAgent
# plist, an Install.command bootstrapper, and a short README — the
# user attaches the DMG to their macOS guest VM (VirtualBuddy, UTM,
# Parallels, plain Virtualization.framework) and double-clicks
# Install.command inside the guest to set up the daemon.
#
# Two run modes:
#
#   1. Shipped mode (the common one). The script lives inside the
#      privacycommand.app bundle at Contents/Resources/, alongside a
#      pre-built `privacycommand-guest` binary and the GuestInstaller
#      payload. We just stage and pack — no swift toolchain required
#      on the user's machine.
#
#   2. Dev mode. The script is at <repo>/privacycommand/Scripts/.
#      Package.swift sits two levels up. We fall through to
#      `swift build -c release --product privacycommand-guest` to
#      produce the binary, then proceed.
#
# Usage:
#   ./build-guest-installer.sh [output-dir]
#
# Default output dir: ~/Library/Application Support/privacycommand/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$HOME/Library/Application Support/privacycommand}"
mkdir -p "$OUT_DIR"

DMG_NAME="privacycommand-guest-installer"
DMG_PATH="$OUT_DIR/$DMG_NAME.dmg"
STAGING="$(mktemp -d -t privacycommand-guest-installer)"
trap 'rm -rf "$STAGING"' EXIT

# ─── Locate the pre-built guest binary + payload ─────────────────

BIN_PATH=""
PLIST_PATH=""
INSTALL_PATH=""
README_PATH=""

# Mode 1: shipped — script's directory is the .app's Resources, and
# the binary + payload sit right next to us.
if [[ -f "$SCRIPT_DIR/privacycommand-guest" ]]; then
    BIN_PATH="$SCRIPT_DIR/privacycommand-guest"
    PLIST_PATH="$SCRIPT_DIR/org.privacykey.privacycommand.guest.plist"
    INSTALL_PATH="$SCRIPT_DIR/Install.command"
    README_PATH="$SCRIPT_DIR/README.txt"
fi

# Mode 2: dev — fall back to a SwiftPM build. The script's parent
# (Scripts/) sits next to Package.swift in the dev tree.
if [[ -z "$BIN_PATH" ]]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -f "$REPO_ROOT/Package.swift" ]]; then
        echo "==> Dev mode: building privacycommand-guest via SwiftPM"
        ( cd "$REPO_ROOT" && swift build -c release --product privacycommand-guest )
        BIN_PATH="$REPO_ROOT/.build/release/privacycommand-guest"
        PLIST_PATH="$REPO_ROOT/Resources/GuestInstaller/org.privacykey.privacycommand.guest.plist"
        INSTALL_PATH="$REPO_ROOT/Resources/GuestInstaller/Install.command"
        README_PATH="$REPO_ROOT/Resources/GuestInstaller/README.txt"
    fi
fi

# Final sanity — clear error if neither mode resolved a binary.
if [[ -z "$BIN_PATH" || ! -f "$BIN_PATH" ]]; then
    echo "error: couldn't locate privacycommand-guest." >&2
    echo "       Tried:" >&2
    echo "         (shipped) $SCRIPT_DIR/privacycommand-guest" >&2
    echo "         (dev)     $SCRIPT_DIR/../Package.swift" >&2
    echo "       This is a build problem — the privacycommand .app should ship" >&2
    echo "       the pre-built guest binary inside Contents/Resources/." >&2
    exit 1
fi

for f in "$PLIST_PATH" "$INSTALL_PATH" "$README_PATH"; do
    if [[ ! -f "$f" ]]; then
        echo "error: missing required payload file: $f" >&2
        exit 1
    fi
done

# ─── Stage payload ───────────────────────────────────────────────

echo "==> Staging payload in $STAGING"
cp "$BIN_PATH"     "$STAGING/privacycommand-guest"
cp "$PLIST_PATH"   "$STAGING/"
cp "$INSTALL_PATH" "$STAGING/"
cp "$README_PATH"  "$STAGING/"
chmod +x "$STAGING/privacycommand-guest" "$STAGING/Install.command"

# ─── Build the DMG ───────────────────────────────────────────────

echo "==> Packaging into $DMG_PATH"
[[ -f "$DMG_PATH" ]] && rm "$DMG_PATH"

hdiutil create \
    -volname "privacycommand-guest" \
    -srcfolder "$STAGING" \
    -ov \
    -fs HFS+ \
    -format UDZO \
    "$DMG_PATH" \
    >/dev/null

echo "==> Done. DMG at:"
echo "    $DMG_PATH"
echo
echo "Attach this DMG to your macOS guest VM (VirtualBuddy, UTM, etc.),"
echo "then double-click Install.command from inside the guest."
