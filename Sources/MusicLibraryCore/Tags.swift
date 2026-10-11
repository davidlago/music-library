import Foundation

public struct TagInfo: Sendable {
    public var metadata: TrackMetadata
    public var duration: Double
    public var format: String
    public var hasEmbeddedCover: Bool
    public var audio: AudioFormat?
    fileprivate var coverStreamIndex: Int?
}

public struct TagReader: Sendable {
    public let tools: ToolLocator
    public init(tools: ToolLocator = ToolLocator()) { self.tools = tools }

    public func read(_ url: URL) async throws -> TagInfo {
        let ffprobe = try tools.require("ffprobe")
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        var info = try Self.parse(probeJSON: result.stdout)
        info.format = url.pathExtension.lowercased()
        return info
    }

    public func extractCover(_ url: URL, info: TagInfo) async throws -> Data? {
        guard let index = info.coverStreamIndex else { return nil }
        let ffmpeg = try tools.require("ffmpeg")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-nostdin", "-v", "error", "-i", url.path, "-map", "0:\(index)", "-c", "copy",
            "-f", "image2pipe", "pipe:1",
        ], checkStatus: false)
        return result.status == 0 && !result.stdout.isEmpty ? result.stdout : nil
    }

    static func parseNumberPair(_ s: String?) -> (Int?, Int?) {
        guard let s else { return (nil, nil) }
        let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let n = parts.first.flatMap { Int($0) }
        let t = parts.count > 1 ? Int(parts[1]) : nil
        return (n, t)
    }

    static func audioFormat(streams: [[String: Any]], format: [String: Any]) -> AudioFormat? {
        guard let s = streams.first(where: { ($0["codec_type"] as? String) == "audio" }),
              let codec = s["codec_name"] as? String else { return nil }
        func int(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let str = v as? String { return Int(str) }
            return nil
        }
        var bits: Int?
        if !AudioFormat.lossyCodecs.contains(codec.lowercased()) {
            if let raw = int(s["bits_per_raw_sample"]), raw > 0 { bits = raw }
            else if let b = int(s["bits_per_sample"]), b > 0 { bits = b }
        }
        let bitrate = int(s["bit_rate"]) ?? int(format["bit_rate"])
        return AudioFormat(codec: codec, sampleRate: int(s["sample_rate"]), bitDepth: bits,
                           bitrate: bitrate.flatMap { $0 > 0 ? $0 : nil }, channels: int(s["channels"]))
    }

    public static func parse(probeJSON data: Data) throws -> TagInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.failed(tool: "ffprobe", status: 0, stderr: "unexpected JSON")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []

        var tags: [String: String] = [:]
        func merge(_ raw: Any?) {
            guard let dict = raw as? [String: Any] else { return }
            for (k, v) in dict {
                guard let s = v as? String else { continue }
                for key in [k.lowercased(), k.lowercased().replacingOccurrences(of: " ", with: "_")] where tags[key] == nil {
                    tags[key] = s
                }
            }
        }
        merge(format["tags"])
        for s in streams where (s["codec_type"] as? String) == "audio" { merge(s["tags"]) }

        func tag(_ keys: String...) -> String? {
            for k in keys { if let v = tags[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v } }
            return nil
        }

        var m = TrackMetadata()
        m.title = tag("title") ?? ""
        m.artist = tag("artist") ?? ""
        m.album = tag("album") ?? ""
        m.albumArtist = tag("album_artist", "albumartist") ?? ""
        m.genre = tag("genre") ?? ""
        if let date = tag("date", "year", "originaldate") {
            m.year = Int(date.prefix(4))
        }
        let (tn, tt) = parseNumberPair(tag("track", "tracknumber"))
        m.trackNo = tn
        m.trackTotal = tt ?? tag("tracktotal", "totaltracks").flatMap { Int($0) }
        let (dn, dt) = parseNumberPair(tag("disc", "discnumber"))
        m.discNo = dn
        m.discTotal = dt ?? tag("disctotal", "totaldiscs").flatMap { Int($0) }
        m.mbRecordingId = tag("musicbrainz_trackid")
        m.mbReleaseId = tag("musicbrainz_albumid")
        m.composer = tag("composer") ?? ""
        let isID3 = (format["format_name"] as? String)?.contains("mp3") == true
        func list(_ keys: String...) -> [String] {
            for k in keys {
                if let v = tags[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    return v.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            }
            return []
        }
        var e = ExtendedMetadata()
        e.lyricist = tag("lyricist", "text") ?? ""
        e.writer = tag("writer") ?? ""
        e.arranger = tag("arranger") ?? ""
        e.conductor = tag("conductor") ?? (isID3 ? tag("performer") ?? "" : "")
        e.producer = tag("producer") ?? ""
        e.engineer = tag("engineer") ?? ""
        e.mixer = tag("mixer") ?? ""
        e.remixer = tag("remixer", "tpe4") ?? ""
        e.label = tag("label", "publisher", "organization") ?? ""
        e.catalogNumber = tag("catalognumber") ?? ""
        e.barcode = tag("barcode") ?? ""
        e.asin = tag("asin") ?? ""
        e.releaseCountry = tag("releasecountry", "musicbrainz_album_release_country") ?? ""
        e.releaseStatus = tag("releasestatus", "musicbrainz_album_status") ?? ""
        let types = list("releasetype", "musicbrainz_album_type")
        e.releaseType = types.first ?? ""
        e.releaseSecondaryTypes = Array(types.dropFirst())
        e.language = tag("language").flatMap { $0 == "und" ? nil : $0 } ?? ""
        e.script = tag("script") ?? ""
        e.originalDate = tag("originaldate", "tdor", "tory", "originalyear") ?? ""
        e.mediaFormat = tag("media", "tmed") ?? ""
        e.discSubtitle = tag("discsubtitle", "disc_subtitle", "tsst") ?? ""
        e.artistSort = tag("artistsort", "artist-sort", "sort_artist", "tsop") ?? ""
        e.albumArtistSort = tag("albumartistsort", "sort_album_artist", "album_artist-sort", "album-artist-sort") ?? ""
        e.workTitle = tag("work") ?? ""
        e.isrcs = list("isrc", "tsrc")
        e.performers = list("performers") + (isID3 ? [] : list("performer"))
        e.mbReleaseGroupId = tag("musicbrainz_releasegroupid", "musicbrainz_release_group_id") ?? ""
        e.mbReleaseTrackId = tag("musicbrainz_releasetrackid", "musicbrainz_release_track_id") ?? ""
        e.mbArtistIds = list("musicbrainz_artistid", "musicbrainz_artist_id")
        e.mbAlbumArtistIds = list("musicbrainz_albumartistid", "musicbrainz_album_artist_id")
        e.mbWorkIds = list("musicbrainz_workid", "musicbrainz_work_id")
        m.extended = e
        m.validateMBIDs()

        let duration = (format["duration"] as? String).flatMap(Double.init) ?? 0
        var coverIndex: Int?
        for s in streams {
            let disposition = s["disposition"] as? [String: Any]
            if (disposition?["attached_pic"] as? Int) == 1, let idx = s["index"] as? Int {
                coverIndex = idx
                break
            }
        }
        return TagInfo(metadata: m, duration: duration, format: "", hasEmbeddedCover: coverIndex != nil, audio: audioFormat(streams: streams, format: format), coverStreamIndex: coverIndex)
    }
}

