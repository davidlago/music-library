import Darwin
import Foundation

public enum LibraryExportError: Error, LocalizedError {
    case insufficientSpace(needed: Int64, available: Int64)
    case missingSource(String)
    case copyFailed(path: String, code: Int32)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough space at the destination: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: available)) available."
        case .missingSource(let p): return "File missing from the library: \(p)"
        case .copyFailed(let p, let code): return "Could not copy \(p): \(String(cString: strerror(code)))"
        case .unsafePath(let p): return "Not a path inside the library: \(p)"
        }
    }
}

/// A playlist written next to the exported music, with paths relative to the playlist file.
public struct ExportPlaylist: Sendable {
    public var name: String
    public var tracks: [Track]
    public init(name: String, tracks: [Track]) { self.name = name; self.tracks = tracks }
}

public struct LibraryExportSummary: Sendable, Equatable {
    /// Music files copied, and those left alone because the destination already had them.
    public var copied = 0
    public var skipped = 0
    public var bytesCopied: Int64 = 0
    public var covers = 0
    public var artistImages = 0
    /// Collection items' own covers (with the database backup).
    public var collectionCovers = 0
    public var playlists = 0
    public var databaseBackedUp = false
    public init() {}
}

/// Mirrors part of the library onto another folder (a USB player, a backup disk) using the library's own layout,
/// `Music/<Artist>/<Album>/<NN - Title>.ext`, so the destination can also serve as a library root.
/// Files already at the destination are never overwritten and nothing is deleted; only the database backup
/// (`library.sqlite` at the destination root) and playlist files are replaced.
public struct LibraryExporter: Sendable {
    public static let playlistFolder = "Playlists"
    /// Photos downloaded for artist pages, referenced from the database.
    public static let artistImageFolder = "Artist Images"
    static let partialSuffix = ".mlpart"

    public init() {}

    public struct Plan: Sendable {
        /// Library-relative paths to copy, in order, with their sizes.
        public var files: [(path: String, size: Int64)] = []
        /// Album covers the destination is missing.
        public var covers: [(path: String, size: Int64)] = []
        /// Artist photos the destination is missing or has an older version of (only with the database backup).
        public var artistImages: [(path: String, size: Int64)] = []
        /// Collection items' own covers the destination is missing (only with the database backup, which refers to
        /// them). Each change of a cover has a new name, so they're never replaced.
        public var collectionCovers: [(path: String, size: Int64)] = []
        public var skipped = 0
        public var bytesNeeded: Int64 { (files + covers + artistImages + collectionCovers).reduce(0) { $0 + $1.size } }
    }

