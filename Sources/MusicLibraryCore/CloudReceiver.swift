import Foundation

/// What the phone took from the iCloud backup.
public struct CloudReceiveOutcome: Equatable, Sendable {
    public enum Database: Equatable, Sendable {
        /// The backup's copy is in place.
        case replaced
        /// The phone's copy is as new or newer (a Wi-Fi sync brought it).
        case current
        /// The phone holds another library (an export dragged in, say); it's left alone.
        case otherLibrary
        /// There's no backup yet.
        case noBackup
    }

    public var database: Database
    /// When the backup's copy was made, by the Mac's clock.
    public var backupAt: Date?
    public var macName: String?
    /// Covers and artist photos copied in.
    public var files = 0
    public var bytes: Int64 = 0
    /// Of the phone's pending changes, the ones the new database shows the Mac applied (only when it replaced it).
    public var applied: Set<String> = []
}

/// The phone's side of the backup (`docs/icloud-plan.md` §6, P4): brings the library at `root` up to the newest copy
/// in iCloud without a Mac nearby. The database is replaced only when the backup's `snapshot_at` is newer than the
/// phone's (D6), so a copy from iCloud never undoes a newer one a Wi-Fi sync brought, in either order; a copy without
/// a stamp (older Macs) counts as older than any. Every cover and artist photo the backup holds that the phone lacks,
/// or has at another size, is copied in, as Wi-Fi sync sends them all. Everything from the container is untrusted:
/// the database is opened read-only and checked first (a newer schema is refused), only cover and photo paths are
/// taken, and each is resolved inside `root`; files are made aside and renamed into place.
public enum CloudReceiver {
    /// `pending`: the ids of the phone's plays, likes and requests not yet known to have reached the Mac. `progress`
    /// gets the covers and photos copied so far and how many there are (a first check brings them all).
    public static func receive(from store: CloudStore, into root: URL, scratch: URL, pending: Set<String> = [], concurrency: Int = 6,
                               progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> CloudReceiveOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let manifest = try await manifest(in: store, scratch: scratch) else { return CloudReceiveOutcome(database: .noBackup) }
        var outcome = CloudReceiveOutcome(database: .current, backupAt: manifest.snapshotAt, macName: manifest.macName)

        let target = LibraryLocation.databaseURL(root: root)
        var local: (id: String?, at: Date?)?
        if fm.fileExists(atPath: target.path), let db = try? Database(snapshotAt: target.path) {
            local = (db.libraryID(), db.snapshotDate())
        }
        if let local, let id = local.id, id != manifest.libraryID {
            outcome.database = .otherLibrary
            return outcome
        }
        let wantsDatabase = local.map { $0.at.map { manifest.snapshotAt > $0 } ?? true } ?? true

        // Covers first, so the library shows with them when it reloads.
        let entries = try store.entries()
        let covers = entries.filter { isArtwork($0.path) }.filter { entry in
            guard let url = LibraryPath.resolve(entry.path, in: root) else { return false }
            return LibraryExporter.size(of: url) != entry.size
        }
        if !covers.isEmpty { progress(0, covers.count) }
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var next = covers.makeIterator()
            func add() {
                guard let entry = next.next(), let url = LibraryPath.resolve(entry.path, in: root) else { return }
                group.addTask {
                    try await store.copyOut(entry.path, to: url)
                    return entry.size
                }
            }
            for _ in 0..<max(1, concurrency) { add() }
            while let bytes = try await group.next() {
                outcome.files += 1; outcome.bytes += bytes
                progress(outcome.files, covers.count)
                add()
            }
        }

