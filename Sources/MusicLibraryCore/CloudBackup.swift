import Foundation

/// What goes to the iCloud backup (`docs/icloud-plan.md` D10). Off by default.
public enum CloudBackupScope: String, Codable, Sendable, CaseIterable {
    case off
    /// The database, album and collection covers, and artist photos.
    case library
}

/// `backup.json`: what the backup holds and which snapshot is current. Replaced only once the snapshot it names is
/// in iCloud. Read back from the container, so it's untrusted (`decode`).
public struct CloudBackupManifest: Codable, Equatable, Sendable {
    public static let path = "backup.json"
    public static let currentFormat = 1
    static let sizeLimit = 64 * 1024

    public var format: Int
    /// `library_meta.library_id`: one backup never mixes two libraries.
    public var libraryID: String
    public var macID: String
    public var macName: String
    public var appVersion: String
    public var schemaVersion: Int
    /// A `CloudBackupScope` raw value, kept as text so a newer one can be read.
    public var scope: String
    /// The snapshot to read, in `Snapshots/`.
    public var current: String
    public var snapshotAt: Date
    public var tracks: Int
    /// The library's music files, whether or not they're in the backup.
    public var musicBytes: Int64

    public init(libraryID: String, macID: String, macName: String, appVersion: String, scope: CloudBackupScope,
                current: String, snapshotAt: Date, tracks: Int, musicBytes: Int64) {
        format = Self.currentFormat
        self.libraryID = libraryID; self.macID = macID; self.macName = macName; self.appVersion = appVersion
        schemaVersion = Database.schemaVersion
        self.scope = scope.rawValue; self.current = current; self.snapshotAt = snapshotAt
        self.tracks = tracks; self.musicBytes = musicBytes
    }

    public enum DecodeError: Error, Equatable {
        /// Written by a newer version of the app, in a format this one can't read.
        case newerFormat(Int)
        case invalid
    }

    public static func decode(_ data: Data) throws -> CloudBackupManifest {
        guard data.count <= sizeLimit else { throw DecodeError.invalid }
        struct Format: Decodable { var format: Int }
        guard let format = try? JSONDecoder().decode(Format.self, from: data).format else { throw DecodeError.invalid }
        guard format <= currentFormat else { throw DecodeError.newerFormat(format) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CloudBackupManifest.self, from: data), manifest.format == currentFormat,
              CloudSnapshots.date(ofPath: manifest.current) != nil, !manifest.libraryID.isEmpty else { throw DecodeError.invalid }
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// The database copies in `Snapshots/`, named after when they were made (UTC, to the second), and which to keep
/// (D9): the last 10, the newest of each day for 14 days and of each week for 8 weeks.
public enum CloudSnapshots {
    public static let folder = "Snapshots"

    /// "Snapshots/2026-10-31T14-05-12Z.sqlite".
    public static func path(for date: Date) -> String {
        "\(folder)/\(date.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")).sqlite"
    }

    /// When the snapshot at `path` was made, or nil for any other path.
    public static func date(ofPath path: String) -> Date? {
        let prefix = folder + "/", suffix = ".sqlite"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        var name = Array(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard name.count == 20, name[13] == "-", name[16] == "-" else { return nil }
        name[13] = ":"; name[16] = ":"
        guard let date = try? Date(String(name), strategy: .iso8601), Self.path(for: date) == path else { return nil }
        return date
    }

    public static func kept(_ dates: [Date], now: Date, calendar: Calendar = .current) -> Set<Date> {
        let newest = dates.sorted(by: >)
        var keep = Set(newest.prefix(10))
        var days = Set<Date>(), weeks = Set<Date>()
        let dayLimit = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let weekLimit = calendar.date(byAdding: .weekOfYear, value: -8, to: now) ?? now
        for date in newest {
            if date > dayLimit, let day = calendar.dateInterval(of: .day, for: date)?.start, days.insert(day).inserted { keep.insert(date) }
            if date > weekLimit, let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start, weeks.insert(week).inserted {
                keep.insert(date)
            }
        }
        return keep
    }
}

/// A library file a backup holds.
public struct CloudBackupFile: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path; self.size = size; self.modified = modified
    }
}

