import Foundation
import Network

/// Who's on each end of a session.
public struct SyncIdentity: Sendable {
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String
    public init(deviceID: String, deviceName: String, appVersion: String) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.appVersion = appVersion
    }

    func hello(libraryID: String? = nil, lastFMConnected: Bool? = nil) -> SyncHello {
        SyncHello(deviceID: deviceID, deviceName: deviceName, appVersion: appVersion,
                  libraryID: libraryID, lastFMConnected: lastFMConnected)
    }
}

public struct SyncProgress: Equatable, Sendable {
    public var files = 0
    public var totalFiles = 0
    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    /// The file being sent or received.
    public var current: String?
    public init() {}

    public var fraction: Double { totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : 0 }
}

public enum SyncSessionError: Error, LocalizedError, Equatable {
    case phoneAppTooOld
    case notEnoughSpace(needed: Int64)

    public var errorDescription: String? {
        switch self {
        case .phoneAppTooOld:
            return "The iPhone app is older than this Mac app and can't read its library. Update the iPhone app, then sync again."
        case .notEnoughSpace(let needed):
            return "Not enough space on the iPhone: this sync needs \(ByteCountFormatter().string(fromByteCount: needed)) more. Free up space on the iPhone or choose less music."
        }
    }
}

// MARK: Phone

