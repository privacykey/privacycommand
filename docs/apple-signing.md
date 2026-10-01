# Apple signing through Xcode

Local archive, export and TestFlight upload commands use the account signed into
**Xcode → Settings → Accounts** by default. You do not need a separate `.p8` API
key for these local operations. Signing certificates and their private keys
remain in Keychain, or Xcode uses an authorized cloud-managed certificate.

Create `~/.config/apple/signing.env` once on the signing Mac:

```sh
export APPLE_TEAM_ID="6S9Q286XS9"
export APPLE_PROVISIONING_AUTH="account"
```

Signed archive, release and Fastlane entry points load the file automatically.
No per-repository `.env` or shell startup edit is needed. Explicit environment
variables override the file. `APPLE_SIGNING_CONFIG` can select another file.
Use `chmod 600 ~/.config/apple/signing.env`; keep it out of Git.

Run `just release-check` to check locally available settings. This does not
prove server-side permission or profile readiness. Xcode may already have
created development certificates, identifiers and profiles on your first run.
The authorized account still needs provisioning and distribution access.

## Archive, export and upload

`just archive` creates an `.xcarchive` without exporting or uploading. Where an
app has a `beta` lane, it keeps the existing archive/export workflow and uploads
through `xcodebuild -exportArchive` with `destination=upload` in account mode.
The upload reuses the archive and preserves its build number. TestFlight
processing follows; upload does not submit the app for App Review or enable
external tester distribution.

To upload an existing App Store archive through Xcode without rebuilding:

```sh
python3 scripts/apple_signing.py --upload-archive "/path/to/App.xcarchive"
```

The helper invokes an upload only when explicitly called. Tests use stubbed
Xcode commands and never upload real builds. You can also use Xcode Organizer
→ Distribute App → App Store Connect to distribute the archive.

## Optional API automation

Existing API-based automation remains supported. For an explicit API-key run,
configure a Team API key and set the mode:

```sh
export APPLE_PROVISIONING_AUTH="api-key"
export APPLE_API_KEY_ID="YOUR_KEY_ID"
export APPLE_API_ISSUER="YOUR_ISSUER_UUID"
export APPLE_API_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8"
```

The authentication modes are:

- `account`: local default; use Xcode's account even if old API-key settings exist.
- `api-key`: require the complete API key configuration before starting signed work.
- `auto`: use a configured API key, otherwise Xcode's account. This remains the CI
  default to preserve existing automation. An explicit setting overrides both defaults.

The resolver validates key paths without reading or logging `.p8` contents.
Legacy `TEAM_ID`, `FASTLANE_TEAM_ID`, `ORBARI_TEAM_ID`, `APPLE_NOTARY_TEAM_ID`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` callers still work. Unsigned archives do not
load the signing configuration. API keys authenticate automation; they are
separate from app-signing certificates. See [Apple's API key guidance](https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api).

## Certificates

An Apple Development identity can sign a normal archive. App Store/TestFlight
export uses Apple Distribution and needs profiles for the app and every
extension. If cloud-managed distribution access is denied, authorize the
account or create/import an Apple Distribution certificate **and its private
key** under Xcode Settings → Accounts → Manage Certificates on the signing Mac.
See [Apple's cloud signing documentation](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/).

Direct macOS releases use Developer ID Application. If multiple certificates
exist, set `APPLE_DEVELOPER_ID_IDENTITY` for that release path. Existing
`DEVELOPER_ID` overrides still work. Keep `APPLE_SIGNING_IDENTITY` as a per-command
override so an Apple Development choice does not interfere with Developer ID.

## macOS notarization through Keychain

Notarization authenticates separately from Xcode account login. Direct macOS
release scripts support a saved `notarytool` Keychain profile, without requiring
a `.p8` file. Set up the profile once on the signing Mac:

```sh
xcrun notarytool store-credentials "apple-release" \
  --apple-id "your-apple-id@example.com" --team-id "6S9Q286XS9"
```

The tool securely prompts for an Apple app-specific password. Add this line to
the shared settings file:

```sh
export APPLE_NOTARY_PROFILE="apple-release"
```

If the profile is in a custom keychain, set `APPLE_NOTARY_KEYCHAIN` to that
keychain's path. A saved profile takes precedence over API settings for
notarization. Complete Team API credentials and existing
`APPLE_NOTARY_USER`/`APPLE_NOTARY_PASSWORD` credentials remain supported.
See [Apple's notarization credential guide](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

## Verify the helpers

```sh
python3 -m unittest discover -s scripts -p 'test_*signing.py'
```