        guard wantsDatabase, entries.contains(where: { $0.path == manifest.current }) else { return outcome }
        let partial = root.appendingPathComponent(".library-icloud.sqlite")
        try? fm.removeItem(at: partial)
        try await store.copyOut(manifest.current, to: partial)
        do {
            let copy = try Database(snapshotAt: partial.path)
            // Read again: a Wi-Fi sync may have brought a newer copy while this one downloaded.
            let now = fm.fileExists(atPath: target.path) ? (try? Database(snapshotAt: target.path))?.snapshotDate() : nil
            guard copy.libraryID() == manifest.libraryID, let at = copy.snapshotDate(),
                  (now ?? local?.at).map({ at > $0 }) ?? true else {
                try? fm.removeItem(at: partial)
                return outcome
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        guard rename(partial.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        outcome.database = .replaced
        if !pending.isEmpty { outcome.applied = (try? Database(snapshotAt: target.path))?.appliedSyncIDs(among: pending) ?? [] }
        return outcome
    }

    /// The backup's `backup.json`, fetched (it may only be in iCloud), or nil when there's none or it can't be read.
    static func manifest(in store: CloudStore, scratch: URL) async throws -> CloudBackupManifest? {
        guard try store.entries().contains(where: { $0.path == CloudBackupManifest.path }) else { return nil }
        let copy = scratch.appendingPathComponent("backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await store.copyOut(CloudBackupManifest.path, to: copy)
        guard let size = LibraryExporter.size(of: copy), size <= CloudBackupManifest.sizeLimit else { return nil }
        return try? CloudBackupManifest.decode(Data(contentsOf: copy))
    }

    /// Album covers, the collection's own covers and artist photos: what the phone always has.
    static func isArtwork(_ path: String) -> Bool {
        guard SyncPlan.isManaged(path) else { return false }
        return (path.hasPrefix("Music/") && (path as NSString).lastPathComponent == "cover.jpg")
            || SyncPlan.isCollectionCover(path) || path.hasPrefix(LibraryExporter.artistImageFolder + "/")
    }
}

/// What fetching songs from iCloud did (P5).
public struct CloudFetchOutcome: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    /// Songs the backup doesn't hold (not chosen for it, or still uploading): they wait for the Mac.
    public var notInCloud: Set<Int64> = []
}

public enum CloudFetchError: Error, LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "There isn't room on this iPhone: the songs need \(f.string(fromByteCount: needed)), and \(f.string(fromByteCount: available)) is free."
        }
    }
}

extension CloudReceiver {
    /// Copies the songs the phone asked for from the backup into `root` (`docs/icloud-plan.md` D12, D16): each is
    /// downloaded, copied in through a partial and a rename, and evicted from the container again, so it's an ordinary
    /// file the phone plays offline and Remove deletes. Songs already here at the backup's size are skipped; songs the
    /// backup doesn't hold are reported. Refuses when they don't fit in `freeSpace`. Track paths come from the database
    /// copy, so they're checked to be plain paths in the managed folders and resolved inside `root`.
    public static func fetch(_ tracks: [Track], from store: CloudStore, into root: URL, freeSpace: Int64?, concurrency: Int = 2,
                             progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> CloudFetchOutcome {
        var inCloud: [String: CloudEntry] = [:]
        for entry in try store.entries(under: "Music") where SyncPlan.isManaged(entry.path) { inCloud[entry.path] = entry }
        var outcome = CloudFetchOutcome()
        var wanted: [(entry: CloudEntry, url: URL)] = []
        var seen = Set<String>()
        for track in tracks where seen.insert(track.path).inserted {
            guard SyncPlan.isManaged(track.path), let url = LibraryPath.resolve(track.path, in: root) else { continue }
            guard let entry = inCloud[track.path] else { outcome.notInCloud.insert(track.id); continue }
            if LibraryExporter.size(of: url) == entry.size { continue }
            wanted.append((entry, url))
        }
        let needed = wanted.reduce(0) { $0 + $1.entry.size }
        if let freeSpace, needed > freeSpace { throw CloudFetchError.notEnoughSpace(needed: needed, available: freeSpace) }

        let total = wanted.count
        progress(0, total)
        try await withThrowingTaskGroup(of: Int64.self) { group in
            var next = wanted.makeIterator()
            func add() {
                guard let file = next.next() else { return }
                group.addTask {
                    try await store.copyOut(file.entry.path, to: file.url)
                    return file.entry.size
                }
            }
            for _ in 0..<max(1, concurrency) { add() }
            while let bytes = try await group.next() {
                outcome.files += 1; outcome.bytes += bytes
                progress(outcome.files, total)
                add()
            }
        }
        return outcome
    }
}
