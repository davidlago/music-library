import Foundation

/// What goes to the iCloud backup (`docs/icloud-plan.md` D10). Off by default.
public enum CloudBackupScope: String, Codable, Sendable, CaseIterable {
    case off
    /// The database, album and collection covers, and artist photos.
    case library
    /// Those, plus the music files of what's chosen (D15).
    case chosen
    /// Those, plus every music file.
    case everything

    public var includesMusic: Bool { self == .chosen || self == .everything }
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

/// What a backup does besides writing the database (D7, D8): the files it should hold that iCloud doesn't have, or
/// has with another size or modification date (a retag can keep the size); the files iCloud has that it shouldn't
/// hold any more, which go on the removal list; and the ones removed long enough ago to delete.
public struct CloudBackupPlan: Equatable, Sendable {
    public var uploads: [CloudBackupFile]
    /// The removal list after this backup, purged files left out.
    public var removals: [CloudRemoval]
    /// Files removed more than `CloudRemoval.keptFor` ago, to delete from iCloud.
    public var purges: [String]
    public var bytes: Int64 { uploads.reduce(0) { $0 + $1.size } }

    /// `entries` come from the container, so any that aren't plain paths in the managed folders are ignored, and so
    /// are removal list entries that aren't.
    public init(files: [CloudBackupFile], entries: [CloudEntry], removals: [CloudRemoval] = [], now: Date = Date()) {
        var inCloud: [String: CloudEntry] = [:]
        for entry in entries where SyncPlan.isManaged(entry.path) { inCloud[entry.path] = entry }
        let wanted = Set(files.map(\.path))
        uploads = files.filter { file in
            guard let entry = inCloud[file.path], entry.size == file.size, let modified = entry.modified else { return true }
            return abs(modified.timeIntervalSince(file.modified)) >= 1
        }
        // Still in iCloud and still unwanted: listed since the first backup that didn't want it.
        var listed: [String: CloudRemoval] = [:]
        for removal in removals where inCloud[removal.path] != nil && !wanted.contains(removal.path) {
            listed[removal.path] = listed[removal.path].map { $0.removedAt <= removal.removedAt ? $0 : removal } ?? removal
        }
        for (path, entry) in inCloud where !wanted.contains(path) && listed[path] == nil {
            listed[path] = CloudRemoval(path: path, size: entry.size, removedAt: now)
        }
        let cutoff = now.addingTimeInterval(-CloudRemoval.keptFor)
        purges = listed.values.filter { $0.removedAt <= cutoff }.map(\.path).sorted()
        self.removals = listed.values.filter { $0.removedAt > cutoff }.sorted { $0.path < $1.path }
    }

    /// The library files a backup holds, in upload order: every album's `cover.jpg`, the collection items' own covers
    /// (`Database.collectionCoverPaths`), artist photos, then the files of `music` (the tracks the scope backs up).
    /// Only regular files inside `root` count.
    public static func files(tracks: [Track], collectionCovers: [String], music: [Track] = [], root: URL) -> [CloudBackupFile] {
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
        for track in music { add(track.path) }
        return files
    }

    /// A song's file, as opposed to a cover or photo: the files a backup evicts from the Mac once uploaded (D11).
    public static func isMusic(_ path: String) -> Bool {
        SyncPlan.isManaged(path) && supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// A file that left the backup's wanted set, kept in iCloud for `keptFor` so a mistake can be undone (D8). The list
/// is `Removed.json`; read back from the container, it's untrusted (`decode`).
public struct CloudRemoval: Codable, Equatable, Sendable {
    public static let path = "Removed.json"
    public static let keptFor: TimeInterval = 30 * 86400
    static let sizeLimit = 64 * 1024 * 1024

    public var path: String
    public var size: Int64
    public var removedAt: Date

    public init(path: String, size: Int64, removedAt: Date) {
        self.path = path; self.size = size; self.removedAt = removedAt
    }

    /// The list, without entries that aren't plain paths in the managed folders. Unreadable means empty: every
    /// unwanted file is then listed again from now, which only delays purging.
    public static func decode(_ data: Data) -> [CloudRemoval] {
        guard data.count <= sizeLimit else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([CloudRemoval].self, from: data)) ?? []).filter { SyncPlan.isManaged($0.path) && $0.size >= 0 }
    }