public struct TagWriter: Sendable {
    public let tools: ToolLocator
    public init(tools: ToolLocator = ToolLocator()) { self.tools = tools }

    /// Extended fields as format-specific tag keys; empty values are skipped by the caller.
    static func extraTags(_ m: TrackMetadata, ext: String) -> [(String, String)] {
        let e = m.extended
        func j(_ xs: [String]) -> String { xs.joined(separator: "; ") }
        let type = j(([e.releaseType].filter { !$0.isEmpty }) + e.releaseSecondaryTypes)
        let originalYear = String(e.originalDate.prefix(4))
        switch ext {
        case "flac":
            return [
                ("LYRICIST", e.lyricist), ("WRITER", e.writer), ("ARRANGER", e.arranger),
                ("CONDUCTOR", e.conductor), ("PRODUCER", e.producer), ("ENGINEER", e.engineer), ("MIXER", e.mixer),
                ("REMIXER", e.remixer), ("PERFORMER", j(e.performers)), ("LABEL", e.label),
                ("CATALOGNUMBER", e.catalogNumber), ("BARCODE", e.barcode), ("ASIN", e.asin),
                ("RELEASECOUNTRY", e.releaseCountry), ("RELEASESTATUS", e.releaseStatus), ("RELEASETYPE", type),
                ("MEDIA", e.mediaFormat), ("DISCSUBTITLE", e.discSubtitle), ("SCRIPT", e.script),
                ("LANGUAGE", e.language), ("ORIGINALDATE", e.originalDate), ("ORIGINALYEAR", originalYear),
                ("ISRC", j(e.isrcs)), ("WORK", e.workTitle), ("ARTISTSORT", e.artistSort),
                ("ALBUMARTISTSORT", e.albumArtistSort), ("MUSICBRAINZ_RELEASEGROUPID", e.mbReleaseGroupId),
                ("MUSICBRAINZ_ARTISTID", j(e.mbArtistIds)), ("MUSICBRAINZ_ALBUMARTISTID", j(e.mbAlbumArtistIds)),
                ("MUSICBRAINZ_RELEASETRACKID", e.mbReleaseTrackId), ("MUSICBRAINZ_WORKID", j(e.mbWorkIds)),
            ]
        case "mp3":
            return [
                ("publisher", e.label), ("TEXT", e.lyricist), ("TSRC", j(e.isrcs)), ("TMED", e.mediaFormat),
                ("TPE3", e.conductor), ("TPE4", e.remixer), ("TLAN", e.language), ("TORY", originalYear),
                ("ARTISTSORT", e.artistSort), ("CATALOGNUMBER", e.catalogNumber), ("BARCODE", e.barcode),
                ("ASIN", e.asin), ("SCRIPT", e.script), ("ALBUMARTISTSORT", e.albumArtistSort), ("WRITER", e.writer),
                ("ARRANGER", e.arranger), ("PRODUCER", e.producer), ("ENGINEER", e.engineer), ("MIXER", e.mixer),
                ("PERFORMERS", j(e.performers)), ("DISCSUBTITLE", e.discSubtitle), ("WORK", e.workTitle),
                ("originaldate", e.originalDate), ("MusicBrainz Album Type", type),
                ("MusicBrainz Album Status", e.releaseStatus), ("MusicBrainz Album Release Country", e.releaseCountry),
                ("MusicBrainz Release Group Id", e.mbReleaseGroupId), ("MusicBrainz Artist Id", j(e.mbArtistIds)),
                ("MusicBrainz Album Artist Id", j(e.mbAlbumArtistIds)),
                ("MusicBrainz Release Track Id", e.mbReleaseTrackId), ("MusicBrainz Work Id", j(e.mbWorkIds)),
            ]
        default:
            return []
        }
    }