/// The phone's side of a session, from the Mac's `.hello` to the final `.done`.
public enum SyncPhoneSession {
    /// Runs one session on a connection from the Mac, or to it (`connection` is opened here either way). When
    /// `pairing`, the Mac must send `.pair`; `storeGrant` keeps the key it sends and the session ends there (the Mac
    /// syncs in a new session, with that key). Otherwise `events` (recorded against `libraryID`) and `requests` go to
    /// the Mac with the file list; once the session returns, the Mac has handled them all. `adoptLastFM` gets the
    /// Mac's Last.fm account when `lastFMConnected` is false and the Mac has one; `storeConcerts` its concert
    /// settings. `freeSpace` is checked here against what the Mac's plan needs and never sent. Returns the Mac's hello
    /// and what was applied.
    public static func run(_ connection: SyncConnection, identity: SyncIdentity, root: URL, freeSpace: Int64?, pairing: Bool,
                           events: [SyncEvent] = [], requests: [SyncRequest] = [], libraryID: String? = nil, lastFMConnected: Bool = true,
                           storeGrant: @Sendable (SyncGrant) async throws -> Void,
                           adoptLastFM: @Sendable (SyncLastFM) async -> Void = { _ in },
                           storeConcerts: @Sendable (SyncConcertSettings) async -> Void = { _ in },
                           progress: @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> (mac: SyncHello, summary: SyncSummary) {
        var receiver: SyncReceiver?
        do {
            try await connection.open()
            guard case .hello(let mac) = try await connection.receiveMessage() else { throw SyncError.unexpected("no hello from the Mac") }
            guard mac.protocolVersion == SyncProtocol.version else { throw SyncError.versionMismatch(mac.protocolVersion) }
            try await connection.send(.hello(identity.hello(lastFMConnected: lastFMConnected)))
            if pairing {
                guard case .pair(let grant) = try await connection.receiveMessage(), grant.keyData != nil else {
                    throw SyncError.unexpected("no key from the Mac")
                }
                try await storeGrant(grant)
                try await connection.send(.paired)
                await connection.close()
                return (mac, SyncSummary())
            }
            let files = try SyncReceiver(root: root)
            receiver = files
            try await connection.send(.manifest(SyncManifest(files: files.manifest(), events: events, libraryID: libraryID, requests: requests)))

            var state = SyncProgress()
            while true {
                switch try await connection.receiveMessage() {
                case .plan(let plan):
                    if let needed = plan.needed, let freeSpace, needed > freeSpace { throw SyncSessionError.notEnoughSpace(needed: needed) }
                    state.totalFiles = plan.files
                    state.totalBytes = plan.bytes
                    await progress(state)
                case .delete(let paths):
                    try files.delete(paths)
                case .lastFM(let account):
                    await adoptLastFM(account)
                case .concerts(let settings):
                    await storeConcerts(settings)
                case .file(let header):
                    let isDatabase = header.path == SyncReceiver.databaseName
                    state.current = header.path
                    await progress(state)
                    var complete = try files.begin(header)
                    var sinceReport: Int64 = 0
                    while !complete {
                        let frame = try await connection.receive()
                        guard frame.kind == .chunk else { throw SyncError.unexpected("a message in the middle of \(header.path)") }
                        complete = try files.write(frame.payload)
                        if !isDatabase { state.bytes += Int64(frame.payload.count) }
                        sinceReport += Int64(frame.payload.count)
                        if sinceReport >= 4 << 20 { sinceReport = 0; await progress(state) }
                    }
                    if !isDatabase { state.files += 1 }
                    state.current = nil
                    await progress(state)
                case .done(let sent):
                    var summary = files.summary
                    summary.missing = sent.missing
                    summary.plays = sent.plays
                    summary.likes = sent.likes
                    summary.eventsDropped = sent.eventsDropped
                    summary.purchases = sent.purchases
                    try await connection.send(.done(summary))
                    await connection.close()
                    return (mac, summary)
                case let other:
                    throw SyncError.unexpected("\(other)")
                }
            }
        } catch {
            receiver?.cancel()
            try? await connection.send(.failure(error.localizedDescription))
            await connection.close()
            throw error
        }
    }
}

// MARK: Mac

/// The songs a sync puts on the phone (`tracks`), and every track in the library (`library`, for the covers).
public struct SyncTracks: Sendable {
    public var tracks: [Track]
    public var library: [Track]
    public init(tracks: [Track], library: [Track] = []) { self.tracks = tracks; self.library = library }
}

/// The Mac's side: pairing with a phone, and syncing a selection to it.
public enum SyncMacSession {
    /// Pairs with a phone showing `code`: hands it a new key and returns the phone's hello and that key, which
    /// later syncs use. A wrong code fails the TLS handshake.
    public static func pair(endpoint: NWEndpoint, code: String, identity: SyncIdentity) async throws -> (phone: SyncHello, key: Data) {
        let connection = SyncConnection(endpoint: endpoint, key: SyncPairing.pairingKey(code: code))
        do {
            try await connection.open()
            let phone = try await exchangeHellos(connection, identity: identity)
            let key = SyncPairing.newKey()
            try await connection.send(.pair(SyncGrant(key: key, macID: identity.deviceID, macName: identity.deviceName)))
            guard case .paired = try await connection.receiveMessage() else { throw SyncError.unexpected("the iPhone didn't confirm pairing") }
            await connection.close()
            return (phone, key)
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Makes the phone's library mirror `tracks`: applies the phone's plays and likes to `database` first (so the
    /// snapshot it gets back includes them), hands over `lastFM` if the phone isn't connected, sends what it's missing
    /// or has a different size of, removes what's no longer selected (when `approveDeletes`, given the number of
    /// files, agrees), then sends a fresh database snapshot. Returns what the phone applied.
    public static func sync(endpoint: NWEndpoint, key: Data, identity: SyncIdentity, tracks: [Track], libraryRoot: URL,
                            database: Database, scratch: URL, lastFM: SyncLastFM? = nil,
                            approveDeletes: @Sendable (Int) async -> Bool = { _ in true },
                            progress: @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> SyncSummary {
        try await sync(SyncConnection(endpoint: endpoint, key: key), identity: identity, selection: { _ in SyncTracks(tracks: tracks) },
                       libraryRoot: libraryRoot, database: database, scratch: scratch, lastFM: lastFM,
                       approveDeletes: approveDeletes, progress: progress).summary
    }

    /// A session on `connection`, made by the Mac or accepted from the phone. `selection` gets the phone's manifest
    /// once its events are applied, applies its requests and returns what to sync. Returns the phone's hello and
    /// what it applied.
    public static func sync(_ connection: SyncConnection, identity: SyncIdentity,
                            selection: @Sendable (SyncManifest) async -> SyncTracks, libraryRoot: URL,
                            database: Database, scratch: URL, lastFM: SyncLastFM? = nil, concerts: SyncConcertSettings? = nil,
                            approveDeletes: @Sendable (Int) async -> Bool = { _ in true },
                            progress: @Sendable (SyncProgress) async -> Void = { _ in }) async throws -> (phone: SyncHello, summary: SyncSummary) {
        let snapshot = scratch.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        do {
            try await connection.open()
            let phone = try await exchangeHellos(connection, identity: identity, libraryID: database.libraryID())
            guard phone.schemaVersion >= Database.schemaVersion else { throw SyncSessionError.phoneAppTooOld }
            guard case .manifest(let manifest) = try await connection.receiveMessage() else { throw SyncError.unexpected("no file list from the iPhone") }
            let applied = try database.applySyncEvents(manifest.events, libraryID: manifest.libraryID)
            if let lastFM, phone.lastFMConnected == false { try await connection.send(.lastFM(lastFM)) }
            if let concerts { try await connection.send(.concerts(concerts)) }

            let selected = await selection(manifest)
            var plan = SyncPlan(tracks: selected.tracks, library: selected.library, collectionCovers: try database.collectionCoverPaths(),
                                libraryRoot: libraryRoot, phone: manifest.files)
            if !plan.deletes.isEmpty, await !approveDeletes(plan.deletes.count) { plan.deletes = [] }
            let onPhone = Dictionary(manifest.files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
            let freed = plan.deletes.reduce(Int64(0)) { $0 + (onPhone[$1] ?? 0) } + plan.sends.reduce(Int64(0)) { $0 + (onPhone[$1.path] ?? 0) }
            let needed = plan.bytes - freed
            if let available = phone.freeSpace, needed > available { throw SyncSessionError.notEnoughSpace(needed: needed) }
            var summary = plan.summary
            summary.needed = needed
            try await connection.send(.plan(summary))
            try await connection.send(.delete(plan.deletes))

            var state = SyncProgress()
            state.totalFiles = plan.sends.count
            state.totalBytes = plan.bytes
            await progress(state)
            for entry in plan.sends {
                try Task.checkCancellation()
                guard let url = LibraryPath.resolve(entry.path, in: libraryRoot) else { throw SyncError.unsafePath(entry.path) }
                state.current = entry.path
                await progress(state)
                try await sendFile(url, as: entry.path, size: entry.size, over: connection) { sent in
                    state.bytes += sent
                }
                state.files += 1
                await progress(state)
            }
            state.current = nil
            try Task.checkCancellation()
            try database.writeSyncSnapshot(to: snapshot, scratch: scratch)
            if let size = LibraryExporter.size(of: snapshot) {
                try await sendFile(snapshot, as: SyncReceiver.databaseName, size: size, over: connection) { _ in }
            }
            var sent = SyncSummary()
            sent.missing = plan.missing
            sent.plays = applied.plays
            sent.likes = applied.likes
            sent.eventsDropped = applied.dropped
            sent.purchases = applied.purchases
            try await connection.send(.done(sent))
            guard case .done(let applied) = try await connection.receiveMessage() else { throw SyncError.unexpected("the iPhone didn't finish") }
            await connection.close()
            return (phone, applied)
        } catch {
            try? await connection.send(.failure(error.localizedDescription))
            await connection.close()
            throw error
        }
    }

    private static func exchangeHellos(_ connection: SyncConnection, identity: SyncIdentity, libraryID: String? = nil) async throws -> SyncHello {
        try await connection.send(.hello(identity.hello(libraryID: libraryID)))
        guard case .hello(let phone) = try await connection.receiveMessage() else { throw SyncError.unexpected("no hello from the iPhone") }
        guard phone.protocolVersion == SyncProtocol.version else { throw SyncError.versionMismatch(phone.protocolVersion) }
        return phone
    }

    /// Sends `url` as `.file` and chunks. The size is the one planned; a file that changed meanwhile is sent as
    /// it was planned (truncated or padded is worse), so it throws instead.
    private static func sendFile(_ url: URL, as path: String, size: Int64, over connection: SyncConnection,
                                 sent: (Int64) async -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try await connection.send(.file(SyncFileHeader(path: path, size: size)))
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(Int64(SyncProtocol.chunkSize), remaining))) ?? Data()
            guard !chunk.isEmpty else { throw SyncError.unexpected("\(path) changed while it was being sent") }
            try await connection.sendChunk(chunk)
            remaining -= Int64(chunk.count)
            await sent(Int64(chunk.count))
        }
    }
}
