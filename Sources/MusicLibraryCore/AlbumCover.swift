import Foundation

extension TagWriter {
    static func embedCoverArguments(file: URL, coverPath: String, output: URL, ext: String) -> [String] {
        var args = ["-nostdin", "-v", "error", "-y", "-i", file.path, "-i", coverPath,
                    "-map", "0:a", "-map", "1:v", "-map_metadata", "0", "-c", "copy",
                    "-disposition:v:0", "attached_pic", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args.append(output.path)
        return args
    }

    /// Replaces the embedded front cover of a library file with `cover` (JPEG), keeping its audio and tags. Written to a
    /// hidden temp file next to it, then swapped in, so a failure leaves the file as it was.
    public func replaceEmbeddedCover(in file: URL, cover: Data) async throws {
        let ext = file.pathExtension.lowercased()
        guard tagWritableExtensions.contains(ext) else {
            throw ToolError.failed(tool: "TagWriter", status: 0, stderr: "cover embedding unsupported for .\(ext)")
        }
        let ffmpeg = try tools.require("ffmpeg")
        let token = UUID().uuidString
        let temp = file.deletingLastPathComponent().appendingPathComponent(".tmp-\(token).\(ext)")
        let coverFile = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(token).jpg")
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: coverFile)
        }
        try cover.write(to: coverFile)
        _ = try await ProcessRunner.run(ffmpeg, Self.embedCoverArguments(file: file, coverPath: coverFile.path, output: temp, ext: ext))
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }
}

/// Gives an album a new cover: its folders' `cover.jpg` (what the app shows) and, optionally, the art embedded in its
/// mp3, flac and m4a files (what other players and exported copies show). Paths go through `LibraryPath`, so tracks
/// whose stored path leads outside the library are skipped.
public struct AlbumCoverWriter: Sendable {
    public struct Result: Sendable {
        public var embedded = 0
        /// File names and what went wrong, for files that kept their old art.
        public var failures: [(file: String, message: String)] = []
    }

    public let root: URL
    public let tools: ToolLocator

    public init(root: URL, tools: ToolLocator = ToolLocator()) { self.root = root; self.tools = tools }

    /// The tracks whose files can have art embedded.
    public static func embeddable(_ tracks: [Track]) -> [Track] {
        tracks.filter { tagWritableExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
    }

    /// `progress` is called with (files done, files to do) as embedding goes along.
    public func apply(_ jpeg: Data, to tracks: [Track], embed: Bool,
                      progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        guard ImageTools.isJPEG(jpeg) else { throw ToolError.failed(tool: "AlbumCoverWriter", status: 0, stderr: "the cover is not a JPEG image") }
        var covers: [String: URL] = [:]
        for t in tracks {
            guard let url = t.coverURL(root: root) else { continue }
            covers[url.path] = url
        }
        guard !covers.isEmpty else { throw ToolError.failed(tool: "AlbumCoverWriter", status: 0, stderr: "no album folder inside the library") }
        for url in covers.values { try jpeg.write(to: url, options: .atomic) }

        var result = Result()
        guard embed else { return result }
        let files = Self.embeddable(tracks)
        let writer = TagWriter(tools: tools)
        for (i, t) in files.enumerated() {
            try Task.checkCancellation()
            progress(i, files.count)
            guard let url = t.resolvedFileURL(root: root) else {
                result.failures.append(((t.path as NSString).lastPathComponent, "outside the library folder"))
                continue
            }
            do {
                try await writer.replaceEmbeddedCover(in: url, cover: jpeg)
                result.embedded += 1
            } catch {
                result.failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        progress(files.count, files.count)
        return result
    }
}
