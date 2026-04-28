import Foundation

public enum DynamicEvent: Codable, Hashable, Sendable, Identifiable {
    case process(ProcessEvent)
    case file(FileEvent)
    case network(NetworkEvent)

    public var id: UUID {
        switch self {
        case .process(let e): return e.id
        case .file(let e):    return e.id
        case .network(let e): return e.id
        }
    }
    public var timestamp: Date {
        switch self {
        case .process(let e): return e.timestamp
        case .file(let e):    return e.timestamp
        case .network(let e): return e.lastSeen
        }
    }
}

public struct ProcessEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case start, exec, exit }
    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let pid: Int32
    public let ppid: Int32
    public let path: String
    public let arguments: [String]?
    public init(id: UUID = .init(), timestamp: Date = .init(),
                kind: Kind, pid: Int32, ppid: Int32,
                path: String, arguments: [String]?) {
        self.id = id; self.timestamp = timestamp; self.kind = kind
        self.pid = pid; self.ppid = ppid; self.path = path; self.arguments = arguments
    }
}

public struct FileEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Op: String, Codable, Hashable, Sendable {
        case open, create, write, read, rename, unlink, mkdir, rmdir, chmod, chown, link, symlink, truncate, other
    }
    public let id: UUID
    public let timestamp: Date
    public let pid: Int32
    public let processName: String
    public let op: Op
    public let path: String
    public let secondaryPath: String?
    public let category: PathCategory
    public let risk: Risk
    public let ruleID: String?

    public init(id: UUID = .init(), timestamp: Date = .init(),
                pid: Int32, processName: String,
                op: Op, path: String, secondaryPath: String? = nil,
                category: PathCategory, risk: Risk, ruleID: String?) {
        self.id = id; self.timestamp = timestamp
        self.pid = pid; self.processName = processName
        self.op = op; self.path = path; self.secondaryPath = secondaryPath
        self.category = category; self.risk = risk; self.ruleID = ruleID
    }
}

public struct NetworkEvent: Codable, Hashable, Sendable, Identifiable {
    public enum NetProto: String, Codable, Hashable, Sendable { case tcp, udp, other }

    public struct Endpoint: Codable, Hashable, Sendable {
        public let address: String   // numeric form
        public let port: UInt16
        public init(address: String, port: UInt16) {
            self.address = address; self.port = port
        }
    }

    public struct PayloadSample: Codable, Hashable, Sendable {
        public let direction: Direction
        public let bytes: Int
        public let preview: String   // already redacted
        public enum Direction: String, Codable, Hashable, Sendable { case sent, received }
    }

    public let id: UUID
    public let firstSeen: Date
    public let lastSeen: Date
    public let pid: Int32
    public let processName: String
    public let netProto: NetProto
    public let localEndpoint: Endpoint
    public let remoteEndpoint: Endpoint
    public let remoteHostname: String?
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
    public let tlsSNI: String?
    public let payloadSamples: [PayloadSample]
    public let risk: Risk

    public init(
        id: UUID = .init(),
        firstSeen: Date,
        lastSeen: Date,
        pid: Int32,
        processName: String,
        netProto: NetProto,
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        remoteHostname: String?,
        bytesSent: UInt64,
        bytesReceived: UInt64,
        tlsSNI: String?,
        payloadSamples: [PayloadSample],
        risk: Risk
    ) {
        self.id = id
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.pid = pid
        self.processName = processName
        self.netProto = netProto
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.remoteHostname = remoteHostname
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.tlsSNI = tlsSNI
        self.payloadSamples = payloadSamples
        self.risk = risk
    }
}

public enum PathCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case userDocuments
    case userDesktop
    case userDownloads
    case userMovies
    case userMusic
    case userPictures
    case userLibraryAppSupport
    case userLibraryContainers
    case userLibraryPreferences
    case userLibraryCaches
    case userLibraryKeychains
    case userLibraryCookies
    case userLibraryMessages
    case userLibraryMail
    case userLibraryCalendar
    case userLibraryContacts
    case userLibraryPhotos
    case userLibrarySafari
    case userLibrarySSH
    case userHomeOther
    case iCloudDrive
    case removableVolume
    case networkVolume
    case temporary
    case systemReadOnly
    case applications
    case bundleInternal       // inside the app's own bundle
    case unknown
}

public enum Risk: String, Codable, Hashable, Sendable {
    case expected      // explained by the bundle's declared capabilities
    case sensitive     // touches a sensitive category but is plausibly intended
    case surprising    // not justified by any declaration
}

public enum Fidelity: String, Codable, Hashable, Sendable {
    case staticAnalysis    // read from the bundle, deterministic
    case observed          // captured during the run, attributable to a tracked PID
    case bestEffort        // captured by polling/parsing tools that may have missed events
    case requiresEntitlement   // not enabled in this build
}
