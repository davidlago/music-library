import Foundation

/// A database copy in the backup, newest first in `CloudRestore.snapshots`.
public struct CloudSnapshotListing: Identifiable, Equatable, Sendable {
    public var path: String
    public var date: Date
    /// The one `backup.json` names.
    public var isCurrent: Bool
    public var id: String { path }
}

/// What a database copy holds, read from the copy itself. Nil where it can't tell.
public struct CloudSnapshotDetails: Equatable, Sendable {
    public var libraryID: String?
    public var tracks: Int?
    public var items: Int?
    public var plays: Int?
    public var likes: Int?

    public init(libraryID: String? = nil, tracks: Int? = nil, items: Int? = nil, plays: Int? = nil, likes: Int? = nil) {
        self.libraryID = libraryID; self.tracks = tracks; self.items = items; self.plays = plays; self.likes = likes
    }
}

/// What a restore to a new folder copied. `missing`: songs and covers the database names that the backup doesn't hold
/// (with "Library and covers", every song).
public struct CloudRestoreResult: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    public var missing: [String] = []
}

public enum CloudRestoreError: Error, LocalizedError, Equatable {
    case folderNotEmpty
    case notEnoughSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .folderNotEmpty: return "Choose an empty folder to restore into."
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "The restore needs \(f.string(fromByteCount: needed)), and there's \(f.string(fromByteCount: available)) free there."
        }
    }
}

/// Getting a library back from the backup (`docs/icloud-plan.md` §7): into a new, empty folder (the database copy,
/// and the songs, covers and photos it names that the backup holds), or the database alone into the open library.
/// Everything read from the backup is untrusted: copies are opened read-only first (`Database(snapshotAt:)` refuses a
/// newer schema), and paths are checked (`SyncPlan.isManaged`) and resolved inside the destination before anything is
/// written. Nothing is ever written into the open library's folders.
public enum CloudRestore {
    /// The database copies in the backup, newest first.
    public static func snapshots(in store: CloudStore) throws -> [CloudSnapshotListing] {
        let current = (try? CloudBackup.manifest(in: store))??.current
        return try store.entries().compactMap { entry in
            CloudSnapshots.date(ofPath: entry.path).map { CloudSnapshotListing(path: entry.path, date: $0, isCurrent: entry.path == current) }
        }.sorted { $0.date > $1.date }
    }

    /// Reads a copy's counts (downloading it when it's only in iCloud).
    public static func details(of snapshot: String, in store: CloudStore, scratch: URL) async throws -> CloudSnapshotDetails {
        let copy = try await fetch(snapshot, from: store, scratch: scratch)
        defer { try? FileManager.default.removeItem(at: copy) }
        let db = try Database(snapshotAt: copy.path)
        func count(_ table: String) -> Int? { try? db.query("SELECT COUNT(*) FROM \(table)") { $0.int(0) ?? 0 }.first }
        return CloudSnapshotDetails(libraryID: db.libraryID(), tracks: count("tracks"), items: count("collection_items"),
                                    plays: count("plays"), likes: count("liked_tracks"))
    }

    /// The backup's files a restore of `database` copies: its songs, their albums' covers, the collection's own covers
    /// and every artist photo; and the songs and collection covers it names that the backup doesn't hold.
    static func files(for database: Database, entries: [CloudEntry]) throws -> (copy: [CloudEntry], missing: [String]) {
        var inCloud: [String: CloudEntry] = [:]
        for entry in entries where SyncPlan.isManaged(entry.path) { inCloud[entry.path] = entry }
        var wanted: [String] = [], required = Set<String>(), seen = Set<String>()
        func want(_ path: String, required needed: Bool) {
            guard SyncPlan.isManaged(path), seen.insert(path).inserted else { return }
            wanted.append(path)
            if needed { required.insert(path) }
        }
        for track in try database.fetchAllTracks() {
            want(track.path, required: true)
            want(((track.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cover.jpg"), required: false)
        }
        for path in try database.collectionCoverPaths() where SyncPlan.isCollectionCover(path) { want(path, required: true) }
        for path in inCloud.keys.sorted() where path.hasPrefix(LibraryExporter.artistImageFolder + "/") { want(path, required: false) }
        return (wanted.compactMap { inCloud[$0] }, wanted.filter { required.contains($0) && inCloud[$0] == nil })
    }

    /// Restores the library as it was in `snapshot` into `root`, which must be empty (or not exist yet). The database
    /// goes in last, so a folder without `library.sqlite` is an unfinished restore. `progress` gets files done and
    /// the total.
    public static func restore(_ snapshot: String, from store: CloudStore, to root: URL, scratch: URL,
                               progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CloudRestoreResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            guard try fm.contentsOfDirectory(atPath: root.path).allSatisfy({ $0.hasPrefix(".") }) else { throw CloudRestoreError.folderNotEmpty }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let copy = try await fetch(snapshot, from: store, scratch: scratch)
        defer { try? fm.removeItem(at: copy) }
        let (files, missing) = try files(for: try Database(snapshotAt: copy.path), entries: try store.entries())
        let needed = files.reduce(0) { $0 + $1.size } + (LibraryExporter.size(of: copy) ?? 0)
        if let available = LibraryExporter.availableCapacity(at: root), needed > available {
            throw CloudRestoreError.notEnoughSpace(needed: needed, available: available)
        }

        var result = CloudRestoreResult(missing: missing)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(index, files.count)
            guard let destination = LibraryPath.resolve(file.path, in: root) else { result.missing.append(file.path); continue }
            try await store.copyOut(file.path, to: destination)
            result.files += 1; result.bytes += file.size
        }
        progress(files.count, files.count)

        let target = LibraryLocation.databaseURL(root: root)
        let partial = root.appendingPathComponent(".library-restoring.sqlite")
        try? fm.removeItem(at: partial)
        try fm.copyItem(at: copy, to: partial)
        do {
            // Opened read-write once, which brings an older copy up to date, and made a live database again.
            let db = try Database(path: partial.path)
            try db.clearSnapshotStamp()
        }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: partial.path + suffix) }
        guard rename(partial.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        return result
    }

    /// Restores only the database of the library open in `database` (at `root`) to `snapshot`, after saving it as
    /// `library-before-restore-<time>.sqlite` next to it; returns that file. Songs whose files aren't there show as
    /// missing, as they would otherwise. The downloaded library catalog is kept.
    public static func restoreDatabase(_ snapshot: String, from store: CloudStore, into database: Database, root: URL,
                                       scratch: URL, now: Date = Date()) async throws -> URL {
        let copy = try await fetch(snapshot, from: store, scratch: scratch)
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try Database(snapshotAt: copy.path)
        let stamp = now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let before = root.appendingPathComponent("library-before-restore-\(stamp).sqlite")
        try database.vacuum(into: before.path)
        try database.restore(from: copy.path, keepingCatalogFrom: before.path)
        return before
    }

    /// A local copy of a snapshot in `scratch`.
    private static func fetch(_ snapshot: String, from store: CloudStore, scratch: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        try await store.copyOut(snapshot, to: copy)
        return copy
    }
}