/// What a backup uploads besides the database: the files it should hold that iCloud doesn't have, or has with
/// another size or modification date (a retag can keep the size; D7).
public struct CloudBackupPlan: Equatable, Sendable {
    public var uploads: [CloudBackupFile]
    public var bytes: Int64 { uploads.reduce(0) { $0 + $1.size } }

    /// `entries` come from the container, so any that aren't plain paths in the managed folders are ignored.
    public init(files: [CloudBackupFile], entries: [CloudEntry]) {
        var inCloud: [String: CloudEntry] = [:]
        for entry in entries where SyncPlan.isManaged(entry.path) { inCloud[entry.path] = entry }
        uploads = files.filter { file in
            guard let entry = inCloud[file.path], entry.size == file.size, let modified = entry.modified else { return true }
            return abs(modified.timeIntervalSince(file.modified)) >= 1
        }
    }

    /// The library files the scope backs up, in upload order: every album's `cover.jpg`, the collection items' own
    /// covers (`Database.collectionCoverPaths`), then artist photos. Only regular files inside `root` count.
    public static func files(tracks: [Track], collectionCovers: [String], root: URL, scope: CloudBackupScope) -> [CloudBackupFile] {
        guard scope != .off else { return [] }
        var files: [CloudBackupFile] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard SyncPlan.isManaged(path), seen.insert(path).inserted, let url = LibraryPath.resolve(path, in: root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date else { return }
            files.append(CloudBackupFile(path: path, size: size, modified: modified))
        }
        var folders = Set<String>()
        for track in tracks {
            let folder = (track.path as NSString).deletingLastPathComponent
            if folders.insert(folder).inserted { add((folder as NSString).appendingPathComponent("cover.jpg")) }
        }
        for path in collectionCovers.sorted() where SyncPlan.isCollectionCover(path) { add(path) }
        let images = LibraryExporter.artistImageFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(images).path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") { add((images as NSString).appendingPathComponent(name)) }
        return files
    }
}

/// Who's publishing, for `backup.json`.
public struct CloudBackupIdentity: Sendable {
    public var macID: String
    public var macName: String
    public var appVersion: String

    public init(macID: String, macName: String, appVersion: String) {
        self.macID = macID; self.macName = macName; self.appVersion = appVersion
    }
}

public enum CloudBackupError: Error, LocalizedError, Equatable {
    /// The backup holds another library (a second Mac, or a library folder switched): never mixed with this one.
    case otherLibrary(macName: String, snapshotAt: Date)
    /// A newer version of the app wrote the backup.
    case newerBackup
    /// The library has no identity yet (it's made when the database is opened).
    case noLibraryID

    public var errorDescription: String? {
        switch self {
        case .otherLibrary(let mac, _): return "iCloud holds a backup of another library, from \(mac)."
        case .newerBackup: return "iCloud holds a backup made by a newer version of Music Library. Update the app to back up."
        case .noLibraryID: return "This library can't be backed up yet."
        }
    }
}

/// What one publish did.
public struct CloudBackupResult: Equatable, Sendable {
    public var snapshot: String
    public var snapshotAt: Date
    public var files: Int
    public var bytes: Int64
    /// False when iCloud hadn't uploaded the snapshot in time, so `backup.json` still names the previous one and the
    /// next publish tries again.
    public var isCurrent: Bool
}

public enum CloudBackup {
    /// The files a backup can hold: the library's managed folders (`Music`, `Artist Images`), the snapshots and
    /// `backup.json`.
    public static func isBackupPath(_ path: String) -> Bool {
        path == CloudBackupManifest.path || CloudSnapshots.date(ofPath: path) != nil || SyncPlan.isManaged(path)
    }

