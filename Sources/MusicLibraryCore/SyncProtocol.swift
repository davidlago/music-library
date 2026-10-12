import Foundation

/// Wi-Fi sync between the Mac app and the iPhone app. The phone advertises `serviceType` over Bonjour while its
/// Sync screen is open; the Mac connects (TLS with a pre-shared key, see `SyncPairing`) and exchanges `SyncMessage`s
/// in length-prefixed frames, with file contents sent as raw chunk frames after a `.file` message.
///
/// The phone can also start a sync (to download or remove what it asked for): the Mac advertises `macServiceType`
/// for each paired phone while it runs, with that phone's key, and the phone connects to it. Who connected doesn't
/// change the session.
///
/// A session: both send `.hello`; when pairing, the Mac sends `.pair` and the phone answers `.paired` (and that's
/// all); the phone sends its `.manifest` (with its plays, likes, ownership changes and download/remove requests since
/// the last sync); the Mac applies those, may send `.lastFM` and `.concerts`, then `.plan`, `.delete`, each file (the
/// database last) and `.done`; the phone answers `.done` once everything is written.
public enum SyncProtocol {
    /// 2: plays and likes from the phone, the library ID, Last.fm handoff. 3: the whole library's covers and
    /// photos, requests and ownership from the phone, phone-started sessions, concert settings.
    public static let version = 3
    public static let serviceType = "_musiclib-sync._tcp"
    /// The Mac, waiting for one paired phone to start a sync.
    public static let macServiceType = "_musiclib-mac._tcp"
    /// File data per chunk frame.
    public static let chunkSize = 1 << 20
    /// Frames larger than this are refused (a manifest of tens of thousands of files fits easily).
    static let maxFrameSize = 32 << 20
    /// Top-level folders sync manages on the phone; nothing else under its library root is listed or deleted.
    public static let managedFolders = ["Music", LibraryExporter.artistImageFolder]
}

public enum SyncError: Error, LocalizedError, Equatable {
    case frameTooLarge(Int)
    case unknownFrameKind(UInt8)
    case badMessage(String)
    case versionMismatch(Int)
    case unsafePath(String)
    case unexpected(String)
    case remote(String)
    case connection(String)
    case notPaired

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let n): return "Sync received an oversized message (\(n) bytes)."
        case .unknownFrameKind(let k): return "Sync received an unknown kind of message (\(k))."
        case .badMessage(let m): return "Sync received a message it couldn't read: \(m)"
        case .versionMismatch(let v): return "The other device uses a different sync version (\(v), this one \(SyncProtocol.version)). Update both apps."
        case .unsafePath(let p): return "Sync refused a path outside the library: \(p)"
        case .unexpected(let m): return "Sync got out of step: \(m)"
        case .remote(let m): return m
        case .connection(let m): return "Connection failed: \(m)"
        case .notPaired: return "This iPhone isn't paired with this Mac. Pair them again."
        }
    }
}

// MARK: Frames

/// One frame on the wire: a 4-byte big-endian payload length, a kind byte, then the payload.
public struct SyncFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case message = 1
        case chunk = 2
    }

    public var kind: Kind
    public var payload: Data

    public init(kind: Kind, payload: Data) { self.kind = kind; self.payload = payload }

    public static func message(_ m: SyncMessage) throws -> SyncFrame {
        SyncFrame(kind: .message, payload: try JSONEncoder().encode(m))
    }

    public func message() throws -> SyncMessage {
        guard kind == .message else { throw SyncError.unexpected("file data where a message was expected") }
        do { return try JSONDecoder().decode(SyncMessage.self, from: payload) } catch { throw SyncError.badMessage(error.localizedDescription) }
    }

    public func encoded() -> Data {
        var data = Data(capacity: payload.count + 5)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }
}

/// Cuts a byte stream into frames; data arrives in arbitrary pieces.
public struct SyncFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [SyncFrame] {
        buffer.append(data)
        var frames: [SyncFrame] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= SyncProtocol.maxFrameSize else { throw SyncError.frameTooLarge(length) }
            let rawKind = buffer[start + 4]
            guard let kind = SyncFrame.Kind(rawValue: rawKind) else { throw SyncError.unknownFrameKind(rawKind) }
            guard buffer.count >= 5 + length else { break }
            frames.append(SyncFrame(kind: kind, payload: Data(buffer[start + 5..<start + 5 + length])))
            buffer = Data(buffer[(start + 5 + length)...])
        }
        return frames
    }
}

// MARK: Messages

