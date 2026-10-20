import CryptoKit
import Foundation

public enum CDError: Error, LocalizedError {
    case malformedTOC(String)
    case missingTrackFile(Int)

    public var errorDescription: String? {
        switch self {
        case .malformedTOC(let m): return "Unreadable CD table of contents: \(m)"
        case .missingTrackFile(let n): return "Track \(n) is not readable on the disc"
        }
    }
}

public struct CDTrack: Sendable, Equatable {
    public var number: Int
    public var startBlock: Int
    public var isData: Bool
    public var session: Int
}

public struct CDTOC: Sendable, Equatable {
    public static let dataGapFrames = 11400
    /// Red Book limit (100 minutes of 75 frames per second); `.TOC.plist` values outside it are rejected.
    public static let maxBlock = 100 * 60 * 75

    public var firstTrack: Int
    public var lastTrack: Int
    public var leadout: Int
    /// Tracks from `firstTrack` to `lastTrack` (a leading data track stays; trailing data tracks are dropped).
    public var tracks: [CDTrack]

    public var offsets: [Int] { tracks.map(\.startBlock) }
    public var audioTracks: [CDTrack] { tracks.filter { !$0.isData } }

    public static func parse(_ plistData: Data) throws -> CDTOC {
        guard let root = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let sessions = root["Sessions"] as? [[String: Any]], !sessions.isEmpty else {
            throw CDError.malformedTOC("no sessions")
        }
        var all: [CDTrack] = []
        var leadouts: [Int: Int] = [:]
        for (i, s) in sessions.enumerated() {
            let sessionNumber = s["Session Number"] as? Int ?? (i + 1)
            if let lo = s["Leadout Block"] as? Int { leadouts[sessionNumber] = lo }
            for t in s["Track Array"] as? [[String: Any]] ?? [] {
                guard let point = t["Point"] as? Int, (1...99).contains(point), let start = t["Start Block"] as? Int else { continue }
                all.append(CDTrack(number: point, startBlock: start, isData: t["Data"] as? Bool ?? false,
                                   session: t["Session Number"] as? Int ?? sessionNumber))
            }
        }
        all.sort { $0.number < $1.number }
        guard !all.isEmpty else { throw CDError.malformedTOC("no tracks") }
        guard all.allSatisfy({ (0...maxBlock).contains($0.startBlock) }) else {
            throw CDError.malformedTOC("track start out of range")
        }
        for (a, b) in zip(all, all.dropFirst()) where a.number == b.number || a.startBlock >= b.startBlock {
            throw CDError.malformedTOC("track starts are not increasing")
        }

        var kept = all
        var firstDropped: CDTrack?
        while let last = kept.last, last.isData {
            kept.removeLast()
            firstDropped = last
        }
        guard let last = kept.last else { throw CDError.malformedTOC("no audio tracks") }
        let leadout: Int
        if let dropped = firstDropped {
            leadout = dropped.startBlock - dataGapFrames
        } else if let lo = leadouts[last.session] ?? leadouts.sorted(by: { $0.key < $1.key }).last?.value {
            leadout = lo
        } else {
            throw CDError.malformedTOC("no leadout")
        }
        guard leadout <= maxBlock else { throw CDError.malformedTOC("leadout out of range") }
        guard leadout > last.startBlock else { throw CDError.malformedTOC("leadout precedes last track") }
        return CDTOC(firstTrack: kept[0].number, lastTrack: last.number, leadout: leadout, tracks: kept)
    }

    public func sectors(of track: CDTrack) -> Int {
        guard let idx = tracks.firstIndex(where: { $0.number == track.number }) else { return 0 }
        let end = idx + 1 < tracks.count ? tracks[idx + 1].startBlock : leadout
        let (diff, overflow) = end.subtractingReportingOverflow(track.startBlock)
        return overflow ? 0 : max(0, diff)
    }

    public func duration(of track: CDTrack) -> Double { Double(sectors(of: track)) / 75 }

    public var discID: String {
        var s = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadout)
        var byNumber: [Int: Int] = [:]
        for t in tracks { byNumber[t.number] = t.startBlock }
        for i in 1...99 { s += String(format: "%08X", byNumber[i] ?? 0) }
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    public var tocString: String {
        ([firstTrack, lastTrack, leadout] + offsets).map(String.init).joined(separator: " ")
    }

    var tocQueryValue: String { tocString.replacingOccurrences(of: " ", with: "+") }

    public var submissionURL: URL {
        URL(string: "https://musicbrainz.org/cdtoc/attach?id=\(discID)&tracks=\(tracks.count)&toc=\(tocQueryValue)")!
    }
}

extension CDTOC {
    /// An audio disc with tracks numbered from 1 starting at `offsets` (blocks, lead-in included), as MusicBrainz
    /// lists a disc ID. Nil unless the values could be a real CD's.
    public init?(offsets: [Int], leadout: Int) {
        guard !offsets.isEmpty, offsets.count <= 99, (0...Self.maxBlock).contains(leadout),
              offsets.allSatisfy({ (0...Self.maxBlock).contains($0) }),
              zip(offsets, offsets.dropFirst() + [leadout]).allSatisfy({ $0 < $1 }) else { return nil }
        tracks = offsets.enumerated().map { CDTrack(number: $0.offset + 1, startBlock: $0.element, isData: false, session: 1) }
        firstTrack = 1
        lastTrack = offsets.count
        self.leadout = leadout
    }