    static func arguments(
        source: URL, output: URL, metadata m: TrackMetadata, coverPath: String?, ext: String
    ) -> [String] {
        var args = ["-nostdin", "-v", "error", "-y", "-i", source.path]
        if let coverPath { args += ["-i", coverPath] }
        if coverPath != nil {
            args += ["-map", "0:a", "-map", "1:v"]
        } else {
            args += ["-map", "0"]
        }
        args += ["-map_metadata", "0", "-c", "copy"]
        if coverPath != nil {
            args += ["-disposition:v:0", "attached_pic",
                     "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        }
        func pair(_ n: Int?, _ t: Int?) -> String {
            guard let n else { return "" }
            return t.map { "\(n)/\($0)" } ?? "\(n)"
        }
        let fields: [(String, String)] = [
            ("title", m.title), ("artist", m.artist), ("album", m.album), ("album_artist", m.albumArtist),
            ("date", m.year.map(String.init) ?? ""), ("track", pair(m.trackNo, m.trackTotal)),
            ("disc", pair(m.discNo, m.discTotal)), ("genre", m.genre), ("composer", m.composer),
            ("MUSICBRAINZ_TRACKID", m.mbRecordingId ?? ""), ("MUSICBRAINZ_ALBUMID", m.mbReleaseId ?? ""),
        ]
        for (k, v) in fields { args += ["-metadata", "\(k)=\(v)"] }
        for (k, v) in extraTags(m, ext: ext) where !v.isEmpty { args += ["-metadata", "\(k)=\(v)"] }
        if ext == "mp3" { args += ["-id3v2_version", "3"] }
        args.append(output.path)
        return args
    }

    /// Writes a tagged copy of `source` to `destination` (temp file in the destination directory, then atomic rename).
    public func writeTaggedCopy(source: URL, destination: URL, metadata: TrackMetadata, cover: Data?) async throws {
        let ext = destination.pathExtension.lowercased()
        guard tagWritableExtensions.contains(ext) else {
            throw ToolError.failed(tool: "TagWriter", status: 0, stderr: "tag writing unsupported for .\(ext)")
        }
        let ffmpeg = try tools.require("ffmpeg")
        let dir = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let temp = dir.appendingPathComponent(".tmp-\(token).\(ext)")
        var coverFile: URL?
        defer {
            try? FileManager.default.removeItem(at: temp)
            if let coverFile { try? FileManager.default.removeItem(at: coverFile) }
        }
        if let cover {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(token).jpg")
            try cover.write(to: f)
            coverFile = f
        }
        let args = Self.arguments(source: source, output: temp, metadata: metadata, coverPath: coverFile?.path, ext: ext)
        _ = try await ProcessRunner.run(ffmpeg, args)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

public enum ImageTools {
    public static func isJPEG(_ d: Data) -> Bool { d.starts(with: [0xFF, 0xD8, 0xFF]) }

    public static func jpegData(from data: Data, tools: ToolLocator = ToolLocator()) async throws -> Data {
        if isJPEG(data) { return data }
        let ffmpeg = try tools.require("ffmpeg")
        let token = UUID().uuidString
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("img-in-\(token)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("img-out-\(token).jpg")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try data.write(to: input)
        _ = try await ProcessRunner.run(ffmpeg, [
            "-nostdin", "-v", "error", "-y", "-i", input.path, "-frames:v", "1", "-q:v", "2", output.path,
        ])
        return try Data(contentsOf: output)
    }
}
