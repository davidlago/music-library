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

public struct AudioCDVolume: Sendable {
    public var url: URL
    public var name: String
    public var toc: CDTOC
    public var trackFiles: [Int: URL]

    public init(url: URL, name: String, toc: CDTOC, trackFiles: [Int: URL]) {
        self.url = url; self.name = name; self.toc = toc; self.trackFiles = trackFiles
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
        return AudioCDVolume(url: url, name: url.lastPathComponent, toc: toc, trackFiles: files)
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
        guard let source = volume.trackFiles[cdTrack], let cd = volume.toc.tracks.first(where: { $0.number == cdTrack }) else {
            throw CDError.missingTrackFile(cdTrack)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let temp = workDir.appendingPathComponent(String(format: "%02d.flac", cdTrack))
        defer { try? FileManager.default.removeItem(at: temp) }
        try await CDRipper(tools: tools).rip(source, to: temp, expectedDuration: volume.toc.duration(of: cd), progress: progress)
        var metadata = TrackMetadata()
        release.apply(releaseTrack, to: &metadata)
        let item = try await service.prepare(temp)
        return try await service.commit(item, metadata: metadata, cover: cover)
    }
}
