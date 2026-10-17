import Foundation

/// What AccurateRip said about a library track ripped from a CD, with the disc it came from, so the rip can be checked
/// again later without the disc. Saved per track in `rip_checks`, apart from the track's own row.
public struct RipCheck: Sendable, Equatable {
    public enum Result: String, Sendable {
        /// Ripped, not checked yet (no network, or the check was cancelled).
        case unchecked
        /// Bit for bit the same as `confidence` other rips.
        case accurate
        /// The disc is in AccurateRip and this track doesn't match: misread.
        case inaccurate
        /// AccurateRip couldn't tell (see `AccurateRipReport.Result.unknown`).
        case unknown
        /// AccurateRip doesn't know the disc.
        case notListed
    }

    public var trackId: Int64
    /// The disc the track was ripped from.
    public var toc: CDTOC
    /// The track's number on that disc.
    public var discTrack: Int
    public var result: Result
    public var confidence: Int?
    /// The offset the rip lined up with the matching rips at (`AccurateRipReport.offset`).
    public var offset: Int?
    public var checkedAt: Date

    public init(trackId: Int64, toc: CDTOC, discTrack: Int, result: Result, confidence: Int? = nil, offset: Int? = nil,
                checkedAt: Date = Date()) {
        self.trackId = trackId; self.toc = toc; self.discTrack = discTrack; self.result = result
        self.confidence = confidence; self.offset = offset; self.checkedAt = checkedAt
    }

    /// The result of a check, for `report`'s entry for `discTrack` (or that AccurateRip doesn't know the disc).
    public init(trackId: Int64, toc: CDTOC, discTrack: Int, report: AccurateRipReport?, checkedAt: Date = Date()) {
        var result = Result.notListed
        var confidence: Int?
        switch report?.tracks[discTrack] {
        case .accurate(let c)?: result = .accurate; confidence = c
        case .inaccurate?: result = .inaccurate
        case .unknown?: result = .unknown
        case nil: result = report == nil ? .notListed : .unknown
        }
        self.init(trackId: trackId, toc: toc, discTrack: discTrack, result: result, confidence: confidence,
                  offset: report?.offset, checkedAt: checkedAt)
    }
}

extension Database {
    /// Mac-only, so it's created without a schema version change: copies synced to a phone (or exported) stay
    /// readable by phones on older versions, which refuse a newer schema and ignore tables they don't know.
    func createRipChecksTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS rip_checks(
            track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
            toc TEXT NOT NULL, disc_track INTEGER NOT NULL, result TEXT NOT NULL,
            confidence INTEGER, drive_offset INTEGER, checked_at REAL NOT NULL)
        """)
    }

    /// By track ID. Rows come from a database that may have been made elsewhere: ones that can't be read are left out.
    public func ripChecks() throws -> [Int64: RipCheck] {
        let rows = try query("SELECT track_id, toc, disc_track, result, confidence, drive_offset, checked_at FROM rip_checks") { r -> RipCheck? in
            guard let toc = r.string(1).flatMap(CDTOC.init(tocString:)), let disc = r.int(2), toc.audioTracks.contains(where: { $0.number == disc }),
                  let result = r.string(3).flatMap(RipCheck.Result.init(rawValue:)) else { return nil }
            let offset = r.int(5).flatMap { abs($0) <= AccurateRip.maxPressingOffset ? $0 : nil }
            return RipCheck(trackId: r.int64(0), toc: toc, discTrack: disc, result: result, confidence: r.int(4).map { max(0, $0) },
                            offset: offset, checkedAt: Date(timeIntervalSince1970: r.double(6)))
        }
        return Dictionary(rows.compactMap { $0 }.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func saveRipChecks(_ checks: [RipCheck]) throws {
        try transaction {
            for c in checks {
                try exec("""
                INSERT OR REPLACE INTO rip_checks(track_id,toc,disc_track,result,confidence,drive_offset,checked_at) VALUES(?,?,?,?,?,?,?)
                """, [.int(c.trackId), .text(c.toc.tocString), .int(Int64(c.discTrack)), .text(c.result.rawValue),
                      .int(c.confidence), .int(c.offset), .double(c.checkedAt.timeIntervalSince1970)])
            }
        }
    }
}

/// Which disc an album was ripped from, for albums ripped before rip checks were saved: of the discs MusicBrainz
/// lists for its release, the one whose tracks are exactly as long as the album's files.
public enum RipDiscMatcher {
    /// Only lossless CD-quality files can be a CD's tracks as ripped; anything else would fail its checksum.
    public static func isCDAudio(_ track: Track) -> Bool {
        guard track.isLossless == true, let f = track.audioFormat else { return false }
        return f.sampleRate == 44100 && f.bitDepth == 16 && f.channels == 2
    }

    /// `tracks` are one medium's tracks; each must be its track number's length on the disc, within half a sector
    /// (durations are rounded; discs differ by whole sectors). Returns the disc and the tracks' numbers on it.
    public static func disc(for tracks: [Track], among tocs: [CDTOC]) -> (toc: CDTOC, discTracks: [Int64: Int])? {
        let candidates = tracks.filter(isCDAudio)
        guard !candidates.isEmpty else { return nil }
        for toc in tocs {
            var numbers: [Int64: Int] = [:]
            for t in candidates {
                guard let n = t.trackNo, let cd = toc.audioTracks.first(where: { $0.number == n }) else { break }
                let samples = Double(toc.sectors(of: cd) * AccurateRip.samplesPerSector)
                guard abs(t.duration * 44100 - samples) < Double(AccurateRip.samplesPerSector / 2) else { break }
                numbers[t.id] = n
            }
            if numbers.count == candidates.count { return (toc, numbers) }
        }
        return nil
    }
}

extension MusicBrainzParser {
    /// The disc IDs of each medium of a release (`inc=discids`), by medium position.
    public static func parseDiscTOCs(_ data: Data) throws -> [Int: [CDTOC]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("unexpected MusicBrainz release")
        }
        var result: [Int: [CDTOC]] = [:]
        for medium in root["media"] as? [[String: Any]] ?? [] {
            guard let position = medium["position"] as? Int else { continue }
            let tocs = (medium["discs"] as? [[String: Any]] ?? []).compactMap { disc -> CDTOC? in
                guard let offsets = disc["offsets"] as? [Int], let sectors = disc["sectors"] as? Int else { return nil }
                return CDTOC(offsets: offsets, leadout: sectors)
            }
            if !tocs.isEmpty { result[position, default: []] += tocs }
        }
        return result
    }
}

extension MusicBrainzClient {
    /// The discs submitted for a release's media, by medium position.
    public func discTOCs(releaseId: String) async throws -> [Int: [CDTOC]] {
        let url = try Self.lookupURL("release", id: releaseId, query: "inc=discids&fmt=json")
        return try MusicBrainzParser.parseDiscTOCs(try await fetchData(url))
    }
}
