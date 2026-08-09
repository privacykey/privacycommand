# Building privacycommand

Two parallel ways to build, both pointed at the same source files.

## 1. Xcode (the primary path)
```bash
cd privacycommand/privacycommand
open privacycommand.xcodeproj
```

In Xcode, three things before the first build:

1. **Add the Sparkle package.** File → Add Package Dependencies… →
   `https://github.com/sparkle-project/Sparkle`, *Up to Next Major* from `2.9.0`.
   Tick the `Sparkle` product on the **privacycommand** target.
2. **Set the app's team.** Select the **privacycommand** target →
   Signing & Capabilities → Team. A personal team is fine for development;
   distribution needs a Developer ID.
3. **Match the helper's team to the app's.** Select **privacycommandHelper** →
   Signing & Capabilities → Team, same team as the app.

   This one is not optional. `CodeSignValidator` requires an Apple anchor plus a
   Team ID matching the helper's own, so a mismatch means the XPC connection is
   refused at runtime and *every* privileged feature fails — file monitoring,
   the BTM audit, and the kill switch.

Then **⌘R** to build and run, **⌘U** for the test bundle.

Xcode targets:

- `privacycommand` — the SwiftUI app (63 Swift sources under `Sources/privacycommand/`).
- `privacycommandCore` — the analyzer (90 sources).
- `privacycommandHelper` — the privileged XPC helper, built from the top-level
  `privacycommandHelper/` directory.
- `privacycommandGuestProtocol` — the host/guest wire format.
- `privacycommandTests` — the XCTest bundle.

Bundle identifiers are `org.privacykey.privacycommand`, plus `.HelperTool` and
`.tests`. The app target depends on the helper, so building the app builds and
embeds the helper first, along with its LaunchDaemon plist.

App Sandbox is disabled. Hardened Runtime is on. macOS deployment target is 13.0. Distribution target is Developer ID + notarization (not the App Store).

## 2. Swift Package Manager (CLI smoke test)
```bash
cd privacycommand/privacycommand
swift build
.build/debug/auditctl /System/Applications/Calculator.app
swift test
```

Builds the `privacycommandCore` library and the `auditctl` CLI. The SwiftUI app is **not** built via SwiftPM (it lives in the Xcode project only).

Why both? `swift build` is a fast iteration loop on the analyzer logic without launching Xcode. The Xcode project is the only path for building/distributing the GUI app.

## How the same source compiles in both

The SwiftUI app source files use a conditional import:
```swift
import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif
```
- Under SwiftPM (`SWIFT_PACKAGE` defined), Core lives in its own module — they import it.
- Under Xcode, all files are in one app module — the import is skipped.

The test files do the same thing:
```swift
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif
```

## Common build failures

In rough order of likelihood:

0. **The helper's signing team doesn't match the app's.** This builds fine and
   fails at runtime: the app launches, but installing or contacting the helper
   is refused and every privileged feature is dead. `CodeSignValidator` requires
   an Apple anchor plus a matching Team ID. Set both targets to the same team.

1. **`Darwin` does not expose `<libproc.h>` on your SDK version.** Symptom: `Use of unresolved identifier 'proc_listallpids'`. Fix: drop these `@_silgen_name` shims at the top of `Sources/privacycommandCore/Monitoring/ProcessTracker.swift` (or in any one file in the Core target):
   ```swift
   @_silgen_name("proc_listallpids") func proc_listallpids(_ buf: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
   @_silgen_name("proc_pidinfo")     func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buf: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
   @_silgen_name("proc_pidpath")     func proc_pidpath(_ pid: Int32, _ buf: UnsafeMutableRawPointer?, _ bufsz: UInt32) -> Int32
   ```

2. **Concurrency strictness warnings on Swift 5.9 / Xcode 15.** All actor `let`s read from outside their isolation domain are marked `nonisolated`. If you flip `SWIFT_STRICT_CONCURRENCY=complete` in build settings you may see additional warnings on `[weak self] in` Task closures — these are warnings, not errors.

3. **`spctl` returning a non-zero exit on first run** while it queries Apple's notarization server. The wrapper handles the parse — it just maps the relevant strings. If you see `notarization = .unknown(...)` for an app you know is notarized, run `spctl -a -vvv <app>` once at the terminal so its result is cached, then re-run.

4. **First-run signing failure** because `org.privacykey.privacycommand` can't be provisioned under your team. Change `PRODUCT_BUNDLE_IDENTIFIER` in **Build Settings** to your own reverse-DNS prefix — on the app, the helper (`.HelperTool`) and the test bundle (`.tests`) — then **Signing & Capabilities → Team** picks up automatically. Keep the helper's identifier as a child of the app's.

## If you ever add new Swift files

The Xcode project has explicit file references for every source file. When you add a new file:
- **In Xcode:** drag it into the appropriate group, tick "privacycommand" target. That's it.
- **In SwiftPM:** SPM auto-discovers files in `Sources/<target>/` — no manifest changes needed.
