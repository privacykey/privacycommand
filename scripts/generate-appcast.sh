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