    public static func encode(_ removals: [CloudRemoval]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(removals)
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
    /// Files not copied into iCloud this time (the run's time was up, or iCloud wasn't keeping up); the next publish
    /// goes on.
    public var remaining = 0
    /// Music copied into iCloud that hadn't uploaded when the run ended, so it's still on the Mac until the next run.
    public var waiting = 0
    /// Files put on the removal list, and files deleted from iCloud after their 30 days.
    public var removed = 0
    public var purged = 0
}

/// How a publish paces itself. Music is copied into the container (an APFS clone where it can) and evicted once
/// uploaded; when the library is on another volume each copy takes real space, so at most `inFlightBytes` wait for
/// iCloud at a time, and a run stops copying after `runTime` (a first backup of a big library spans many runs).
public struct CloudUploadLimits: Sendable {
    public var inFlightBytes: Int64
    public var runTime: Duration
    /// How long the snapshot may take to upload before `backup.json` is left for the next publish.
    public var snapshotTimeout: Duration
    public var poll: Duration

    public init(inFlightBytes: Int64 = 2 << 30, runTime: Duration = .seconds(30 * 60), snapshotTimeout: Duration = .seconds(300),
                poll: Duration = .seconds(2)) {
        self.inFlightBytes = inFlightBytes; self.runTime = runTime; self.snapshotTimeout = snapshotTimeout; self.poll = poll
    }
}

public enum CloudBackup {
    /// The files a backup can hold: the library's managed folders (`Music`, `Artist Images`), the snapshots,
    /// `backup.json`, `Removed.json` and the phones' inbox batches.
    public static func isBackupPath(_ path: String) -> Bool {
        path == CloudBackupManifest.path || path == CloudRemoval.path || CloudSnapshots.date(ofPath: path) != nil
            || SyncPlan.isManaged(path) || CloudInbox.parse(path) != nil
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

    /// Backs the library up (§5): a new snapshot, then the covers, photos and `music` files that changed (music evicted
    /// from the Mac once uploaded), then `backup.json` once the snapshot is in iCloud, then the removal list, purges
    /// and old snapshots. `music` is what the scope backs up (none for "Library and covers"). `replacingOther`
    /// replaces a backup of another library, its snapshots included. `deletingRemovedNow` deletes every file the backup
    /// no longer wants at once instead of after `CloudRemoval.keptFor` (Delete Now, to free iCloud space). Cancelling
    /// the task stops the music copy (what's left is `remaining`) and leaves the rest of the run as it would be.
    public static func publish(database: Database, root: URL, store: CloudStore, identity: CloudBackupIdentity,
                               scope: CloudBackupScope, music: [Track] = [], scratch: URL, now: Date = Date(),
                               replacingOther: Bool = false, deletingRemovedNow: Bool = false,
                               limits: CloudUploadLimits = CloudUploadLimits()) async throws -> CloudBackupResult {
        guard let libraryID = database.libraryID() else { throw CloudBackupError.noLibraryID }
        var replacing = false
        if let existing = try manifest(in: store), existing.libraryID != libraryID {
            guard replacingOther else { throw CloudBackupError.otherLibrary(macName: existing.macName, snapshotAt: existing.snapshotAt) }
            replacing = true
        }
        let started = ContinuousClock.now
        let snapshotAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let snapshot = CloudSnapshots.path(for: snapshotAt)
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        defer { try? fm.removeItem(at: copy) }
        try database.writeBackupSnapshot(to: copy, scratch: scratch, snapshotAt: snapshotAt)
        try store.upload(from: copy, to: snapshot, modified: snapshotAt)

        let tracks = try database.fetchAllTracks()
        let files = CloudBackupPlan.files(tracks: tracks, collectionCovers: try database.collectionCoverPaths(),
                                          music: scope.includesMusic ? music : [], root: root)
        // Unreadable reads as empty, which only delays purging.
        let removals = ((try? store.read(CloudRemoval.path, limit: CloudRemoval.sizeLimit)) ?? nil).map(CloudRemoval.decode) ?? []
        let plan = CloudBackupPlan(files: files, entries: try store.entries(), removals: removals, now: now)
        var result = CloudBackupResult(snapshot: snapshot, snapshotAt: snapshotAt, files: 0, bytes: 0, isCurrent: false)
        func upload(_ file: CloudBackupFile) throws -> Bool {
            guard let url = LibraryPath.resolve(file.path, in: root) else { return false }
            do {
                try store.upload(from: url, to: file.path, modified: file.modified)
                result.files += 1; result.bytes += file.size
                return true
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                return false  // Removed since the plan was made.
            }
        }

        // The database, covers and photos first, so a long music upload never holds back the current snapshot.
        let music = plan.uploads.filter { CloudBackupPlan.isMusic($0.path) }
        for file in plan.uploads where !CloudBackupPlan.isMusic(file.path) { _ = try upload(file) }
        guard await store.waitUntilUploaded(snapshot, timeout: limits.snapshotTimeout) else {
            result.remaining = music.count
            return result
        }
        var musicBytes: Int64 = 0
        for track in tracks { musicBytes += track.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0 }
        let manifest = CloudBackupManifest(libraryID: libraryID, macID: identity.macID, macName: identity.macName,
                                           appVersion: identity.appVersion, scope: scope, current: snapshot,
                                           snapshotAt: snapshotAt, tracks: tracks.count, musicBytes: musicBytes)
        try store.write(try manifest.encoded(), to: CloudBackupManifest.path)
        result.isCurrent = true

        // Music waiting for iCloud, evicted from the Mac once uploaded (D11).
        var inFlight: [(path: String, size: Int64)] = []
        func settle() -> Bool {
            let before = inFlight.count
            inFlight.removeAll { file in
                guard store.isUploaded(file.path) else { return false }
                try? store.evict(file.path)
                return true
            }
            return inFlight.count < before
        }
        let overTime = { ContinuousClock.now - started >= limits.runTime || Task.isCancelled }
        copying: for (index, file) in music.enumerated() {
            while !inFlight.isEmpty, inFlight.reduce(0, { $0 + $1.size }) + file.size > limits.inFlightBytes {
                if settle() { continue }
                if overTime() { result.remaining = music.count - index; break copying }
                try? await Task.sleep(for: limits.poll)
            }
            if overTime() { result.remaining = music.count - index; break }
            if try upload(file) { inFlight.append((file.path, file.size)) }
        }
        // What's still uploading is waited for (within the run's time), so it leaves the Mac now, not at the next run.
        while !inFlight.isEmpty, !overTime() {
            if !settle() { try? await Task.sleep(for: limits.poll) }
        }
        result.waiting = inFlight.count

        // Deleted only after their 30 days (or all of them now); a file whose deletion fails stays listed.
        var kept = deletingRemovedNow ? [] : plan.removals
        let purges = deletingRemovedNow ? plan.purges + plan.removals.map(\.path) : plan.purges
        for path in purges {
            do { try store.remove(path); result.purged += 1 } catch {
                if let removal = plan.removals.first(where: { $0.path == path }) ?? removals.first(where: { $0.path == path }) {
                    kept.append(removal)
                }
            }
        }
        result.removed = deletingRemovedNow ? 0 : plan.removals.filter { old in !removals.contains { $0.path == old.path } }.count
        if kept != removals { try store.write(try CloudRemoval.encode(kept.sorted { $0.path < $1.path }), to: CloudRemoval.path) }

        var snapshots: [Date: String] = [:]
        let entries = try store.entries()
        for entry in entries { if let date = CloudSnapshots.date(ofPath: entry.path) { snapshots[date] = entry.path } }
        let keep = replacing ? [snapshotAt] : CloudSnapshots.kept(Array(snapshots.keys), now: now).union([snapshotAt])
        for (date, path) in snapshots where !keep.contains(date) { try store.remove(path) }
        // Music uploaded earlier (or by an earlier run) that's still on the Mac.
        for entry in entries where entry.isUploaded && entry.isLocal && CloudBackupPlan.isMusic(entry.path) { try? store.evict(entry.path) }
        return result
    }

    /// What's waiting to be deleted from the backup (`Removed.json`): files and bytes. Zero when there's no list.
    public static func awaitingDeletion(in store: CloudStore) -> (files: Int, bytes: Int64) {
        guard let data = (try? store.read(CloudRemoval.path, limit: CloudRemoval.sizeLimit)) ?? nil else { return (0, 0) }
        let list = CloudRemoval.decode(data)
        return (list.count, list.reduce(0) { $0 + $1.size })
    }

    /// About how much a backup puts in iCloud: the database (catalog included, so a little more), the covers and
    /// photos, and `music`'s files.
    public static func estimatedSize(database: Database, root: URL, music: [Track] = []) -> Int64 {
        guard let tracks = try? database.fetchAllTracks() else { return 0 }
        let files = CloudBackupPlan.files(tracks: tracks, collectionCovers: (try? database.collectionCoverPaths()) ?? [], music: music, root: root)
        let databaseSize = LibraryExporter.size(of: LibraryLocation.databaseURL(root: root)) ?? 0
        return files.reduce(databaseSize) { $0 + $1.size }
    }
}
