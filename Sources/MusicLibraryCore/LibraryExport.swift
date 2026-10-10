import Darwin
import Foundation

public enum LibraryExportError: Error, LocalizedError {
    case insufficientSpace(needed: Int64, available: Int64)
    case missingSource(String)
    case copyFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough space at the destination: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: available)) available."
        case .missingSource(let p): return "File missing from the library: \(p)"
        case .copyFailed(let p, let code): return "Could not copy \(p): \(String(cString: strerror(code)))"
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
    static let partialSuffix = ".mlpart"

    public init() {}

    public struct Plan: Sendable {
        /// Library-relative paths to copy, in order, with their sizes.
        public var files: [(path: String, size: Int64)] = []
        /// Album covers the destination is missing.
        public var covers: [(path: String, size: Int64)] = []
        public var skipped = 0
        public var bytesNeeded: Int64 { (files + covers).reduce(0) { $0 + $1.size } }
    }

    /// What `export` would copy: tracks (deduplicated, in order) and album covers not yet at the destination.
    public func plan(tracks: [Track], libraryRoot: URL, destination: URL) throws -> Plan {
        let fm = FileManager.default
        var plan = Plan()
        var seenTracks = Set<String>(), seenDirs = Set<String>()
        for t in tracks where seenTracks.insert(t.path).inserted {
            if fm.fileExists(atPath: destination.appendingPathComponent(t.path).path) {
                plan.skipped += 1
            } else {
                guard let size = Self.size(of: libraryRoot.appendingPathComponent(t.path)) else {
                    throw LibraryExportError.missingSource(t.path)
                }
                plan.files.append((t.path, size))
            }
            let dir = (t.path as NSString).deletingLastPathComponent
            guard seenDirs.insert(dir).inserted else { continue }
            let cover = (dir as NSString).appendingPathComponent("cover.jpg")
            if !fm.fileExists(atPath: destination.appendingPathComponent(cover).path),
               let size = Self.size(of: libraryRoot.appendingPathComponent(cover)) {
                plan.covers.append((cover, size))
            }
        }
        return plan
    }

    /// Copies `tracks` (and their album covers) into `destination`, writes `playlists` as .m3u files and, when
    /// `database` is given, replaces `<destination>/library.sqlite` with a fresh snapshot of it.
    /// Checks for cancellation between files; a cancelled export leaves only complete files behind.
    @discardableResult
    public func export(
        tracks: [Track], playlists: [ExportPlaylist] = [], database: Database? = nil,
        libraryRoot: URL, to destination: URL,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> LibraryExportSummary {
        let fm = FileManager.default
        let plan = try plan(tracks: tracks, libraryRoot: libraryRoot, destination: destination)
        if let available = Self.availableCapacity(at: destination), plan.bytesNeeded > available {
            throw LibraryExportError.insufficientSpace(needed: plan.bytesNeeded, available: available)
        }
        var summary = LibraryExportSummary()
        summary.skipped = plan.skipped
        let total = plan.files.count + plan.covers.count + (database == nil ? 0 : 1)
        var done = 0
        progress(0, total)
        for (isCover, file) in plan.files.map({ (false, $0) }) + plan.covers.map({ (true, $0) }) {
            try Task.checkCancellation()
            try Self.copy(libraryRoot.appendingPathComponent(file.path), to: destination.appendingPathComponent(file.path), label: file.path)
            if isCover { summary.covers += 1 } else { summary.copied += 1; summary.bytesCopied += file.size }
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
    static func copy(_ source: URL, to target: URL, label: String) throws {
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
            try moveIntoPlace(partial, target, replacing: false)
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

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
    }
}
