import Foundation

/// The `privacycommand` command-line tool that ships inside privacycommand.app,
/// and the symlink that puts it on the user's `PATH`.
///
/// Release builds embed the CLI at `Contents/Helpers/privacycommand` (the app
/// target's "Embed command-line tool" build phase). A Homebrew cask install
/// links it automatically through the cask's `binary` stanza; a DMG install
/// links it from the app menu's Install Command Line Tool… item, which drives
/// this type.
///
/// The link points into the app bundle rather than at a copy, so the tool
/// updates whenever the app does. Install and uninstall only ever touch a
/// symlink to an embedded tool: a file or link that something else put at the
/// install location is reported and left alone.
public struct CommandLineTool: Sendable {

    public static let name = "privacycommand"

    /// Where the binary sits inside the app bundle.
    public static let bundlePath = "Contents/Helpers/privacycommand"

    /// Where Install Command Line Tool… puts the link: on the default
    /// `PATH` for every shell.
    public static let defaultInstallDirectory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    /// Other places a link to the tool may already live. Homebrew on Apple
    /// silicon links cask binaries here (on Intel it uses /usr/local/bin).
    public static let defaultSearchDirectories = [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)]

    public enum Status: Equatable, Sendable {
        /// This build has no embedded binary — a SwiftPM build of the app
        /// sources, or one whose embed phase was skipped.
        case unavailable
        /// No link to the tool exists.
        case notInstalled
        /// A symlink at `link` resolves to this app's binary. It is either
        /// at the install location or in a search directory (Homebrew's).
        case installed(link: URL)
        /// The install location holds a link to an embedded tool that is not
        /// this app's: an older copy of the app, or one that has since
        /// moved. Installing replaces it; uninstalling removes it.
        case stale(link: URL, destination: String)
        /// The install location holds something privacycommand did not put
        /// there. `destination` is the link target, or nil for a plain file.
        case occupied(link: URL, destination: String?)
    }

    public enum Failure: Error, Equatable {
        case unavailable
        case notInstalled
        case occupied(link: URL, destination: String?)
        /// The tool is linked from somewhere this type doesn't manage —
        /// Homebrew's bin directory, removed by `brew uninstall`.
        case managedElsewhere(link: URL)
        /// This user can't write the install directory. `command` makes the
        /// same change with `sudo`, for the user to run in Terminal.
        case permissionDenied(command: String)
    }

    /// The embedded binary.
    public let tool: URL
    /// The link Install Command Line Tool… creates.
    public let link: URL
    public let installDirectory: URL
    public let searchDirectories: [URL]

    public init(appBundle: URL,
                installDirectory: URL = CommandLineTool.defaultInstallDirectory,
                searchDirectories: [URL] = CommandLineTool.defaultSearchDirectories) {
        self.tool = appBundle.appendingPathComponent(Self.bundlePath)
        self.installDirectory = installDirectory
        self.link = installDirectory.appendingPathComponent(Self.name)
        self.searchDirectories = searchDirectories.filter {
            $0.standardizedFileURL != installDirectory.standardizedFileURL
        }
    }

    // MARK: - Status

    public func status() -> Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { return .unavailable }
        let toolPath = Self.resolved(tool)

        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if Self.resolved(link) == toolPath { return .installed(link: link) }
            if Self.isEmbeddedToolPath(destination) {
                return .stale(link: link, destination: destination)
            }
            return .occupied(link: link, destination: destination)
        }
        if fm.fileExists(atPath: link.path) {
            return .occupied(link: link, destination: nil)
        }
        for directory in searchDirectories {
            let other = directory.appendingPathComponent(Self.name)
            if (try? fm.destinationOfSymbolicLink(atPath: other.path)) != nil,
               Self.resolved(other) == toolPath {
                return .installed(link: other)
            }
        }
        return .notInstalled
    }

    // MARK: - Install / uninstall

    /// Links the tool into the install directory, creating the directory if
    /// needed. Does nothing when a link to this app's tool already exists.
    public func install() throws {
        switch status() {
        case .unavailable:
            throw Failure.unavailable
        case .installed:
            return
        case .occupied(let link, let destination):
            throw Failure.occupied(link: link, destination: destination)
        case .stale:
            try permissionChecked(command: installCommand) {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
            }
        case .notInstalled:
            try permissionChecked(command: installCommand) {
                try FileManager.default.createDirectory(at: installDirectory,
                                                        withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
            }
        }
    }

    /// Removes the install directory's link, if it points at an embedded
    /// `privacycommand`. Anything else is reported, never deleted.
    public func uninstall() throws {
        switch status() {
        case .installed(let found) where found == link, .stale(let found, _):
            try permissionChecked(command: uninstallCommand) {
                try FileManager.default.removeItem(at: found)
            }
        case .installed(let found):
            throw Failure.managedElsewhere(link: found)
        case .occupied(let link, let destination):
            throw Failure.occupied(link: link, destination: destination)
        case .notInstalled, .unavailable:
            throw Failure.notInstalled
        }
    }

    // MARK: - Terminal equivalents

    /// What Install does, for a user without write access to the install
    /// directory to run themselves.
    public var installCommand: String {
        "sudo mkdir -p \(Self.shellQuoted(installDirectory.path)) && "
            + "sudo ln -sf \(Self.shellQuoted(tool.path)) \(Self.shellQuoted(link.path))"
    }

    public var uninstallCommand: String {
        "sudo rm \(Self.shellQuoted(link.path))"
    }

    // MARK: - Location

    /// True when the app is running from somewhere a link into it would
    /// soon break: a Gatekeeper-translocated copy (a quarantined download
    /// opened in place) or a read-only volume such as the release disk
    /// image.
    public static func isTemporaryLocation(_ appBundle: URL) -> Bool {
        if appBundle.path.contains("/AppTranslocation/") { return true }
        let readOnly = try? appBundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
        return readOnly == true
    }

    // MARK: - Helpers

    private func permissionChecked(command: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw Failure.permissionDenied(command: command)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                    && (error.code == Int(EACCES) || error.code == Int(EPERM)) {
            throw Failure.permissionDenied(command: command)
        }
    }

    private static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A link target that names some copy of privacycommand's embedded tool,
    /// whether or not that copy still exists.
    static func isEmbeddedToolPath(_ path: String) -> Bool {
        path.hasSuffix(".app/" + bundlePath)
    }

    /// Single-quotes `value` for a POSIX shell when it holds anything beyond
    /// a conservative set of path characters.
    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(plain.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
