#!/usr/bin/env bash
# release.sh — build → codesign → notarize → DMG, all in one shot.
#
# Designed to run inside CI (.github/workflows/release.yml) but works
# locally too if you've imported the Developer ID cert into the
# default keychain and stashed the notary credentials in your
# environment.
#
# Outputs:
#   dist/privacycommand-<version>.dmg — signed + notarized + stapled
#
# Required environment:
#   APPLE_NOTARY_USER           Apple ID for notarytool.
#   APPLE_NOTARY_PASSWORD       App-specific password.
#   APPLE_NOTARY_TEAM_ID        Apple Developer team ID.
#
# Optional:
#   DEVELOPER_ID                Override the Developer ID common name
#                               (defaults to the first matching cert
#                               in the keychain).
#   SCHEME                      xcodebuild scheme (default: privacycommand).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/privacycommand"

SCHEME="${SCHEME:-privacycommand}"
CONFIG="Release"
ARCHIVE_PATH="$REPO_ROOT/dist/${SCHEME}.xcarchive"
EXPORT_PATH="$REPO_ROOT/dist/export"
DIST_DIR="$REPO_ROOT/dist"
mkdir -p "$DIST_DIR"

# ── 1. Resolve the version from Info.plist ─────────────────────────
PLIST="$REPO_ROOT/privacycommand/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read CFBundleShortVersionString from $PLIST" >&2
  exit 2
fi
echo "Building privacycommand v$VERSION"

# ── 2. Resolve the signing identity ────────────────────────────────
DEVELOPER_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$DEVELOPER_ID" ]]; then
  echo "error: no Developer ID Application identity found in keychain" >&2
  exit 2
fi
echo "Signing as: $DEVELOPER_ID"

# ── 3. Archive the app target ──────────────────────────────────────
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  CODE_SIGN_STYLE=Manual \
  archive

# ── 4. Export the .app from the archive ────────────────────────────
EXPORT_OPTIONS_PLIST="$REPO_ROOT/dist/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>            <string>developer-id</string>
  <key>signingStyle</key>      <string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath  "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: exported .app missing at $APP_PATH" >&2
  exit 2
fi

# ── 5. Notarize ────────────────────────────────────────────────────
ZIP_PATH="$DIST_DIR/${SCHEME}-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --apple-id    "$APPLE_NOTARY_USER" \
  --password    "$APPLE_NOTARY_PASSWORD" \
  --team-id     "$APPLE_NOTARY_TEAM_ID" \
  --wait

# Staple so Gatekeeper can verify offline.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ── 6. Build the DMG ───────────────────────────────────────────────
DMG_PATH="$DIST_DIR/privacycommand-$VERSION.dmg"
rm -f "$DMG_PATH"
DMG_STAGING="$(mktemp -d)"
trap 'rm -rf "$DMG_STAGING"' EXIT
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "privacycommand" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

# Sign + staple the DMG itself so the download isn't quarantined on
# first open.
codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id    "$APPLE_NOTARY_USER" \
  --password    "$APPLE_NOTARY_PASSWORD" \
  --team-id     "$APPLE_NOTARY_TEAM_ID" \
  --wait
xcrun stapler staple "$DMG_PATH"

echo
echo "──────────────────────────────────────────────"
echo "DMG ready: $DMG_PATH"
echo "──────────────────────────────────────────────"
