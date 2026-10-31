import Darwin
import Foundation

// MARK: Planning (Mac)

/// What a sync sends to the phone and removes from it, from the selection's tracks and the phone's manifest.
/// The phone mirrors the selection: files it has under the managed folders that aren't wanted are deleted, and a
/// wanted file whose size differs (retagged, a new cover) is sent again. Every album's cover, every collection
/// item's own cover and every artist photo go too, so the whole library and collection can be browsed on the phone.
public struct SyncPlan: Equatable, Sendable {
    /// Paths relative to the library root, in send order: tracks (with their album covers), the other albums'
    /// covers, collection covers, then artist photos.
    public var sends: [SyncFileEntry] = []
    public var deletes: [String] = []
    /// Selected tracks whose files are missing from the Mac's library; they're skipped.
    public var missing = 0

    public var bytes: Int64 { sends.reduce(0) { $0 + $1.size } }
    public var summary: SyncPlanSummary { SyncPlanSummary(files: sends.count, bytes: bytes, deletes: deletes.count) }

    /// `library` is every track in the library, for the covers; `collectionCovers` the items' own covers
    /// (`Database.collectionCoverPaths`), wanted whatever the selection is. Only those in `CollectionCovers.folder`
    /// with an allowed name are used.
    public init(tracks: [Track], library: [Track] = [], collectionCovers: [String] = [], libraryRoot: URL, phone: [SyncFileEntry]) {
        var onPhone: [String: Int64] = [:]
        // The manifest comes from the phone: entries that aren't plain paths inside the managed folders are ignored.
        for entry in phone where SyncPlan.isManaged(entry.path) { onPhone[entry.path] = entry.size }
        var wanted = Set<String>()

        func want(_ path: String, size: Int64) {
            guard wanted.insert(path).inserted else { return }
            if onPhone[path] != size { sends.append(SyncFileEntry(path: path, size: size)) }
        }
        func sourceSize(_ path: String) -> Int64? {
            LibraryPath.resolve(path, in: libraryRoot).flatMap(LibraryExporter.size(of:))
        }

        var seenDirs = Set<String>()
        func wantCover(of t: Track) {
            let dir = (t.path as NSString).deletingLastPathComponent
            guard seenDirs.insert(dir).inserted else { return }
            let cover = (dir as NSString).appendingPathComponent("cover.jpg")
            if SyncPlan.isManaged(cover), let size = sourceSize(cover) { want(cover, size: size) }
        }
        for t in tracks where !wanted.contains(t.path) {
            guard SyncPlan.isManaged(t.path), let size = sourceSize(t.path) else {
                missing += 1
                continue
            }
            want(t.path, size: size)
            wantCover(of: t)
        }
        for t in library { wantCover(of: t) }
        for path in collectionCovers.sorted() where SyncPlan.isCollectionCover(path) {
            if let size = sourceSize(path) { want(path, size: size) }
        }
        let images = LibraryExporter.artistImageFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: libraryRoot.appendingPathComponent(images).path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = (images as NSString).appendingPathComponent(name)
            if let size = sourceSize(path) { want(path, size: size) }
        }
        deletes = onPhone.keys.filter { !wanted.contains($0) }.sorted()
    }

    /// "Music/Collection Covers/<allowed name>".
    static func isCollectionCover(_ path: String) -> Bool {
        let prefix = CollectionCovers.folder + "/"
        return path.hasPrefix(prefix) && CollectionCovers.isFileName(String(path.dropFirst(prefix.count))) && isManaged(path)
    }

    /// A plain relative path inside one of the folders sync manages.
    static func isManaged(_ path: String) -> Bool {
        guard LibraryPath.isPlainRelative(path), let first = path.split(separator: "/").first, path.contains("/") else { return false }
        return SyncProtocol.managedFolders.contains(String(first))
    }
}

