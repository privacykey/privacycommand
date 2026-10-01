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
# Notarization credentials (loaded from ~/.config/apple/signing.env):
#   APPLE_NOTARY_PROFILE        Preferred: saved notarytool Keychain profile.
#   or APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER
#   or APPLE_NOTARY_USER/APPLE_NOTARY_PASSWORD/APPLE_TEAM_ID.
# Xcode account login handles signing/provisioning; notarization is separate.
# See docs/apple-signing.md.
#
# Optional:
#   SCHEME                      xcodebuild scheme (default: privacycommand).
#   KEYCHAIN_PATH               Keychain holding the Developer ID identity.
#                               Set by CI (the shared workflow's ephemeral
#                               keychain); omit locally and codesign falls
#                               back to the default keychain search list.

set -euo pipefail

# Load the shared settings once, including when invoked outside just.
if [[ "${APPLE_SIGNING_LOADED:-}" != "1" ]]; then
  exec python3 "$(dirname "$0")/apple_signing.py" --exec bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Verify publication before signing/notarization; capture source before compilation.
project_command() {
  python3 "$REPO_ROOT/.project/projectctl.py" --config "$REPO_ROOT/.project/commands.json" "$@"
}
project_command source-check --channel release
PROJECT_SOURCE_RECORD="$(mktemp -t project-release-source)"
project_command source-capture "$PROJECT_SOURCE_RECORD"
trap 'rm -f "$PROJECT_SOURCE_RECORD"' EXIT

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
trap 'rm -rf "$TMP_DIR"; rm -f "$PROJECT_SOURCE_RECORD"' EXIT

# ── 1. Read the canonical marketing version ───────────────────────
VERSION="$(sed -nE 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9.]+).*/\1/p' "$REPO_ROOT/Config/Shared.xcconfig" | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read MARKETING_VERSION from Config/Shared.xcconfig" >&2
  exit 2
fi
echo "Building privacycommand v$VERSION"

# Capture one UTC build number and provenance stamp for the release.
build_identity=()
while IFS= read -r setting; do build_identity+=("$setting"); done < <(cd "$REPO_ROOT" && BUILD_CHANNEL=release scripts/buildinfo.sh)
BUILD_NUMBER="${build_identity[0]#BUILD_NUMBER=}"
echo "Using CFBundleVersion: $BUILD_NUMBER"

# ── 2. Resolve the signing identity ────────────────────────────────
# CI sets APPLE_SIGNING_IDENTITY explicitly so we sign with the exact
# cert we expect (rather than whichever Developer ID cert happens to
# come back first from the keychain). Fall back to the keychain probe
# for local dev — convenient when a developer has only one identity
# imported.
DEVELOPER_ID="${APPLE_DEVELOPER_ID_IDENTITY:-${APPLE_SIGNING_IDENTITY:-${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}}}"
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
certificate_team="$TEAM_ID"
TEAM_ID="${TEAM_ID_OVERRIDE:-${APPLE_TEAM_ID:-$certificate_team}}"
if [[ "$TEAM_ID" != "$certificate_team" ]]; then
  echo "error: configured Apple team does not match the Developer ID certificate" >&2
  exit 2
fi
echo "Using DEVELOPMENT_TEAM: $TEAM_ID"

# Resolve notarization independently from Xcode provisioning before archiving.
notary_arguments_file="$TMP_DIR/notary-args"
if ! python3 "$REPO_ROOT/scripts/apple_signing.py" --notary-args > "$notary_arguments_file"; then
  rm -f "$notary_arguments_file"
  exit 2
fi
notary_auth=()
while IFS= read -r -d '' argument; do notary_auth+=("$argument"); done < "$notary_arguments_file"
rm -f "$notary_arguments_file"

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
  "${build_identity[@]}" \
  archive

project_command record-artifact "$ARCHIVE_PATH" --source-record "$PROJECT_SOURCE_RECORD"

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

# notarytool with the configured Keychain or API credentials. `--wait` blocks until
# Apple's notarisation service returns Accepted / Invalid; on Invalid
# the command exits non-zero and `set -e` aborts the rest of the run.
xcrun notarytool submit "$ZIP_PATH" \
  "${notary_auth[@]}" \
  --wait

# Staple so Gatekeeper can verify offline.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
project_command record-artifact "$APP_PATH" --source-record "$PROJECT_SOURCE_RECORD"
project_command artifact-verify "$APP_PATH" --channel release


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
# first open. In CI, pin codesign to the ephemeral keychain the cert
# was imported into (KEYCHAIN_PATH, provided by the shared release
# workflow) so it never falls through to an interactive unlock prompt;
# locally, fall back to the default keychain search list.
if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID" --keychain "$KEYCHAIN_PATH" "$DMG_PATH"
else
  codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
fi
xcrun notarytool submit "$DMG_PATH" \
  "${notary_auth[@]}" \
  --wait
xcrun stapler staple "$DMG_PATH"
project_command record-package "$DMG_PATH" --from-artifact "$APP_PATH" --channel release


# ── 7. Package the dSYM for crash symbolication ────────────────────
# xcodebuild emits the .dSYM into the .xcarchive's dSYMs/ folder.
# Zip it into a sibling `symbols/` directory (NOT into dist/ — Sparkle's
# generate_appcast scans dist/ for .zip and would treat the dSYM bundle
# as another release archive). The workflow copies this into dist/
# *after* generate-appcast has run, so it lands as a release asset
# without confusing the appcast generator.
#
# Field crashes on a 0.1.2+ build can then be symbolicated by:
#   1. Downloading privacycommand-<version>.app.dSYM.zip from the Release.
#   2. Unzipping it.
#   3. atos -arch arm64 \
#        -o privacycommand.app.dSYM/Contents/Resources/DWARF/privacycommand \
#        -l <load-address-from-crash-report> <crashing-frame-addresses>
DSYM_SRC="$ARCHIVE_PATH/dSYMs/${SCHEME}.app.dSYM"
DSYM_OUT_DIR="$REPO_ROOT/symbols"
DSYM_ZIP="$DSYM_OUT_DIR/privacycommand-$VERSION.app.dSYM.zip"
if [[ -d "$DSYM_SRC" ]]; then
  mkdir -p "$DSYM_OUT_DIR"
  rm -f "$DSYM_ZIP"
  ( cd "$ARCHIVE_PATH/dSYMs" && \
    zip -qry "$DSYM_ZIP" "${SCHEME}.app.dSYM" )
  echo "dSYM packaged: $DSYM_ZIP"
else
  echo "warning: no dSYM at $DSYM_SRC" >&2
  echo "         The build may have DEBUG_INFORMATION_FORMAT=dwarf" >&2
  echo "         instead of dwarf-with-dsym. Field crashes for this" >&2
  echo "         release won't be symbolicatable." >&2
fi

echo
echo "──────────────────────────────────────────────"
echo "DMG ready: $DMG_PATH"
[[ -f "$DSYM_ZIP" ]] && echo "dSYM ready: $DSYM_ZIP"
echo "──────────────────────────────────────────────"