    /// Reads back `tocString` ("first last leadout offset…"). Nil unless it's well formed.
    public init?(tocString: String) {
        let values = tocString.split(separator: " ").map { Int($0) }
        guard values.count >= 4, values.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = values.compactMap { $0 }
        guard numbers[0] == 1, numbers[1] == numbers.count - 3 else { return nil }
        self.init(offsets: Array(numbers.dropFirst(3)), leadout: numbers[2])
    }
}

/// The names macOS gives a disc, from its CD-Text or from Apple's Gracenote lookup: it names the volume after the
/// album (often the artist and the album run together: "Placido Domingo Popular Favorites") and the track files
/// after the songs ("1 Somewhere, My Love.aiff"); a disc it knows nothing about is "Audio CD" with "1 Audio
/// Track.aiff" files. The names come from the disc and the drive, so they're untrusted: control characters are
/// dropped and lengths capped (they still have to go through `Organizer.sanitize` before becoming a path).
public struct CDNames: Sendable, Equatable {
    /// The volume name: the album, the artist and the album, or whatever else the disc is called.
    public var title: String?
    /// Song titles by track number.
    public var titles: [Int: String]

    public init(title: String? = nil, titles: [Int: String] = [:]) {
        self.title = title; self.titles = titles
    }

    public var isEmpty: Bool { title == nil && titles.isEmpty }

    static let maxLength = 200

    /// `trackFileNames` are the volume's track files by number, extension included.
    public static func read(volumeName: String, trackFileNames: [Int: String]) -> CDNames {
        let generic = try! NSRegularExpression(pattern: #"^Audio CD( \d+)?$"#, options: .caseInsensitive)
        let name = clean(volumeName)
        let title = name.flatMap { n in generic.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) == nil ? n : nil }
        let numbered = try! NSRegularExpression(pattern: #"^\d+\s+"#)
        var titles: [Int: String] = [:]
        for (n, file) in trackFileNames {
            let stem = (file as NSString).deletingPathExtension
            let range = numbered.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)).flatMap { Range($0.range, in: stem) }
            if let title = clean(range.map { String(stem[$0.upperBound...]) } ?? stem) { titles[n] = title }
        }
        // macOS's own name for a track it has no name for ("Audio Track", or the same words in another language on
        // every track).
        let distinct = Set(titles.values.map { $0.lowercased() })
        if distinct == ["audio track"] || (titles.count > 1 && distinct.count == 1) { titles = [:] }
        return CDNames(title: title, titles: titles)
    }

    /// Splits a disc title that runs the artist and the album together ("Placido Domingo Popular Favorites") where it
    /// starts with one of `artists` (compared without case, accents or punctuation; the longest first), giving the
    /// artist as `artists` spells it ("Plácido Domingo"). "Artist - Album" splits at the dash. Nil when neither fits
    /// or nothing would be left for the album.
    public static func split(_ title: String, artists: [String]) -> (artist: String, album: String)? {
        var known: [String: String] = [:]
        for a in artists {
            let key = TextNormalizer.normalize(a)
            if !key.isEmpty, known[key] == nil { known[key] = a }
        }
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 {
            for k in stride(from: min(words.count - 1, 8), through: 1, by: -1) {
                guard let artist = known[TextNormalizer.normalize(words[..<k].joined(separator: " "))] else { continue }
                let album = words[k...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-–—:/ "))
                if !album.isEmpty { return (artist, album) }
            }
        }
        for dash in [" - ", " – ", " — ", " / "] {
            guard let r = title.range(of: dash) else { continue }
            let artist = title[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let album = title[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !album.isEmpty { return (artist, album) }
        }
        return nil
    }

    static func clean(_ text: String) -> String? {
        var out = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: out.unicodeScalars.append(" ")
            default: out.unicodeScalars.append(scalar)
            }
        }
        let words = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : String(words.prefix(maxLength))
    }
}

public struct AudioCDVolume: Sendable {
    public var url: URL
    public var name: String
    public var toc: CDTOC
    public var trackFiles: [Int: URL]
    /// The names macOS gives the disc and its tracks.
    public var names: CDNames

    public init(url: URL, name: String, toc: CDTOC, trackFiles: [Int: URL], names: CDNames = CDNames()) {
        self.url = url; self.name = name; self.toc = toc; self.trackFiles = trackFiles; self.names = names
    }

