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
#   APPLE_SIGNING_IDENTITY      Common-name string of the Developer ID
#                               Application cert, e.g.
#                               "Developer ID Application: PrivacyKey (TEAMID)".
#                               Optional locally — falls back to picking the
#                               first matching identity in the keychain.
#
#   APPLE_API_KEY_PATH          Path to the App Store Connect API key (.p8).
#   APPLE_API_KEY_ID            10-character Key ID associated with the .p8.
#   APPLE_API_ISSUER            Issuer UUID from App Store Connect → Keys.
#
#   notarytool's API-key auth is preferred over the legacy
#   --apple-id/--password/--team-id triple because it's revocable per-key
#   in one click and immune to Apple ID 2FA prompts. The legacy path is
#   no longer wired up here — if you need it for an emergency local run,
#   call notarytool directly.
#
# Optional:
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

# Single staging area for transient build artefacts (the notarize-zip
# upload payload, the DMG staging tree). Nothing here should ever end
# up in dist/ — Sparkle's `generate_appcast` scans dist/ for archives
# and refuses to publish if it sees more than one with the same bundle
# version, so leaving notarize.zip next to the DMG breaks the appcast
# step. Cleaned up unconditionally on script exit (success or failure).
TMP_DIR="$(mktemp -d -t privacycommand-release)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── 1. Resolve the version from the Xcode project ─────────────────
# Info.plist's CFBundleShortVersionString is now $(MARKETING_VERSION) —
# Xcode resolves it at build time. PlistBuddy on the static file would
# return the placeholder string, so we ask xcodebuild for the resolved
# value. -showBuildSettings is a read-only dry-run; it doesn't compile
# anything, but does load the project.
VERSION=$(xcodebuild \
    -project "$REPO_ROOT/privacycommand/privacycommand.xcodeproj" \
    -target "$SCHEME" \
    -configuration "$CONFIG" \
    -showBuildSettings \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from privacycommand target" >&2
  echo "       Make sure Xcode has Marketing Version set under Project →" >&2
  echo "       privacycommand → General → Identity." >&2
  exit 2
fi
echo "Building privacycommand v$VERSION"

# Auto-incrementing CFBundleVersion: count of git commits on HEAD.
# Sparkle requires CFBundleVersion to monotonically increase across
# releases, and `git rev-list --count HEAD` grows with every push to
# main, so we get that for free. CI does fetch-depth: 0 so this works
# in GitHub Actions; locally the result is whatever your full clone
# has, which is also fine for dry-runs.
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
echo "Using CFBundleVersion: $BUILD_NUMBER"

# ── 2. Resolve the signing identity ────────────────────────────────
# CI sets APPLE_SIGNING_IDENTITY explicitly so we sign with the exact
# cert we expect (rather than whichever Developer ID cert happens to
# come back first from the keychain). Fall back to the keychain probe
# for local dev — convenient when a developer has only one identity
# imported.
DEVELOPER_ID="${APPLE_SIGNING_IDENTITY:-${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}}"
if [[ -z "$DEVELOPER_ID" ]]; then
  echo "error: no Developer ID Application identity available" >&2
  echo "       Set APPLE_SIGNING_IDENTITY explicitly, or import a Developer ID" >&2
  echo "       Application cert into your login keychain." >&2
  exit 2
fi
echo "Signing as: $DEVELOPER_ID"

# Extract the 10-character team ID from the trailing "(TEAMID)" of the
# identity string. The Developer ID format is fixed by Apple:
#
#   "Developer ID Application: <Common Name> (TEAMID)"
#
# We pass this as DEVELOPMENT_TEAM= to xcodebuild so the team that
# xcodebuild expects always agrees with the team baked into the cert.
# Without this override, xcodebuild falls back to the project's
# hardcoded DEVELOPMENT_TEAM in project.pbxproj — which is fine as
# long as nobody ever changes Apple Developer teams or imports a cert
# from a different team, but breaks confusingly the first time those
# go out of sync ("No certificate for team X matching Y found").
TEAM_ID="$(printf '%s' "$DEVELOPER_ID" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
if [[ -z "$TEAM_ID" ]]; then
  echo "error: could not extract team ID from APPLE_SIGNING_IDENTITY=$DEVELOPER_ID" >&2
  echo "       Expected suffix '(TEAMID)' where TEAMID is a 10-char alphanumeric." >&2
  echo "       If your Apple Developer team ID has a non-standard format, override" >&2
  echo "       this by exporting TEAM_ID before invoking the script." >&2
  exit 2
fi
TEAM_ID="${TEAM_ID_OVERRIDE:-$TEAM_ID}"
echo "Using DEVELOPMENT_TEAM: $TEAM_ID"

# ── 2b. Validate notarytool credentials ────────────────────────────
# All three are required; checking up front means we fail in seconds
# rather than after the 5-minute archive build.
: "${APPLE_API_KEY_PATH:?APPLE_API_KEY_PATH must point to the App Store Connect .p8 file}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID must be the 10-char Key ID}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER must be the App Store Connect issuer UUID}"
if [[ ! -f "$APPLE_API_KEY_PATH" ]]; then
  echo "error: APPLE_API_KEY_PATH=$APPLE_API_KEY_PATH does not exist" >&2
  exit 2
fi

# ── 3. Archive the app target ──────────────────────────────────────
# Build settings overridden on the CLI win against anything in
# project.pbxproj. We force Manual signing (so xcodebuild doesn't try
# to talk to Apple's automatic-provisioning service from CI), pin the
# identity, and pin the team explicitly so the project's hardcoded
# DEVELOPMENT_TEAM doesn't have to match the cert.
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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
  <!-- teamID is required when method=developer-id and signingStyle=manual.
       Some Xcode versions accept omission and infer from the cert; later
       ones (16+) reject the export with a confusing "could not find
       distribution code signing identity". Always include it. -->
  <key>teamID</key>            <string>${TEAM_ID}</string>
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
# Stage the upload zip in TMP_DIR (not DIST_DIR) so Sparkle's appcast
# generator doesn't pick it up as a release artefact. The zip exists
# only to ship the .app to Apple's notary service; once stapling is
# done it has no further purpose.
ZIP_PATH="$TMP_DIR/${SCHEME}-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# notarytool with App Store Connect API key auth. `--wait` blocks until
# Apple's notarisation service returns Accepted / Invalid; on Invalid
# the command exits non-zero and `set -e` aborts the rest of the run.
xcrun notarytool submit "$ZIP_PATH" \
  --key         "$APPLE_API_KEY_PATH" \
  --key-id      "$APPLE_API_KEY_ID" \
  --issuer      "$APPLE_API_ISSUER" \
  --wait

# Staple so Gatekeeper can verify offline.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ── 6. Build the DMG ───────────────────────────────────────────────
DMG_PATH="$DIST_DIR/privacycommand-$VERSION.dmg"
rm -f "$DMG_PATH"
# Staging dir lives in TMP_DIR (cleaned up by the trap at the top of
# the script) — overriding the EXIT trap with a second one here would
# leak TMP_DIR.
DMG_STAGING="$TMP_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
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
  --key         "$APPLE_API_KEY_PATH" \
  --key-id      "$APPLE_API_KEY_ID" \
  --issuer      "$APPLE_API_ISSUER" \
  --wait
xcrun stapler staple "$DMG_PATH"

echo
echo "──────────────────────────────────────────────"
echo "DMG ready: $DMG_PATH"
echo "──────────────────────────────────────────────"