    /// What `export` would copy: tracks (deduplicated, in order) and album covers not yet at the destination, plus
    /// new or changed artist photos when `artistImages` is set and the `collectionCovers` (library-relative paths
    /// from `Database.collectionCoverPaths`) the destination is missing.
    public func plan(tracks: [Track], libraryRoot: URL, destination: URL, artistImages: Bool = false,
                     collectionCovers: [String] = []) throws -> Plan {
        let fm = FileManager.default
        var plan = Plan()
        var seenTracks = Set<String>(), seenDirs = Set<String>()
        for t in tracks where seenTracks.insert(t.path).inserted {
            guard let source = LibraryPath.resolve(t.path, in: libraryRoot), let target = LibraryPath.resolve(t.path, in: destination) else {
                throw LibraryExportError.unsafePath(t.path)
            }
            if fm.fileExists(atPath: target.path) {
                plan.skipped += 1
            } else {
                guard let size = Self.size(of: source) else {
                    throw LibraryExportError.missingSource(t.path)
                }
                plan.files.append((t.path, size))
            }
            let dir = (t.path as NSString).deletingLastPathComponent
            guard seenDirs.insert(dir).inserted else { continue }
            let cover = (dir as NSString).appendingPathComponent("cover.jpg")
            if let source = LibraryPath.resolve(cover, in: libraryRoot), let target = LibraryPath.resolve(cover, in: destination),
               !fm.fileExists(atPath: target.path), let size = Self.size(of: source) {
                plan.covers.append((cover, size))
            }
        }
        if artistImages {
            let dir = Self.artistImageFolder
            let names = (try? fm.contentsOfDirectory(atPath: libraryRoot.appendingPathComponent(dir).path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let source = LibraryPath.resolve(path, in: libraryRoot), let target = LibraryPath.resolve(path, in: destination),
                      let size = Self.size(of: source), Self.size(of: target) != size else { continue }
                plan.artistImages.append((path, size))
            }
        }
        for path in Set(collectionCovers).sorted() where SyncPlan.isCollectionCover(path) {
            guard let source = LibraryPath.resolve(path, in: libraryRoot), let target = LibraryPath.resolve(path, in: destination),
                  !fm.fileExists(atPath: target.path), let size = Self.size(of: source) else { continue }
            plan.collectionCovers.append((path, size))
        }
        return plan
    }

    /// Copies `tracks` (and their album covers) into `destination`, writes `playlists` as .m3u files and, when
    /// `database` is given, replaces `<destination>/library.sqlite` with a fresh snapshot of it, brings
    /// `Artist Images` up to date and adds the collection's own covers, so the destination works as a complete
    /// library without re-downloading.
    /// Checks for cancellation between files; a cancelled export leaves only complete files behind.
    @discardableResult
    public func export(
        tracks: [Track], playlists: [ExportPlaylist] = [], database: Database? = nil,
        libraryRoot: URL, to destination: URL,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> LibraryExportSummary {
        let fm = FileManager.default
        let plan = try plan(tracks: tracks, libraryRoot: libraryRoot, destination: destination, artistImages: database != nil,
                            collectionCovers: try database?.collectionCoverPaths() ?? [])
        if let available = Self.availableCapacity(at: destination), plan.bytesNeeded > available {
            throw LibraryExportError.insufficientSpace(needed: plan.bytesNeeded, available: available)
        }
        var summary = LibraryExportSummary()
        summary.skipped = plan.skipped
        let total = plan.files.count + plan.covers.count + plan.artistImages.count + plan.collectionCovers.count + (database == nil ? 0 : 1)
        var done = 0
        progress(0, total)
        enum Kind { case track, cover, artistImage, collectionCover }
        let work = plan.files.map { (Kind.track, $0) } + plan.covers.map { (Kind.cover, $0) } + plan.artistImages.map { (Kind.artistImage, $0) }
            + plan.collectionCovers.map { (Kind.collectionCover, $0) }
        for (kind, file) in work {
            try Task.checkCancellation()
            // Artist photos are replaced when they change; music and covers never are.
            guard let source = LibraryPath.resolve(file.path, in: libraryRoot), let target = LibraryPath.resolve(file.path, in: destination) else {
                throw LibraryExportError.unsafePath(file.path)
            }
            try Self.copy(source, to: target, label: file.path, replacing: kind == .artistImage)
            switch kind {
            case .track: summary.copied += 1; summary.bytesCopied += file.size
            case .cover: summary.covers += 1
            case .artistImage: summary.artistImages += 1
            case .collectionCover: summary.collectionCovers += 1
            }
            done += 1
            progress(done, total)
        }

        let named = playlists.filter { !$0.tracks.isEmpty }
        if !named.isEmpty {
            let folder = destination.appendingPathComponent(Self.playlistFolder, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var used = Set<String>()
            for p in named {
                let base = Organizer.sanitize(p.name, maxBytes: Organizer.maxComponentBytes - 8)
                var name = base.isEmpty ? "Playlist" : base, n = 2
                while !used.insert(name.lowercased()).inserted { name = "\(base) (\(n))"; n += 1 }
                try Self.m3u(p.tracks).write(to: folder.appendingPathComponent("\(name).m3u"), atomically: true, encoding: .utf8)
                summary.playlists += 1
            }
        }

        if let database {
            try Task.checkCancellation()
            try Self.backUp(database, to: LibraryLocation.databaseURL(root: destination))
            summary.databaseBackedUp = true
            done += 1
            progress(done, total)
        }
        return summary
    }

    /// An extended M3U for a file in `Playlists/`, pointing at the exported music.
    static func m3u(_ tracks: [Track]) -> String {
        PlaylistExporter.m3uContents(entries: tracks.map { t in
            let title = t.title.isEmpty ? ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension : t.title
            return ("../" + t.path, t.artist.isEmpty ? "Unknown Artist" : t.artist, title, t.duration)
        })
    }

    /// Writes a consistent snapshot (including anything still in the WAL) next to `target`, then swaps it in.
    static func backUp(_ database: Database, to target: URL) throws {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent("." + target.lastPathComponent + partialSuffix)
        try? fm.removeItem(at: partial)
        do {
            try database.vacuum(into: partial.path)
            // A WAL or shared-memory file left by a program that opened the old copy must not be applied to the new one.
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: target.path + suffix) }
            try Self.moveIntoPlace(partial, target, replacing: true)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Copies file data only: extended attributes would become `._` files on FAT/exFAT drives, which players
    /// list as broken tracks. The copy is made under a hidden name and renamed, so an interrupted export
    /// never leaves a truncated file that a later export would skip.
    static func copy(_ source: URL, to target: URL, label: String, replacing: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + partialSuffix)
        try? fm.removeItem(at: partial)
        guard copyfile(source.path, partial.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            let code = errno
            try? fm.removeItem(at: partial)
            throw LibraryExportError.copyFailed(path: label, code: code)
        }
        do {
            try moveIntoPlace(partial, target, replacing: replacing)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private static func moveIntoPlace(_ partial: URL, _ target: URL, replacing: Bool) throws {
        if replacing {
            // rename(2) replaces atomically on every file system macOS writes, including FAT and exFAT.
            guard rename(partial.path, target.path) == 0 else { throw LibraryExportError.copyFailed(path: target.lastPathComponent, code: errno) }
        } else {
            // Fails rather than overwrite if something appeared at the target meanwhile.
            try FileManager.default.moveItem(at: partial, to: target)
        }
    }

    public static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }
}

/// What an export destination already holds and what exporting would add to it, album folder by album folder.
public struct ExportPreview: Sendable {
    public struct Folder: Identifiable, Sendable, Equatable {
        public var id: String { path }
        /// Destination-relative folder, e.g. "Music/Artist/Album (1997)".
        public var path: String
        public var artist: String
        public var album: String
        public var existingFiles = 0
        public var existingBytes: Int64 = 0
        public var incomingFiles = 0
        public var incomingBytes: Int64 = 0
        public var hasCover = false
        public var incomingCover = false
        /// Not at the destination yet; the export creates it.
        public var isNew: Bool { existingFiles == 0 }
    }

    public struct DatabaseCopy: Sendable, Equatable {
        public var size: Int64
        public var modified: Date?
    }

    /// False when the folder doesn't exist (e.g. the drive isn't connected); everything else is then empty.
    public var isAvailable = false
    /// Album folders at the destination or about to be, sorted by artist then album.
    public var folders: [Folder] = []
    public var plan = LibraryExporter.Plan()
    /// Library-relative paths of the tracks the export would copy, with their sizes.
    public var incoming: [String: Int64] = [:]
    /// Names of the .m3u files in the destination's Playlists folder.
    public var playlists: [String] = []
    public var database: DatabaseCopy?
    /// Artist photos already at the destination.
    public var artistImageCount = 0
    public var availableCapacity: Int64?

    public var existingFiles: Int { folders.reduce(0) { $0 + $1.existingFiles } }
    public var existingAlbums: Int { folders.filter { !$0.isNew }.count }

    public init() {}

    /// `collectionCovers` (with the database backup) are counted in the plan, never listed as album folders.
    public static func make(tracks: [Track], libraryRoot: URL, destination: URL, artistImages: Bool = false,
                            collectionCovers: [String] = []) throws -> ExportPreview {
        var preview = ExportPreview()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else { return preview }
        preview.isAvailable = true
        preview.availableCapacity = LibraryExporter.availableCapacity(at: destination)
        preview.plan = try LibraryExporter().plan(tracks: tracks, libraryRoot: libraryRoot, destination: destination,
                                                  artistImages: artistImages, collectionCovers: collectionCovers)
        preview.incoming = Dictionary(preview.plan.files.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })

        let fm = FileManager.default
        var folders: [String: Folder] = [:]
        func folder(_ dir: String) -> Folder {
            if let f = folders[key(dir)] { return f }
            let parts = dir.split(separator: "/").dropFirst().map(String.init)  // drop "Music"
            return Folder(path: dir, artist: parts.first ?? "", album: parts.dropFirst().joined(separator: "/"))
        }
        for (dir, size) in audioFiles(in: destination) {
            var f = folder(dir)
            f.existingFiles += 1; f.existingBytes += size
            folders[key(dir)] = f
        }
        for file in preview.plan.files {
            let dir = (file.path as NSString).deletingLastPathComponent
            var f = folder(dir)
            f.incomingFiles += 1; f.incomingBytes += file.size
            folders[key(dir)] = f
        }
        for cover in preview.plan.covers {
            let dir = (cover.path as NSString).deletingLastPathComponent
            var f = folder(dir)
            f.incomingCover = true
            folders[key(dir)] = f
        }
        for (k, f) in folders where !f.isNew {
            folders[k]?.hasCover = fm.fileExists(atPath: destination.appendingPathComponent(f.path).appendingPathComponent("cover.jpg").path)
        }
        preview.folders = folders.values.sorted {
            let a = $0.artist.localizedStandardCompare($1.artist)
            return a != .orderedSame ? a == .orderedAscending : $0.album.localizedStandardCompare($1.album) == .orderedAscending
        }

        let playlistDir = destination.appendingPathComponent(LibraryExporter.playlistFolder)
        preview.playlists = ((try? fm.contentsOfDirectory(atPath: playlistDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".m3u") && !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let db = LibraryLocation.databaseURL(root: destination)
        if let attrs = try? fm.attributesOfItem(atPath: db.path) {
            preview.database = DatabaseCopy(size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date)
        }
        let images = destination.appendingPathComponent(LibraryExporter.artistImageFolder)
        preview.artistImageCount = ((try? fm.contentsOfDirectory(atPath: images.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        return preview
    }

    /// File systems differ in Unicode normalization (and FAT/APFS ignore case), so folders are matched loosely.
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// Audio files under `<destination>/Music`, as (destination-relative folder, size).
    private static func audioFiles(in destination: URL) -> [(String, Int64)] {
        let music = destination.appendingPathComponent("Music")
        guard let e = FileManager.default.enumerator(atPath: music.path) else { return [] }
        var out: [(String, Int64)] = []
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") {
                if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { e.skipDescendants() }
                continue
            }
            guard e.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let dir = ("Music/" + rel as NSString).deletingLastPathComponent
            out.append((dir, (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return out
    }
}
