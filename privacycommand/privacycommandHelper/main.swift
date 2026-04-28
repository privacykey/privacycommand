import Foundation

// privacycommand privileged helper (root daemon).
//
// Lifecycle:
//   - launchd starts us when SMAppService.daemon(...).register() succeeds and
//     the user approves in System Settings → General → Login Items.
//   - We listen on `HelperToolID.machServiceName` and accept connections only
//     from the main app (Team-ID-pinned).
//   - For each connection, we expose `HelperToolProtocol` and accept reverse
//     calls to push file events back to the GUI.
//
// Process model:
//   - We run as `root` under launchd. We do NOT spawn child processes from
//     XPC handlers without first sanitizing inputs. The only subprocess we
//     spawn is `/usr/bin/fs_usage`, with a fixed argument list.
//
// Security:
//   - Connections are validated against the helper's own Team ID.
//   - We never expose arbitrary command execution to the GUI.

let listener = NSXPCListener(machServiceName: HelperToolID.machServiceName)
let delegate = HelperToolListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
