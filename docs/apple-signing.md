# Shared Apple signing settings

Create `~/.config/apple/signing.env` once on the Mac that holds the signing
certificates and API key. Signed archive, release and Fastlane entry points
load it automatically; no per-repository `.env` or shell startup edit is needed.

```sh
export APPLE_TEAM_ID="6S9Q286XS9"
export APPLE_API_KEY_ID="YOUR_KEY_ID"
export APPLE_API_ISSUER="YOUR_ISSUER_UUID"
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8"
```

Keep this file and the `.p8` out of Git. Restrict the settings file to your
user with `chmod 600 ~/.config/apple/signing.env`. The resolver reads settings
and checks that the key file exists; it never reads or prints private-key contents.
Use an App Store Connect **Team API key** for provisioning. Individual keys
cannot use provisioning endpoints or notarization. A key's role cannot be
changed after creation; create another Team key with appropriate access if needed.
See [Apple's API key guidance](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api).

Run `just release-check` to check locally available settings. This cannot prove
server-side permissions or App Store provisioning readiness; Xcode verifies
those during archive/export. Xcode may already have created development
certificates, identifiers and profiles when you first ran the app.

## Overrides and compatibility

Explicit environment variables take priority over the shared file. Point
`APPLE_SIGNING_CONFIG` at another file when you intentionally use another team.
The file supports simple `NAME=value` / `export NAME=value` lines, comments,
quoted spaces, `$HOME` and `~/`. It does not execute shell commands. Unsigned
`archive-app.py --unsigned` builds do not load signing configuration.

Existing `TEAM_ID`, `FASTLANE_TEAM_ID`, `ORBARI_TEAM_ID`,
`APPLE_NOTARY_TEAM_ID`, `ASC_KEY_ID` and `ASC_ISSUER_ID` callers are still accepted.
Prefer the four `APPLE_*` names above in new configuration.

`APPLE_PROVISIONING_AUTH` chooses Xcode provisioning authentication:

- `auto` (default): use the API key when configured, otherwise the account in Xcode.
- `account`: use the account signed into Xcode Settings → Accounts, keeping the API
  key available to a separate upload/notarization command.
- `api-key`: require the complete API key configuration for Xcode provisioning.

For example, `APPLE_PROVISIONING_AUTH=account just archive` uses Xcode's account.
The account must still have provisioning and distribution access. This setting
changes how Xcode authenticates; it does not grant permissions.

## Certificates and distribution

`just archive` creates an `.xcarchive`; it does not export or upload. An Apple
Development identity can sign a normal archive. App Store/TestFlight export
re-signs with Apple Distribution and requires App Store profiles for the main
app and every extension. A successful archive or local check does not establish
that export will succeed.

When no local Apple Distribution identity is available, Xcode may use a
cloud-managed distribution certificate. If export reports a cloud signing
permission error, check the key/account's distribution access. You can also
create/import an Apple Distribution certificate **and its private key** in
Xcode Settings → Accounts → Manage Certificates on this Mac to use local signing.
See [Apple's cloud certificate documentation](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/).

Direct macOS distribution uses **Developer ID Application**, rather than Apple
Distribution. Set `APPLE_DEVELOPER_ID_IDENTITY` only for that release path when
multiple certificates exist. Existing `DEVELOPER_ID` overrides still work. Keep
`APPLE_SIGNING_IDENTITY` as a per-command override; setting it globally to Apple
Development can interfere with a Developer ID release.

Signing certificates and their private keys stay in Keychain. An API `.p8`
authenticates automation; it is not an app-signing certificate. Installing
certificates on another Mac does not install their private keys on this Mac.

## Verify the helper

Run `python3 -m unittest discover -s scripts -p test_apple_signing.py`.
