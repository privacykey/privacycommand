import Foundation

/// One row of `lsof -p <pid>` for any FD type — files, pipes, sockets,
/// devices. Modeled after Sloth's view of "what does this process have open
/// right now?".
public struct OpenResource: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case regularFile     // REG
        case directory       // DIR
        case pipe            // PIPE
        case fifo            // FIFO
        case unixSocket      // unix
        case ipv4Socket      // IPv4
        case ipv6Socket      // IPv6
        case characterDevice // CHR
        case blockDevice     // BLK
        case kqueue          // KQUEUE
        case event           // EVENT
        case psxsem          // PSXSEM (POSIX semaphore)
        case psxshm          // PSXSHM (POSIX shared memory)
        case other           // anything we don't have a case for

        public var label: String {
            switch self {
            case .regularFile:     return "File"
            case .directory:       return "Directory"
            case .pipe:            return "Pipe"
            case .fifo:            return "FIFO"
            case .unixSocket:      return "Unix socket"
            case .ipv4Socket:      return "IPv4 socket"
            case .ipv6Socket:      return "IPv6 socket"
            case .characterDevice: return "Char device"
            case .blockDevice:     return "Block device"
            case .kqueue:          return "Kqueue"
            case .event:           return "Event"
            case .psxsem:          return "POSIX sem"
            case .psxshm:          return "Shared mem"
            case .other:           return "Other"
            }
        }

        public var systemImage: String {
            switch self {
            case .regularFile:     return "doc"
            case .directory:       return "folder"
            case .pipe:            return "tornado"
            case .fifo:            return "tornado"
            case .unixSocket:      return "link"
            case .ipv4Socket:      return "network"
            case .ipv6Socket:      return "network"
            case .characterDevice: return "puzzlepiece"
            case .blockDevice:     return "internaldrive"
            case .kqueue:          return "tray"
            case .event:           return "bell"
            case .psxsem:          return "lock.shield"
            case .psxshm:          return "memorychip"
            case .other:           return "questionmark.diamond"
            }
        }

        /// Stable KnowledgeBase article identifier — UI uses this to look up
        /// the explanatory popover for the chip / table row.
        public var kbArticleID: String { "resource-\(rawValue)" }

        /// Maps `lsof`'s TYPE column to a Kind.
        public static func from(lsofType raw: String) -> Kind {
            switch raw.uppercased() {
            case "REG":             return .regularFile
            case "DIR":             return .directory
            case "PIPE":            return .pipe
            case "FIFO":            return .fifo
            case "UNIX":            return .unixSocket
            case "IPV4":            return .ipv4Socket
            case "IPV6":            return .ipv6Socket
            case "CHR":             return .characterDevice
            case "BLK":             return .blockDevice
            case "KQUEUE":          return .kqueue
            case "EVENT":           return .event
            case "PSXSEM":          return .psxsem
            case "PSXSHM":          return .psxshm
            default:                return .other
            }
        }
    }

    public var id: String { "\(pid)/\(fd)/\(name)" }
    public let pid: Int32
    public let processName: String
    public let user: String?
    /// FD column from lsof, e.g. "27u", "5r", "txt", "cwd".
    public let fd: String
    public let kind: Kind
    public let typeRaw: String
    public let device: String?
    public let sizeOrOffset: String?
    public let node: String?
    /// NAME column. For files this is the path; for sockets it's the
    /// socket descriptor like "192.168.1.2:51212->17.253.144.10:443".
    public let name: String

    public init(pid: Int32, processName: String, user: String?,
                fd: String, kind: Kind, typeRaw: String,
                device: String?, sizeOrOffset: String?, node: String?, name: String) {
        self.pid = pid
        self.processName = processName
        self.user = user
        self.fd = fd
        self.kind = kind
        self.typeRaw = typeRaw
        self.device = device
        self.sizeOrOffset = sizeOrOffset
        self.node = node
        self.name = name
    }
}
