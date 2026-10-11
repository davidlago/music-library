import CryptoKit
import Foundation

public enum LibraryLocation {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MusicLibrary", isDirectory: true)
    }
    public static func databaseURL(root: URL) -> URL { root.appendingPathComponent("library.sqlite") }

    public static func openDatabase(root: URL) throws -> Database {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try Database(path: databaseURL(root: root).path)
    }
}

public enum ImportError: Error, LocalizedError {
    case duplicate(existingPath: String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let p): return "Already in library (\(p))"
        case .unsupported(let e): return "Unsupported file type: .\(e)"
        }
    }
}

public struct ImportItem: Sendable {
    public var sourceURL: URL
    public var sha256: String
    public var tags: TrackMetadata
    public var duration: Double
    public var format: String
    public var embeddedCover: Data?
    public var duplicateOf: Track?
    public var audioFormat: AudioFormat?
}

public struct ImportService: Sendable {
    public let root: URL
    public let database: Database
    public let tools: ToolLocator

    public init(root: URL, database: Database, tools: ToolLocator = ToolLocator()) {
        self.root = root; self.database = database; self.tools = tools
    }

    public static func discover(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var inDir: [URL] = []
                for case let f as URL in e where supportedExtensions.contains(f.pathExtension.lowercased()) {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { inDir.append(f) }
                }
                found += inDir.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func prepare(_ url: URL) async throws -> ImportItem {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupported(ext) }
        let sha = try Self.sha256(of: url)
        let reader = TagReader(tools: tools)
        let info = try await reader.read(url)
        let cover = info.hasEmbeddedCover ? try await reader.extractCover(url, info: info) : nil
        return ImportItem(
            sourceURL: url, sha256: sha, tags: info.metadata, duration: info.duration, format: ext,
            embeddedCover: cover, duplicateOf: try database.trackBySha256(sha), audioFormat: info.audio)
    }

    public func commit(_ item: ImportItem, metadata: TrackMetadata, cover: Data?) async throws -> Track {
        if let dup = try database.trackBySha256(item.sha256) { throw ImportError.duplicate(existingPath: dup.path) }
        let fm = FileManager.default
        let ext = item.sourceURL.pathExtension.lowercased()
        let stem = item.sourceURL.deletingPathExtension().lastPathComponent
        let relative = Organizer.uniquePath(Organizer.relativePath(for: metadata, sourceStem: stem, ext: ext)) {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        let destination = root.appendingPathComponent(relative)
        let albumDir = destination.deletingLastPathComponent()
        var createdFiles: [URL] = []
        do {
            try fm.createDirectory(at: albumDir, withIntermediateDirectories: true)
            let jpegCover: Data? = try await cover.asyncMap { try await ImageTools.jpegData(from: $0, tools: tools) }
            if tagWritableExtensions.contains(ext) {
                try await TagWriter(tools: tools).writeTaggedCopy(
                    source: item.sourceURL, destination: destination, metadata: metadata, cover: jpegCover)
            } else {
                try fm.copyItem(at: item.sourceURL, to: destination)
            }
            createdFiles.append(destination)

            let coverURL = albumDir.appendingPathComponent("cover.jpg")
            if !fm.fileExists(atPath: coverURL.path) {
                var data = jpegCover
                if data == nil, let embedded = item.embeddedCover {
                    data = try await ImageTools.jpegData(from: embedded, tools: tools)
                }
                if let data {
                    try data.write(to: coverURL)
                    createdFiles.append(coverURL)
                }
            }
            let track = Track(path: relative, metadata: metadata, duration: item.duration, format: ext, sha256: item.sha256, audioFormat: item.audioFormat)
            return try database.insertTrack(track)
        } catch {
            for f in createdFiles { try? fm.removeItem(at: f) }
            for dir in [albumDir, albumDir.deletingLastPathComponent()] {
                if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
            throw error
        }
    }
}

extension Optional where Wrapped: Sendable {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let v): return try await transform(v)
        case .none: return nil
        }
    }
}

public struct PlaylistExporter: Sendable {
    public init() {}

    /// Tag text and paths can contain line breaks, which would start new playlist entries: in the `#EXTINF`
    /// text they become spaces, in the file line they are percent-encoded.
    public static func m3uContents(entries: [(file: String, artist: String, title: String, duration: Double)]) -> String {
        var s = "#EXTM3U\n"
        for e in entries {
            let info = m3uSafe("\(e.artist) - \(e.title)") { _ in " " }
            let file = m3uSafe(e.file) { scalar in
                String(scalar).utf8.map { "%" + ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: true) }.joined()
            }
            s += "#EXTINF:\(Int(e.duration.rounded())),\(info)\n\(file)\n"
        }
        return s
    }

    private static func m3uSafe(_ text: String, replacing: (Unicode.Scalar) -> String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" {
                out += replacing(scalar)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Returns the playlist folder. Existing files with the same size are not recopied; nothing is deleted.
    @discardableResult
    public func export(
        name: String, tracks: [Track], libraryRoot: URL, to destination: URL,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> URL {
        let fm = FileManager.default
        let folderName = Organizer.sanitize(name)
        let folder = destination.appendingPathComponent(folderName.isEmpty ? "Playlist" : folderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = max(2, String(tracks.count).count)
        var entries: [(file: String, artist: String, title: String, duration: Double)] = []
        progress(0, tracks.count)
        for (i, t) in tracks.enumerated() {
            guard let src = t.resolvedFileURL(root: libraryRoot) else { throw LibraryExportError.unsafePath(t.path) }
            let ext = (t.path as NSString).pathExtension
            let artist = t.artist.isEmpty ? "Unknown Artist" : t.artist
            let title = t.title.isEmpty ? ((t.path as NSString).lastPathComponent as NSString).deletingPathExtension : t.title
            let nn = String(format: "%0\(width)d", i + 1)
            let stem = Organizer.sanitize("\(nn) - \(artist) - \(title)", maxBytes: Organizer.maxComponentBytes - ext.utf8.count - 1)
            let fileName = "\(stem).\(ext)"
            let dst = folder.appendingPathComponent(fileName)
            let srcSize = (try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? -1
            let dstSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value
            if dstSize != srcSize {
                if dstSize != nil { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            entries.append((fileName, artist, title, t.duration))
            progress(i + 1, tracks.count)
        }
        let m3u = folder.appendingPathComponent("\(folder.lastPathComponent).m3u")
        try Self.m3uContents(entries: entries).write(to: m3u, atomically: true, encoding: .utf8)
        return folder
    }
}
