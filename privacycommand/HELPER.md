# The privileged helper

The Xcode project already wires the helper end-to-end. This file
documents what's in place, what to verify if the helper misbehaves,
and the one signing knob you have to set on first checkout.

## What's wired (you don't need to do this manually any more)

The `privacycommand.xcodeproj` now contains:

- A `privacycommandHelper` target that builds a Mach-O command-line
  executable from `Sources/privacycommandHelper/*.swift` (auto-discovered
  via Xcode's file-system-synchronized group, so adding/removing files
  doesn't require pbxproj edits).
- The helper target is configured with:
  - `PRODUCT_BUNDLE_IDENTIFIER = org.privacykey.privacycommand.HelperTool`
  - `CODE_SIGN_ENTITLEMENTS = privacycommand/Resources/privacycommandHelper.entitlements`
  - `ENABLE_HARDENED_RUNTIME = YES`
  - `GENERATE_INFOPLIST_FILE = YES` + `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`
    (so the LSBackgroundOnly / CFBundleIdentifier / CFBundleDisplayName
    keys are embedded in the Mach-O's `__TEXT,__info_plist` section)
  - `MACOSX_DEPLOYMENT_TARGET = 13.0`
- The app target has a build dependency on the helper, so building
  the app builds the helper first.
- The app target has two **Copy Files** phases:
  1. **Embed Privileged Helper** — copies the helper executable into
     `privacycommand.app/Contents/MacOS/privacycommandHelper`,
     code-sign-on-copy enabled.
  2. **Embed LaunchDaemon plist** — copies
     `Resources/org.privacykey.privacycommand.HelperTool.plist` to
     `privacycommand.app/Contents/Library/LaunchDaemons/`.

The plist itself (`org.privacykey.privacycommand.HelperTool.plist`)
declares `BundleProgram = Contents/MacOS/privacycommandHelper`, which
matches the embed destination above.

## The one thing you do have to set: signing identity

On first checkout, open `privacycommand.xcodeproj`, select each
target, and confirm:

- **privacycommand** → Signing & Capabilities → Team is set
  (your personal team is fine for development; production needs a
  Developer ID).
- **privacycommandHelper** → Signing & Capabilities → Team matches
  the app's. The helper's Team ID must equal the app's, otherwise
  `CodeSignValidator` rejects the XPC connection.

`CODE_SIGN_STYLE = Automatic` is on for the helper, so once a Team
is selected Xcode handles the certs.

## Verifying after build

```bash
# After ⌘B, check the .app structure:
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products*/privacycommand.app' -maxdepth 7 -print -quit)
ls -1 "$APP/Contents/MacOS"
# → privacycommand
# → privacycommandHelper          ← exec is bundled

ls -1 "$APP/Contents/Library/LaunchDaemons"
# → org.privacykey.privacycommand.HelperTool.plist  ← plist is bundled

codesign -dvv "$APP/Contents/MacOS/privacycommandHelper" 2>&1 | grep -E 'TeamIdentifier|Authority|format='
# Confirm Team ID matches the main app's, hardened runtime is on.
```

## Walkthrough — installing the helper at runtime

1. Build + run the app.
2. Open Settings → Helper → click **Install Helper**.
3. macOS shows a one-time system prompt; click "Open System Settings".
4. Toggle **privacycommand** on under Login Items.
5. Click **Refresh** in Settings → Helper. Status flips to **installed**.

After that, the BTM audit on the Static tab silently fetches via the
helper (no admin prompt), file-event monitoring is available during
monitored runs, and the network kill switch can install pf rules.

## Verifying the helper is alive

```bash
# Is the daemon registered?
launchctl list | grep privacycommand

# Is the helper actually running?
ps -fe | grep privacycommandHelper

# Are file events being captured? In Xcode's Console, after Cmd-R-ing the app:
log stream --predicate 'process == "privacycommandHelper"' --info
```

## Uninstalling

The wizard's "File monitoring" step has an Uninstall button when status is `installed`. Or from the Terminal:
```bash
sudo launchctl unload /Library/LaunchDaemons/org.privacykey.privacycommand.HelperTool.plist
sudo rm /Library/LaunchDaemons/org.privacykey.privacycommand.HelperTool.plist
```

## What I would expect to fail first

1. **`SMAppService.daemon(plistName:).register()` throws "1: Operation not permitted"** — the daemon plist isn't where SMAppService expects. Verify the Embed Daemon Plist build phase actually copied the file to `Contents/Library/LaunchDaemons/` (right-click the built `.app` → Show Package Contents).
2. **System Settings shows the entry but the toggle won't enable** — the helper is signed with a different Team ID than the app. Both must match.
3. **Helper launches but XPC connection is rejected** — the bundle IDs don't match across the four places listed in Step 6.
4. **fs_usage exits immediately with permission denied** — the helper isn't actually running as root. Check `launchctl list | grep privacycommand` and confirm the LaunchDaemon (system, not user) plist was loaded.
