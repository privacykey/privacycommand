#!/bin/bash
#
# Builds privacycommand-guest in release mode and packages it into a
# read/write disk image alongside the LaunchAgent plist, the
# Install.command script, and a short README. The resulting DMG can
# be attached to any macOS VM (VirtualBuddy, UTM, Parallels, plain
# Virtualization.framework) — the user double-clicks Install.command
# inside the guest to set up the daemon.
#
# Used by the SwiftUI "Build installer DMG" button. Safe to run
# directly from a shell, too.
#
# Usage:
#   ./Scripts/build-guest-installer.sh [output-dir]
#
# Default output: ~/Library/Application Support/privacycommand/

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$HOME/Library/Application Support/privacycommand}"
mkdir -p "$OUT_DIR"

DMG_NAME="privacycommand-guest-installer"
DMG_PATH="$OUT_DIR/$DMG_NAME.dmg"
STAGING="$(mktemp -d -t privacycommand-guest-installer)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Building privacycommand-guest (release)"
( cd "$ROOT" && swift build -c release --product privacycommand-guest )

BIN_PATH="$ROOT/.build/release/privacycommand-guest"
[[ -f "$BIN_PATH" ]] || { echo "Build didn't produce $BIN_PATH"; exit 1; }

echo "==> Staging payload in $STAGING"
cp "$BIN_PATH"                                                   "$STAGING/privacycommand-guest"
cp "$ROOT/Resources/GuestInstaller/org.privacykey.privacycommand.guest.plist" "$STAGING/"
cp "$ROOT/Resources/GuestInstaller/Install.command"              "$STAGING/"
cp "$ROOT/Resources/GuestInstaller/README.txt"                   "$STAGING/"
chmod +x "$STAGING/privacycommand-guest" "$STAGING/Install.command"

# A .DS_Store would be nice for icon positions but we keep it
# simple and skip the customisation — the README plus the obvious
# Install.command name is enough.

echo "==> Packaging into $DMG_PATH"
# Remove a previous DMG with the same name; hdiutil refuses to
# overwrite.
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
