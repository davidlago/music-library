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
}

/// The phone's side of the backup (`docs/icloud-plan.md` §6, P4): brings the library at `root` up to the newest copy
/// in iCloud without a Mac nearby. The database is replaced only when the backup's `snapshot_at` is newer than the
/// phone's (D6), so a copy from iCloud never undoes a newer one a Wi-Fi sync brought, in either order; a copy without
/// a stamp (older Macs) counts as older than any. Every cover and artist photo the backup holds that the phone lacks,
/// or has at another size, is copied in, as Wi-Fi sync sends them all. Everything from the container is untrusted:
/// the database is opened read-only and checked first (a newer schema is refused), only cover and photo paths are
/// taken, and each is resolved inside `root`; files are made aside and renamed into place.
public enum CloudReceiver {
    public static func receive(from store: CloudStore, into root: URL, scratch: URL, concurrency: Int = 6) async throws -> CloudReceiveOutcome {
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