extension Database {
    /// A compact copy of the library database for the phone, without the downloaded library catalog (Mac only,
    /// and often the biggest part). `scratch` is a folder for the intermediate copy.
    public func writeSyncSnapshot(to target: URL, scratch: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let full = scratch.appendingPathComponent("sync-full-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: full.path + suffix) } }
        try vacuum(into: full.path)
        do {
            let copy = try Database(path: full.path)
            for table in ["catalog_items", "catalog_info", "catalog_previews", "discogs_sync"] { try copy.exec("DELETE FROM \(table)") }
            try? fm.removeItem(at: target)
            try copy.vacuum(into: target.path)
        }
    }
}

// MARK: Receiving (phone)

/// Applies a sync to the phone's library folder. Every path comes from the network, so each is checked to be a
/// plain path inside a managed folder (or the database) and resolved inside the root (`LibraryPath.resolve`, which
/// also refuses symlinks leading out) before anything is written or removed. Files are written under a hidden
/// partial name and renamed into place, so an interrupted sync leaves only complete files behind.
public final class SyncReceiver {
    public let root: URL
    private var current: (header: SyncFileHeader, target: URL, partial: URL, handle: FileHandle, written: Int64)?
    public private(set) var summary = SyncSummary()

    static let partialSuffix = ".mlsync"

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        removeLeftoverPartials()
    }

    /// Every file in the managed folders, with its size (hidden files, partial ones included, aren't listed).
    public func manifest() -> [SyncFileEntry] {
        var entries: [SyncFileEntry] = []
        let rootPath = root.standardizedFileURL.path
        for folder in SyncProtocol.managedFolders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                entries.append(SyncFileEntry(path: String(path.dropFirst(rootPath.count + 1)), size: Int64(size)))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Removes files that are no longer in the selection, and folders left empty.
    public func delete(_ paths: [String]) throws {
        let fm = FileManager.default
        for path in paths {
            guard SyncPlan.isManaged(path), let url = LibraryPath.resolve(path, in: root) else { throw SyncError.unsafePath(path) }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try fm.removeItem(at: url)
            summary.deleted += 1
            // Up to (not including) the managed folder itself.
            var dir = url.deletingLastPathComponent()
            while dir.pathComponents.count > root.pathComponents.count + 1,
                  (try? fm.contentsOfDirectory(atPath: dir.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
    }

    /// Starts a file announced by `.file`. Returns true when it's already complete (an empty file).
    public func begin(_ header: SyncFileHeader) throws -> Bool {
        cancel()
        let isDatabase = header.path == Self.databaseName
        guard isDatabase || SyncPlan.isManaged(header.path), header.size >= 0,
              let target = LibraryPath.resolve(header.path, in: root) else { throw SyncError.unsafePath(header.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created only after the folder exists, so it can be resolved (and checked) once more.
        guard LibraryPath.resolve(header.path, in: root) != nil else { throw SyncError.unsafePath(header.path) }
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + Self.partialSuffix)
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        current = (header, target, partial, try FileHandle(forWritingTo: partial), 0)
        if header.size == 0 { try finish(); return true }
        return false
    }

    /// Writes the next chunk of the current file. Returns true when the file is complete and in place.
    public func write(_ chunk: Data) throws -> Bool {
        guard var c = current else { throw SyncError.unexpected("file data without a file") }
        guard c.written + Int64(chunk.count) <= c.header.size else { throw SyncError.unexpected("more data than \(c.header.path)'s size") }
        try c.handle.write(contentsOf: chunk)
        c.written += Int64(chunk.count)
        current = c
        if c.written == c.header.size { try finish(); return true }
        return false
    }

    /// Drops a file that didn't arrive completely.
    public func cancel() {
        guard let c = current else { return }
        try? c.handle.close()
        try? FileManager.default.removeItem(at: c.partial)
        current = nil
    }

    private func finish() throws {
        guard let c = current else { return }
        current = nil
        try c.handle.close()
        if c.header.path == Self.databaseName {
            // A WAL or shared-memory file from the old copy must not be applied to the new one.
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: c.target.path + suffix) }
            summary.databaseUpdated = true
        } else {
            summary.copied += 1
            summary.bytes += c.header.size
        }
        guard rename(c.partial.path, c.target.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: c.partial)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't save \(c.target.lastPathComponent): \(String(cString: strerror(code)))"])
        }
    }

    private func removeLeftoverPartials() {
        let fm = FileManager.default
        var partials = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        for folder in SyncProtocol.managedFolders {
            guard let e = fm.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            partials += e.compactMap { $0 as? URL }
        }
        for url in partials where url.lastPathComponent.hasSuffix(Self.partialSuffix) { try? fm.removeItem(at: url) }
    }

    public static let databaseName = "library.sqlite"
}
