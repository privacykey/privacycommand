#!/bin/bash
# Build the auditctl CLI via SwiftPM, embed it at
# privacycommand.app/Contents/Helpers/auditctl, and sign it with the app's
# identity and hardened runtime so the notarized bundle stays valid.
#
# Runs as the app target's "Embed auditctl" build phase. Homebrew's cask
# links the embedded binary onto PATH (the `binary` stanza in
# packaging/homebrew/privacycommand.rb); DMG installs link it from the app
# menu's Install Command Line Tool… item.

set -euo pipefail

PRODUCT=auditctl

# A scratch path of its own. The guest agent's phase builds host-only into
# ${SRCROOT}/.build; sharing that with this build, which follows the app's
# architectures, would make each one rebuild the package from scratch.
SCRATCH="${PROJECT_TEMP_DIR}/auditctl-swiftpm"

# Stamp the app's version into the binary's __TEXT,__info_plist section, so
# `auditctl --version` reports it and codesign takes the identifier from it.
IDENTITY_PLIST="${DERIVED_FILE_DIR}/BuildIdentity-Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${IDENTITY_PLIST}")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${IDENTITY_PLIST}")
INFO_PLIST="${DERIVED_FILE_DIR}/auditctl-Info.plist"
rm -f "${INFO_PLIST}"
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string ${PRODUCT_BUNDLE_IDENTIFIER}.${PRODUCT}" \
    -c "Add :CFBundleName string ${PRODUCT}" \
    -c "Add :CFBundleShortVersionString string ${VERSION}" \
    -c "Add :CFBundleVersion string ${BUILD}" \
    "${INFO_PLIST}" >/dev/null

# One SwiftPM invocation for every architecture the app is being built for
# (arm64 + x86_64 for Release, the active one for Debug).
SWIFT_ARGS=( -c release --product "${PRODUCT}"
             --package-path "${SRCROOT}" --scratch-path "${SCRATCH}" )
for arch in ${ARCHS}; do
    SWIFT_ARGS+=( --arch "${arch}" )
done
# Only flags clang also understands: older SwiftPM (Xcode 26.6's, for
# multi-arch builds) hands -Xlinker values to clang unwrapped.
SWIFT_ARGS+=( -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
              -Xlinker "${INFO_PLIST}" )

# Xcode's build settings arrive as environment variables; keep them away
# from SwiftPM so this builds exactly what `swift build` does in Terminal,
# with the toolchain Xcode is using.
SWIFTPM_ENV=( HOME="${HOME}" PATH="${PATH}" TMPDIR="${TMPDIR:-/tmp}" )
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SWIFTPM_ENV+=( DEVELOPER_DIR="${DEVELOPER_DIR}" )
fi
swiftpm() {
    env -i "${SWIFTPM_ENV[@]}" swift build "${SWIFT_ARGS[@]}" "$@"
}

echo "Building ${PRODUCT} ${VERSION} (${BUILD}) for ${ARCHS} via SwiftPM…"
swiftpm
BIN="$(swiftpm --show-bin-path)/${PRODUCT}"
if [[ ! -f "${BIN}" ]]; then
    echo "error: SwiftPM didn't produce ${BIN}" >&2
    exit 1
fi
for arch in ${ARCHS}; do
    if ! /usr/bin/lipo "${BIN}" -verify_arch "${arch}"; then
        echo "error: ${BIN} is missing the ${arch} slice" >&2
        exit 1
    fi
done

DEST="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "${DEST}"
cp -f "${BIN}" "${DEST}/${PRODUCT}"
chmod 755 "${DEST}/${PRODUCT}"
# Drop debug info and local symbols, as Xcode strips the app's own
# executable: it halves the binary. strip re-signs a linker-signed arm64
# slice, so unsigned builds still run.
xcrun strip -S -x "${DEST}/${PRODUCT}"

# Follow Xcode's signing choice for unsigned builds (App CI).
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
    echo "Embedded ${PRODUCT} without signing (CODE_SIGNING_ALLOWED=NO)."
    exit 0
fi

# Same identity as the rest of the app, as the guest agent's phase does:
# EXPANDED_CODE_SIGN_IDENTITY is '-' for Sign to Run Locally and the
# Developer ID certificate for release builds. Hardened runtime always, so
# notarization accepts the binary; a secure timestamp only with a real
# identity (ad-hoc signing can't take one).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="-"
fi
SIGN_FLAGS=( --force --options runtime --sign "${IDENTITY}" )
if [[ "${IDENTITY}" != "-" ]]; then
    SIGN_FLAGS+=( --timestamp )
fi
echo "Signing ${PRODUCT} with identity '${IDENTITY}'…"
/usr/bin/codesign "${SIGN_FLAGS[@]}" "${DEST}/${PRODUCT}"

echo "Embedded + signed ${PRODUCT} at ${DEST}/${PRODUCT}"