    /// The backup's `backup.json`, or nil when there's none or it can't be read (it's then replaced).
    public static func manifest(in store: CloudStore) throws -> CloudBackupManifest? {
        let data: Data
        do {
            guard let read = try store.read(CloudBackupManifest.path, limit: CloudBackupManifest.sizeLimit) else { return nil }
            data = read
        } catch CloudStoreError.tooLarge { return nil }
        do { return try CloudBackupManifest.decode(data) } catch CloudBackupManifest.DecodeError.newerFormat {
            throw CloudBackupError.newerBackup
        } catch { return nil }
    }

    /// Backs the library up (§5): a new snapshot, then the files that changed, then `backup.json` once the snapshot
    /// is in iCloud, then old snapshots pruned. `replacingOther` replaces a backup of another library, its snapshots
    /// included.
    public static func publish(database: Database, root: URL, store: CloudStore, identity: CloudBackupIdentity,
                               scope: CloudBackupScope, scratch: URL, now: Date = Date(), replacingOther: Bool = false,
                               uploadTimeout: Duration = .seconds(300)) async throws -> CloudBackupResult {
        guard let libraryID = database.libraryID() else { throw CloudBackupError.noLibraryID }
        var replacing = false
        if let existing = try manifest(in: store), existing.libraryID != libraryID {
            guard replacingOther else { throw CloudBackupError.otherLibrary(macName: existing.macName, snapshotAt: existing.snapshotAt) }
            replacing = true
        }
        let snapshotAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let snapshot = CloudSnapshots.path(for: snapshotAt)
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: copy) }
        try database.writeBackupSnapshot(to: copy, scratch: scratch, snapshotAt: snapshotAt)
        try store.upload(from: copy, to: snapshot, modified: snapshotAt)

        let tracks = try database.fetchAllTracks()
        let files = CloudBackupPlan.files(tracks: tracks, collectionCovers: try database.collectionCoverPaths(), root: root, scope: scope)
        let plan = CloudBackupPlan(files: files, entries: try store.entries())
        var uploaded = 0, bytes: Int64 = 0
        for file in plan.uploads {
            guard let url = LibraryPath.resolve(file.path, in: root) else { continue }
            do {
                try store.upload(from: url, to: file.path, modified: file.modified)
                uploaded += 1; bytes += file.size
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                // Removed since the plan was made.
            }
        }

        guard await store.waitUntilUploaded(snapshot, timeout: uploadTimeout) else {
            return CloudBackupResult(snapshot: snapshot, snapshotAt: snapshotAt, files: uploaded, bytes: bytes, isCurrent: false)
        }
        var musicBytes: Int64 = 0
        for track in tracks { musicBytes += track.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0 }
        let manifest = CloudBackupManifest(libraryID: libraryID, macID: identity.macID, macName: identity.macName,
                                           appVersion: identity.appVersion, scope: scope, current: snapshot,
                                           snapshotAt: snapshotAt, tracks: tracks.count, musicBytes: musicBytes)
        try store.write(try manifest.encoded(), to: CloudBackupManifest.path)

        var snapshots: [Date: String] = [:]
        for entry in try store.entries() { if let date = CloudSnapshots.date(ofPath: entry.path) { snapshots[date] = entry.path } }
        let kept = replacing ? [snapshotAt] : CloudSnapshots.kept(Array(snapshots.keys), now: now).union([snapshotAt])
        for (date, path) in snapshots where !kept.contains(date) { try store.remove(path) }
        return CloudBackupResult(snapshot: snapshot, snapshotAt: snapshotAt, files: uploaded, bytes: bytes, isCurrent: true)
    }

    /// About how much the scope puts in iCloud: the database (catalog included, so a little more) and the files.
    public static func estimatedSize(database: Database, root: URL, scope: CloudBackupScope) -> Int64 {
        guard scope != .off, let tracks = try? database.fetchAllTracks() else { return 0 }
        let files = CloudBackupPlan.files(tracks: tracks, collectionCovers: (try? database.collectionCoverPaths()) ?? [], root: root, scope: scope)
        let databaseSize = LibraryExporter.size(of: LibraryLocation.databaseURL(root: root)) ?? 0
        return files.reduce(databaseSize) { $0 + $1.size }
    }
}