    /// Returns nil when `url` has no `.TOC.plist` (not an audio CD).
    public static func load(at url: URL) throws -> AudioCDVolume? {
        let tocURL = url.appendingPathComponent(".TOC.plist")
        guard FileManager.default.fileExists(atPath: tocURL.path) else { return nil }
        let toc = try CDTOC.parse(try Data(contentsOf: tocURL))
        var files: [Int: URL] = [:]
        let regex = try NSRegularExpression(pattern: #"^(\d+)\s"#)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "aiff" || ext == "aif",
                  let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let r = Range(m.range(at: 1), in: name), let n = Int(name[r]) else { continue }
            files[n] = url.appendingPathComponent(name)
        }
        let names = CDNames.read(volumeName: url.lastPathComponent, trackFileNames: files.mapValues(\.lastPathComponent))
        return AudioCDVolume(url: url, name: url.lastPathComponent, toc: toc, trackFiles: files, names: names)
    }
}

extension TrackMetadata {
    /// A song of a disc MusicBrainz doesn't know, tagged as its page names it: the album and its artist (also the
    /// song's), the song's title (else "Track N"), its number of `total`, on disc 1 of 1. Names are cleaned like the
    /// disc's own (`CDNames.clean`).
    public static func unmatchedDisc(album: String, artist: String, title: String, track: Int, of total: Int) -> TrackMetadata {
        var m = TrackMetadata()
        m.album = CDNames.clean(album) ?? ""
        m.artist = CDNames.clean(artist) ?? ""
        m.albumArtist = m.artist
        m.title = CDNames.clean(title) ?? "Track \(track)"
        m.trackNo = track
        m.trackTotal = total > 0 ? total : nil
        m.discNo = 1
        m.discTotal = 1
        return m
    }
}

public enum CDTrackMapping {
    /// k-th audio track of the disc ↔ k-th track of the chosen medium (up to the shorter list).
    public static func map(audioTracks: [CDTrack], release: ReleaseInfo, medium: Int) -> [Int: ReleaseTrack] {
        let tracks = release.tracks.filter { $0.discNo == medium }.sorted { $0.trackNo < $1.trackNo }
        var result: [Int: ReleaseTrack] = [:]
        for (cd, mb) in zip(audioTracks, tracks) { result[cd.number] = mb }
        return result
    }
}

#if os(macOS)
public struct CDRipper: Sendable {
    public let tools: ToolLocator
    public init(tools: ToolLocator = ToolLocator()) { self.tools = tools }

    static func fraction(progressFile: URL, expectedDuration: Double) -> Double? {
        guard expectedDuration > 0, let text = try? String(contentsOf: progressFile, encoding: .utf8) else { return nil }
        var last: Double?
        for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
            if let v = Double(line.dropFirst("out_time_us=".count)) { last = v }
        }
        return last.map { min(max($0 / 1_000_000 / expectedDuration, 0), 1) }
    }

    public func rip(
        _ source: URL, to destination: URL, expectedDuration: Double, metadata: [String: String] = [:],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let ffmpeg = try tools.require("ffmpeg")
        let progressFile = FileManager.default.temporaryDirectory.appendingPathComponent("rip-\(UUID().uuidString).progress")
        var args = ["-nostdin", "-v", "error", "-y", "-progress", progressFile.path, "-i", source.path,
                    "-map", "0:a:0", "-c:a", "flac", "-compression_level", "8"]
        for (k, v) in metadata.sorted(by: { $0.key < $1.key }) where !v.isEmpty { args += ["-metadata", "\(k)=\(v)"] }
        args.append(destination.path)
        let finalArgs = args
        defer { try? FileManager.default.removeItem(at: progressFile) }
        do {
            progress(0)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await ProcessRunner.run(ffmpeg, finalArgs) }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        if let f = Self.fraction(progressFile: progressFile, expectedDuration: expectedDuration) { progress(f) }
                    }
                }
                try await group.next()
                group.cancelAll()
                while (try? await group.next()) != nil {}
            }
            try Task.checkCancellation()
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

public struct CDImporter: Sendable {
    public let tools: ToolLocator
    public init(tools: ToolLocator = ToolLocator()) { self.tools = tools }

    public func ripAndImport(
        volume: AudioCDVolume, cdTrack: Int, release: ReleaseInfo, releaseTrack: ReleaseTrack, cover: Data?,
        service: ImportService, workDir: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Track {
        var metadata = TrackMetadata()
        release.apply(releaseTrack, to: &metadata)
        return try await ripAndImport(volume: volume, cdTrack: cdTrack, metadata: metadata, cover: cover, service: service,
                                      workDir: workDir, progress: progress)
    }

    /// Rips a track and imports it with `metadata` as its tags (a disc MusicBrainz doesn't know, named on its page).
    public func ripAndImport(
        volume: AudioCDVolume, cdTrack: Int, metadata: TrackMetadata, cover: Data?,
        service: ImportService, workDir: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Track {
        guard let source = volume.trackFiles[cdTrack], let cd = volume.toc.tracks.first(where: { $0.number == cdTrack }) else {
            throw CDError.missingTrackFile(cdTrack)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let temp = workDir.appendingPathComponent(String(format: "%02d.flac", cdTrack))
        defer { try? FileManager.default.removeItem(at: temp) }
        try await CDRipper(tools: tools).rip(source, to: temp, expectedDuration: volume.toc.duration(of: cd), progress: progress)
        let item = try await service.prepare(temp)
        return try await service.commit(item, metadata: metadata, cover: cover)
    }
}
#endif
