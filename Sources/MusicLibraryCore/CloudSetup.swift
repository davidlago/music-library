import Foundation

/// What a Mac set up from iCloud found and took (`docs/icloud-plan.md` D21).
public struct CloudMoveResult: Equatable, Sendable {
    public var tracks = 0
    /// Songs recorded as offloaded: every one the backup holds.
    public var offloaded = 0
    /// Covers and artist photos copied in.
    public var files = 0
    public var bytes: Int64 = 0
    /// What the backup was set to back up, when this version knows it.
    public var scope: CloudBackupScope?
    public var macName = ""
}

public enum CloudSetupError: Error, LocalizedError, Equatable {
    case noBackup
    /// Moving only goes into a library with nothing in it yet.
    case libraryNotEmpty

    public var errorDescription: String? {
        switch self {
        case .noBackup: return "There's no library backed up in iCloud."
        case .libraryNotEmpty: return "This Mac already has a library. Setting up from iCloud needs an empty one."
        }
    }
}

public enum CloudSetup {
    /// The backup's `backup.json`, for offering Set Up from iCloud; nil when there's none or it can't be read.
    public static func backup(in store: CloudStore) -> CloudBackupManifest? {
        (try? CloudBackup.manifest(in: store)) ?? nil
    }

    /// Moves the backed-up library onto this Mac (Move My Library to This Mac): into `database`, the open library at
    /// `root`, which must have no songs and no collection items. The covers, collection covers and artist photos come
    /// down first, then the current snapshot replaces the database in place (`Database.restore`, so the open
    /// connection sees it), then every song the backup holds is recorded as offloaded (D17): they download when
    /// played, or with Download to This Mac. Nothing of the old Mac's own offloading is kept. The caller then backs up
    /// from here, taking the backup over (`CloudBackup.publish(takingOver:)`), which tells the other Mac it moved.
    /// Everything from the container is untrusted, as in `CloudReceiver`.
    public static func moveLibrary(from store: CloudStore, into database: Database, root: URL, scratch: URL, now: Date = Date(),
                                   progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> CloudMoveResult {
        let items = try database.query("SELECT COUNT(*) FROM collection_items") { $0.int(0) ?? 0 }.first ?? 0
        guard try database.trackCount() == 0, items == 0 else { throw CloudSetupError.libraryNotEmpty }
        guard let manifest = try CloudBackup.manifest(in: store) else { throw CloudSetupError.noBackup }
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let entries = try store.entries()
        guard entries.contains(where: { $0.path == manifest.current }) else { throw CloudSetupError.noBackup }
        let copy = scratch.appendingPathComponent("move-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: copy) }
        try await store.copyOut(manifest.current, to: copy)
        guard try Database(snapshotAt: copy.path).libraryID() == manifest.libraryID else { throw CloudSetupError.noBackup }

        var result = CloudMoveResult(scope: CloudBackupScope(rawValue: manifest.scope), macName: manifest.macName)
        let artwork = entries.filter { CloudReceiver.isArtwork($0.path) }
        progress(0, artwork.count)
        for entry in artwork {
            try Task.checkCancellation()
            guard let url = LibraryPath.resolve(entry.path, in: root) else { continue }
            try await store.copyOut(entry.path, to: url)
            result.files += 1; result.bytes += entry.size
            progress(result.files, artwork.count)
        }

        // The empty library's own database, kept only for the catalog `restore` takes back (there's none yet).
        let before = scratch.appendingPathComponent("move-before-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: before) }
        try database.vacuum(into: before.path)
        try database.restore(from: copy.path, keepingCatalogFrom: before.path)
        try database.exec("DELETE FROM offloaded_tracks")

        var inCloud: [String: CloudEntry] = [:]
        for entry in entries where CloudBackupPlan.isMusic(entry.path) { inCloud[entry.path] = entry }
        let tracks = try database.fetchAllTracks()
        result.tracks = tracks.count
        let rows = tracks.compactMap { track -> OffloadedTrack? in
            guard let entry = inCloud[track.path], LibraryPath.resolve(track.path, in: root).flatMap(LibraryExporter.size(of:)) == nil else { return nil }
            return OffloadedTrack(trackID: track.id, path: track.path, size: entry.size,
                                  modified: entry.modified ?? Date(timeIntervalSince1970: 0), offloadedAt: now)
        }
        try database.markOffloaded(rows)
        result.offloaded = rows.count
        return result
    }
}
