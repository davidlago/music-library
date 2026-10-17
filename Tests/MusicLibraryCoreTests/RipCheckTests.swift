import Foundation
import Testing
@testable import MusicLibraryCore

/// Medium 2 of a real release: MusicBrainz lists three discs for it (`mb_release_discids.json`).
private let medium2 = [
    CDTOC(offsets: [150, 16995, 34582, 46052, 60075, 79487, 98147, 112357, 127765, 140730, 155605], leadout: 174405)!,
    CDTOC(offsets: [150, 16995, 34582, 46052, 60075, 79487, 98147, 112357, 127765, 140730, 155605], leadout: 174555)!,
    CDTOC(offsets: [150, 16995, 34592, 46062, 60075, 79487, 98147, 112357, 127765, 140740, 155605], leadout: 174255)!,
]

/// Library tracks as ripped from `toc`, with the durations ffprobe reports (rounded to microseconds).
private func rippedTracks(_ toc: CDTOC, codec: String = "flac", bitDepth: Int = 16) -> [Track] {
    toc.audioTracks.map { cd in
        let seconds = (Double(toc.sectors(of: cd) * 588) / 44100 * 1_000_000).rounded() / 1_000_000
        return Track(id: Int64(cd.number * 10), path: "Music/A/B/\(cd.number).flac", metadata: TrackMetadata(title: "T", trackNo: cd.number),
                     duration: seconds, format: codec == "mp3" ? "mp3" : "flac", sha256: "\(cd.number)",
                     audioFormat: AudioFormat(codec: codec, sampleRate: 44100, bitDepth: bitDepth, channels: 2))
    }
}

@Suite struct RipCheckTests {
    @Test func readsBackTOCs() {
        let toc = medium2[0]
        #expect(CDTOC(tocString: toc.tocString) == toc)
        for bad in ["", "1 2 300", "1 3 300 150 200", "2 2 300 150 200", "1 2 300 150 abc", "1 2 200 150 300", "1 2 9999999 150 200", "1 1 300 -5"] {
            #expect(CDTOC(tocString: bad) == nil, "\(bad)")
        }
    }

    @Test func savesChecksWithTheirTracks() throws {
        let db = try Database(path: ":memory:")
        let track = try db.insertTrack(rippedTracks(medium2[0])[0])
        let check = RipCheck(trackId: track.id, toc: medium2[0], discTrack: 1, result: .accurate, confidence: 156, offset: 6,
                             checkedAt: Date(timeIntervalSince1970: 1_000_000))
        try db.saveRipChecks([check])
        #expect(try db.ripChecks() == [track.id: check])
        // Unreadable rows (from a library made elsewhere) are left out.
        try db.exec("INSERT OR REPLACE INTO rip_checks VALUES(?,?,?,?,?,?,?)", [.int(track.id), .text("1 1 nonsense"), .int(1), .text("accurate"), .null, .null, .double(0)])
        #expect(try db.ripChecks().isEmpty)
        try db.saveRipChecks([check])
        try db.deleteTrack(id: track.id)
        #expect(try db.ripChecks().isEmpty)
    }

    @Test func recordsAReport() {
        let report = AccurateRipReport(tracks: [1: .accurate(confidence: 12), 2: .inaccurate], offset: 6)
        #expect(RipCheck(trackId: 1, toc: medium2[0], discTrack: 1, report: report).result == .accurate)
        #expect(RipCheck(trackId: 1, toc: medium2[0], discTrack: 1, report: report).confidence == 12)
        #expect(RipCheck(trackId: 2, toc: medium2[0], discTrack: 2, report: report).result == .inaccurate)
        #expect(RipCheck(trackId: 3, toc: medium2[0], discTrack: 3, report: report).result == .unknown)
        #expect(RipCheck(trackId: 3, toc: medium2[0], discTrack: 3, report: nil).result == .notListed)
    }

    @Test func parsesARealReleasesDiscs() throws {
        let tocs = try MusicBrainzParser.parseDiscTOCs(try TestSupport.fixture("mb_release_discids"))
        #expect(tocs.keys.sorted() == [1, 2, 3, 4, 5, 6])
        #expect(tocs[2] == medium2)
    }

    @Test func findsTheDiscAnAlbumWasRippedFrom() throws {
        for toc in medium2 {
            let match = try #require(RipDiscMatcher.disc(for: rippedTracks(toc), among: medium2))
            #expect(match.toc == toc)
            #expect(match.discTracks[30] == 3)
        }
        // A track missing from the album is fine; lossy or hi-res files are never CD rips.
        #expect(RipDiscMatcher.disc(for: Array(rippedTracks(medium2[2]).dropFirst()), among: medium2)?.toc == medium2[2])
        #expect(RipDiscMatcher.disc(for: rippedTracks(medium2[0], codec: "mp3"), among: medium2) == nil)
        #expect(RipDiscMatcher.disc(for: rippedTracks(medium2[0], bitDepth: 24), among: medium2) == nil)
        // A track no disc has (an edit, a bonus track) means none of them.
        var odd = rippedTracks(medium2[0])
        odd[4].duration += 0.5
        #expect(RipDiscMatcher.disc(for: odd, among: medium2) == nil)
    }

    @Test func findsEveryDiscWithTheAlbumsLengths() {
        // A disc whose tracks all start 32 sectors later (a real pressing of another album) has the same lengths and
        // is listed apart in AccurateRip: both are candidates.
        let shifted = CDTOC(offsets: medium2[0].offsets.map { $0 + 32 }, leadout: medium2[0].leadout + 32)!
        let found = RipDiscMatcher.discs(for: rippedTracks(medium2[0]), among: [medium2[0], medium2[1], shifted])
        #expect(found.map(\.toc) == [medium2[0], shifted])
        #expect(AccurateRipDisc(toc: shifted) != AccurateRipDisc(toc: medium2[0]))
    }

    @Test(arguments: ["pcm_s16be", "pcm_s16le"])
    func readsCDTrackFilesLikeTheirRips(codec: String) async throws {
        // macOS shows CD tracks as AIFF-C with little-endian samples (`sowt`); plain big-endian AIFF reads the same.
        let dir = try TestSupport.tempDir()
        let aiff = dir.appendingPathComponent("1 Audio Track.aiff"), flac = dir.appendingPathComponent("1.flac")
        try await TestSupport.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
                                      "-filter_complex", "[0][1]amerge=inputs=2", "-ar", "44100", "-c:a", codec, aiff.path])
        try await TestSupport.ffmpeg(["-i", aiff.path, "-c:a", "flac", flac.path])
        let file = try CDTrackAudioFile(url: aiff)
        #expect(file.sampleCount == 44100)
        let decoded = try await PCMDecoder.samples(of: flac, tools: ToolLocator())
        #expect(decoded.count == 44100)
        #expect(try file.samples(0..<44100) == decoded)
        #expect(try file.samples(1000..<1588) == Array(decoded[1000..<1588]))
        #expect(try file.samples(44000..<44101) == nil)
        // Left and right are different tones: the left channel is the low half.
        #expect(decoded[1000] & 0xFFFF != decoded[1000] >> 16)
        #expect(throws: CDAudioError.self) { try CDTrackAudioFile(url: flac) }
    }
}
