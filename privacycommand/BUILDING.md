# Building privacycommand

Two parallel ways to build, both pointed at the same source files.

## 1. Xcode (the primary path)
```bash
cd "MacOS Permissions/privacycommand"
open privacycommand.xcodeproj
```

In Xcode:
1. Select the **privacycommand** scheme (top toolbar).
2. **Signing & Capabilities → Team:** pick your personal team (or change `PRODUCT_BUNDLE_IDENTIFIER` from `com.example.privacycommand` to your own reverse-DNS prefix first).
3. **⌘R** to build and run. **⌘U** to run the test bundle (3 tests).

The project has two targets:
- `privacycommand` — the SwiftUI app (single target, contains all 31 Swift sources).
- `privacycommandTests` — host-app-loaded XCTest bundle with the 3 unit-test files.

App Sandbox is disabled. Hardened Runtime is on. macOS deployment target is 13.0. Distribution target is Developer ID + notarization (not the App Store).

## 2. Swift Package Manager (CLI smoke test)
```bash
cd "MacOS Permissions/privacycommand"
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

## What I would expect to fail first on a real build

If anything trips, my best guesses in priority order:

1. **`Darwin` does not expose `<libproc.h>` on your SDK version.** Symptom: `Use of unresolved identifier 'proc_listallpids'`. Fix: drop these `@_silgen_name` shims at the top of `Sources/privacycommandCore/Monitoring/ProcessTracker.swift` (or in any one file in the Core target):
   ```swift
   @_silgen_name("proc_listallpids") func proc_listallpids(_ buf: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
   @_silgen_name("proc_pidinfo")     func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buf: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
   @_silgen_name("proc_pidpath")     func proc_pidpath(_ pid: Int32, _ buf: UnsafeMutableRawPointer?, _ bufsz: UInt32) -> Int32
   ```

2. **Concurrency strictness warnings on Swift 5.9 / Xcode 15.** All actor `let`s read from outside their isolation domain are marked `nonisolated`. If you flip `SWIFT_STRICT_CONCURRENCY=complete` in build settings you may see additional warnings on `[weak self] in` Task closures — these are warnings, not errors.

3. **`spctl` returning a non-zero exit on first run** while it queries Apple's notarization server. The wrapper handles the parse — it just maps the relevant strings. If you see `notarization = .unknown(...)` for an app you know is notarized, run `spctl -a -vvv <app>` once at the terminal so its result is cached, then re-run.

4. **First-run signing failure** because the bundle ID `com.example.privacycommand` collides or doesn't match your team. Change `PRODUCT_BUNDLE_IDENTIFIER` in **privacycommand → Build Settings** to e.g. `com.<yourdomain>.privacycommand`, then **Signing & Capabilities → Team** picks up automatically.

## If you ever add new Swift files

The Xcode project has explicit file references for every source file. When you add a new file:
- **In Xcode:** drag it into the appropriate group, tick "privacycommand" target. That's it.
- **In SwiftPM:** SPM auto-discovers files in `Sources/<target>/` — no manifest changes needed.