public enum SyncMessage: Codable, Equatable, Sendable {
    case hello(SyncHello)
    /// Mac → phone while pairing: the long-term key for later sessions.
    case pair(SyncGrant)
    /// Mac → phone, when the phone isn't connected to Last.fm: the Mac's account.
    case lastFM(SyncLastFM)
    /// Mac → phone: where home is and the concert services' keys, for concerts on artist pages.
    case concerts(SyncConcertSettings)
    /// Phone → Mac: the key is stored.
    case paired
    case manifest(SyncManifest)
    case plan(SyncPlanSummary)
    case delete([String])
    /// A file follows as chunk frames totalling `size` bytes (none for an empty file).
    case file(SyncFileHeader)
    case done(SyncSummary)
    case failure(String)
}

public struct SyncHello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String
    /// The newest library database schema the sender's app reads.
    public var schemaVersion: Int
    /// Free space on the phone, in bytes. Sent only by older iPhone apps: newer ones check `SyncPlanSummary.needed`
    /// themselves.
    public var freeSpace: Int64?
    /// The Mac's library (`Database.libraryID`).
    public var libraryID: String?
    /// The phone is connected to Last.fm (when false, the Mac may send its account).
    public var lastFMConnected: Bool?

    public init(deviceID: String, deviceName: String, appVersion: String, freeSpace: Int64? = nil, libraryID: String? = nil,
                lastFMConnected: Bool? = nil) {
        protocolVersion = SyncProtocol.version
        schemaVersion = Database.schemaVersion
        self.deviceID = deviceID; self.deviceName = deviceName; self.appVersion = appVersion; self.freeSpace = freeSpace
        self.libraryID = libraryID; self.lastFMConnected = lastFMConnected
    }
}

public struct SyncGrant: Codable, Equatable, Sendable {
    /// 32 random bytes, base64.
    public var key: String
    public var macID: String
    public var macName: String

    public init(key: Data, macID: String, macName: String) {
        self.key = key.base64EncodedString(); self.macID = macID; self.macName = macName
    }

    public var keyData: Data? { Data(base64Encoded: key).flatMap { $0.count == 32 ? $0 : nil } }
}

public struct SyncFileEntry: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

public struct SyncManifest: Codable, Equatable, Sendable {
    public var files: [SyncFileEntry]
    /// Plays, likes and ownership changes on the phone since the last sync.
    public var events: [SyncEvent]
    /// The library the phone's copy came from (and its events refer to); nil before the first sync.
    public var libraryID: String?
    /// Downloads and removals asked for on the phone, oldest first.
    public var requests: [SyncRequest]
    public init(files: [SyncFileEntry], events: [SyncEvent] = [], libraryID: String? = nil, requests: [SyncRequest] = []) {
        self.files = files; self.events = events; self.libraryID = libraryID; self.requests = requests
    }
}

public struct SyncPlanSummary: Codable, Equatable, Sendable {
    public var files: Int
    public var bytes: Int64
    public var deletes: Int
    /// How much more space the phone's copy takes after this sync (what's sent minus what's deleted or replaced). The
    /// phone checks it against its free space itself: App Store rules keep the free space on the device. Optional:
    /// older Macs don't send it.
    public var needed: Int64?
    public init(files: Int, bytes: Int64, deletes: Int, needed: Int64? = nil) {
        self.files = files; self.bytes = bytes; self.deletes = deletes; self.needed = needed
    }
}

public struct SyncFileHeader: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

public struct SyncSummary: Codable, Hashable, Sendable {
    public var copied = 0
    public var bytes: Int64 = 0
    public var deleted = 0
    public var databaseUpdated = false
    /// Songs in the selection whose files are missing from the Mac's library.
    public var missing = 0
    /// The phone's plays and like changes added to the Mac's library, and events dropped (songs changed or gone).
    public var plays = 0
    public var likes = 0
    public var eventsDropped = 0
    /// Ownership changes from the phone (optional: summaries saved by older versions don't have it).
    public var purchases: Int?
    public init() {}
}

/// The Mac's concert settings, handed to the phone with each sync.
public struct SyncConcertSettings: Codable, Equatable, Sendable {
    public var home: HomeLocation
    public var radius: Int
    public var unit: DistanceUnit
    public var ticketmasterKey: String
    public var jambaseKey: String
    public init(home: HomeLocation, radius: Int, unit: DistanceUnit, ticketmasterKey: String, jambaseKey: String) {
        self.home = home; self.radius = radius; self.unit = unit; self.ticketmasterKey = ticketmasterKey; self.jambaseKey = jambaseKey
    }
}
