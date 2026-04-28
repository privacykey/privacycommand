import Foundation
import Security

/// Validates that a connecting XPC peer was signed by the same Team ID as the
/// helper itself. Defense-in-depth — SMAppService daemons are already limited
/// to launchd-launched mach services bound to the daemon plist.
enum CodeSignValidator {

    /// Reads our own Team ID at startup. If we can't read our own signature
    /// (e.g. unsigned local development build) we fall back to "accept" so
    /// the wizard install flow still works on a personal-team dev machine.
    static let allowedTeamID: String? = {
        let exec = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(exec as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    static func validateConnection(_ connection: NSXPCConnection) -> Bool {
        // Personal-team dev mode: helper isn't team-signed, so we accept.
        // Production builds (Developer ID) should always have a Team ID.
        guard let allowedTeamID, !allowedTeamID.isEmpty else {
            NSLog("[privacycommandHelper] No Team ID — accepting connection (dev mode)")
            return true
        }

        let pid = connection.processIdentifier
        guard pid > 0 else { return false }

        let attrs: NSDictionary = [
            kSecGuestAttributePid: pid as NSNumber
        ]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return false
        }

        // Require Apple anchor + matching Team ID.
        let reqString = "anchor apple generic and certificate leaf[subject.OU] = \"\(allowedTeamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
