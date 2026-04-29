#!/usr/bin/env bash
# generate-appcast.sh — wraps Sparkle's `generate_appcast` against a
# directory of release DMGs.
#
# Sparkle's tool is what signs each DMG with the EdDSA private key and
# emits the `<sparkle:edSignature>` attribute that the running app
# verifies before applying an update. Running it in CI keeps the key
# out of developer machines.
#
# Inputs (env or first arg):
#   DIST_DIR — directory containing one or more <App>-<version>.dmg
#              files. Defaults to ./dist.
#   APPCAST_DIR — where the appcast.xml ends up. Defaults to ./dist.
#
# Required environment for signing:
#   SPARKLE_PRIVATE_KEY — base64-encoded EdDSA private key, generated
#     once with Sparkle's `generate_keys` tool. Stored in 1Password +
#     mirrored to a GitHub Actions secret.
#
# The matching public half goes into Info.plist's `SUPublicEDKey`. See
# docs/RELEASES.md for the full release flow.

set -euo pipefail

DIST_DIR="${1:-${DIST_DIR:-./dist}}"
APPCAST_DIR="${APPCAST_DIR:-$DIST_DIR}"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "error: distribution directory '$DIST_DIR' does not exist" >&2
  exit 2
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "error: SPARKLE_PRIVATE_KEY is unset" >&2
  echo "       Generate one with Sparkle's bin/generate_keys, then put" >&2
  echo "       the secret part in 1Password and the public part in" >&2
  echo "       Resources/Info.plist's SUPublicEDKey." >&2
  exit 2
fi

# Validate the key format up front so we fail with a clear pointer to
# docs/RELEASES.md instead of Sparkle's fairly opaque "Failed to
# decode private and public keys from secret data" error.
#
# Sparkle's decodePrivateAndPublicKeys (in Sparkle/common_cli/Secret.swift)
# base64-decodes the file contents once and accepts:
#   • 32 bytes — new "regular seed" format. Sparkle derives the
#     ed25519 keypair from this seed at sign time via
#     ed25519_create_keypair. This is what current `generate_keys`
#     produces.
#   • 96 bytes — legacy "hashed seed" format (64-byte private +
#     32-byte public concatenated). Older keys.
# Anything else is rejected. The most common failure mode is double
# base64-encoding — `generate_keys -x` already writes base64, so an
# extra `| base64` step at export time produces a string that decodes
# back to base64 text (~88 bytes), not 32 binary bytes.
SPARKLE_KEY_DECODED_BYTES="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
if [[ "$SPARKLE_KEY_DECODED_BYTES" != "32" && "$SPARKLE_KEY_DECODED_BYTES" != "96" ]]; then
  echo "error: SPARKLE_PRIVATE_KEY base64-decodes to $SPARKLE_KEY_DECODED_BYTES bytes; Sparkle expects 32 (new) or 96 (legacy)." >&2
  echo "       The most common cause is double base64-encoding when exporting." >&2
  echo "       Re-export with:" >&2
  echo "         ./privacycommand/.build/checkouts/Sparkle/bin/generate_keys -x ~/sparkle-private.key" >&2
  echo "         pbcopy < ~/sparkle-private.key" >&2
  echo "       and update the SPARKLE_PRIVATE_KEY environment secret with the value as-is" >&2
  echo "       (do NOT pipe through base64 again). See docs/RELEASES.md for details." >&2
  exit 2
fi

# Sparkle ships `generate_appcast` as a binary inside the SPM
# checkout. CI does `git clone https://github.com/sparkle-project/Sparkle`
# and adds bin/ to PATH; locally the developer can use Homebrew's
# `brew install --cask sparkle` and find the binary in the resulting
# `.app/Contents/Resources/`.
GENERATE_APPCAST="${GENERATE_APPCAST:-generate_appcast}"
if ! command -v "$GENERATE_APPCAST" >/dev/null 2>&1; then
  echo "error: '$GENERATE_APPCAST' not found on PATH" >&2
  echo "       Install Sparkle's CLI tools (brew install --cask sparkle)" >&2
  echo "       or set GENERATE_APPCAST to the full binary path." >&2
  exit 2
fi

# Stash the key in a temp file — Sparkle's tool wants a file path.
KEY_FILE="$(mktemp -t sparkle-private)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

# `--ed-key-file` makes the tool sign each DMG it finds in DIST_DIR
# with the supplied private key. `-o` writes the appcast to the
# requested location instead of the default DIST_DIR/appcast.xml so
# CI can stage it next to the release notes.
"$GENERATE_APPCAST" \
  --ed-key-file "$KEY_FILE" \
  -o "$APPCAST_DIR/appcast.xml" \
  "$DIST_DIR"

echo "Appcast written to $APPCAST_DIR/appcast.xml"
