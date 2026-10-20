import Foundation
import Testing
@testable import MusicLibraryCore

private func plist(sessions: [[String: Any]]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["Sessions": sessions], format: .xml, options: 0)
}

private func track(_ n: Int, _ start: Int, data: Bool = false, session: Int = 1) -> [String: Any] {
    ["Point": n, "Start Block": start, "Data": data, "Session Number": session]
}

private func vectorPlist() throws -> Data {
    try plist(sessions: [[
        "Session Number": 1, "First Track": 1, "Last Track": 6, "Leadout Block": 95462,
        "Track Array": [track(1, 150), track(2, 15363), track(3, 32314), track(4, 46592), track(5, 63414), track(6, 80489)],
    ]])
}
let vectorDiscID = "49HHV7Eb8UKF3aQiNmu1GR8vKTY-"

func makeSimulatedCD(trackCount: Int = 2, seconds: Double = 1) async throws -> AudioCDVolume {
    let dir = try TestSupport.tempDir().appendingPathComponent("Audio CD", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try vectorPlist().write(to: dir.appendingPathComponent(".TOC.plist"))
    for n in 1...trackCount {
        try await TestSupport.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=\(300 + n * 50):duration=\(seconds)", "-ar", "44100", "-ac", "2",
                                      dir.appendingPathComponent("\(n) Audio Track.aiff").path])
    }
    return try #require(try AudioCDVolume.load(at: dir))
}

@Suite struct CDTOCTests {
    @Test func musicBrainzVector() throws {
        let toc = try CDTOC.parse(try vectorPlist())
        #expect(toc.discID == vectorDiscID)
        #expect(toc.tocString == "1 6 95462 150 15363 32314 46592 63414 80489")
        #expect(toc.submissionURL.absoluteString == "https://musicbrainz.org/cdtoc/attach?id=\(vectorDiscID)&tracks=6&toc=1+6+95462+150+15363+32314+46592+63414+80489")
        #expect(toc.audioTracks.count == 6)
    }

    @Test func durationsFromSectors() throws {
        let toc = try CDTOC.parse(try vectorPlist())
        #expect(toc.sectors(of: toc.tracks[0]) == 15213)
        #expect(abs(toc.duration(of: toc.tracks[0]) - 15213.0 / 75) < 0.001)
        #expect(toc.sectors(of: toc.tracks[5]) == 95462 - 80489)
    }

    @Test func enhancedCDDropsTrailingDataTrack() throws {
        let data = try plist(sessions: [
            ["Session Number": 1, "Leadout Block": 60000, "Track Array": [track(1, 150), track(2, 20000), track(3, 40000)]],
            ["Session Number": 2, "Leadout Block": 90000, "Track Array": [track(4, 71400, data: true, session: 2)]],
        ])
        let toc = try CDTOC.parse(data)
        #expect(toc.lastTrack == 3)
        #expect(toc.leadout == 71400 - 11400)
        #expect(toc.audioTracks.count == 3)
        #expect(toc.offsets == [150, 20000, 40000])
        #expect(toc.sectors(of: toc.tracks[2]) == 60000 - 40000)
    }

    @Test func mixedModeLeadingDataTrackStaysInTOCButIsNotAudio() throws {
        let data = try plist(sessions: [[
            "Session Number": 1, "Leadout Block": 50000,
            "Track Array": [track(1, 150, data: true), track(2, 10000), track(3, 30000)],
        ]])
        let toc = try CDTOC.parse(data)
        #expect(toc.firstTrack == 1 && toc.lastTrack == 3)
        #expect(toc.offsets == [150, 10000, 30000])
        #expect(toc.audioTracks.map(\.number) == [2, 3])
    }

    @Test func malformedThrows() {
        #expect(throws: (any Error).self) { try CDTOC.parse(Data("not a plist".utf8)) }
        #expect(throws: CDError.self) { try CDTOC.parse(try plist(sessions: [])) }
        #expect(throws: CDError.self) { try CDTOC.parse(try plist(sessions: [["Track Array": [track(1, 150, data: true)]]])) }
    }

    @Test func rejectsOutOfRangeOrUnorderedBlocks() {
        let cases: [[[String: Any]]] = [
            [["Leadout Block": 50000, "Track Array": [track(1, Int.max), track(2, Int.min)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, -1), track(2, 10000)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, 150), track(2, CDTOC.maxBlock + 1)]]],
            [["Leadout Block": Int.max, "Track Array": [track(1, 150)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, 20000), track(2, 10000)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, 150), track(2, 150)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, 150), track(1, 10000)]]],
            [["Leadout Block": 50000, "Track Array": [track(1, 150), track(2, Int.min, data: true)]]],
        ]
        for sessions in cases {
            #expect(throws: CDError.self) { try CDTOC.parse(try plist(sessions: sessions)) }
        }
    }

    @Test func sectorsDoNotOverflow() {
        let toc = CDTOC(firstTrack: 1, lastTrack: 2, leadout: 0, tracks: [
            CDTrack(number: 1, startBlock: Int.min, isData: false, session: 1),
            CDTrack(number: 2, startBlock: Int.max, isData: false, session: 1),
        ])
        #expect(toc.sectors(of: toc.tracks[0]) == 0)
        #expect(toc.sectors(of: toc.tracks[1]) == 0)
    }
}

@Suite struct AudioCDVolumeTests {
    @Test func loadsTrackFiles() async throws {
        let v = try await makeSimulatedCD()
        #expect(v.name == "Audio CD")
        #expect(Set(v.trackFiles.keys) == [1, 2])
        #expect(v.trackFiles[2]?.lastPathComponent == "2 Audio Track.aiff")
        #expect(v.toc.discID == vectorDiscID)
    }

    @Test func discWithoutNamesHasNone() async throws {
        let v = try await makeSimulatedCD()
        #expect(v.names.isEmpty)
        #expect(CDNames.read(volumeName: "Audio CD 1", trackFileNames: [1: "1 Audio Track.aiff"]).isEmpty)
        // Another language's name for an unnamed track, the same on every track.
        #expect(CDNames.read(volumeName: "Audio CD", trackFileNames: [1: "1 Piste audio.aiff", 2: "2 Piste audio.aiff"]).titles.isEmpty)
    }

    @Test func readsNamesFromTheVolume() throws {
        // As macOS mounted a real disc (Placido Domingo, Popular Favorites).
        let text = CDNames.read(volumeName: "Placido Domingo Popular Favorites", trackFileNames: [
            1: "1 Somewhere, My Love.aiff", 8: "8 Menendez: Aquellos Ojos Verdes.aiff", 10: "10 Martinez: Adiós.aiff",
        ])
        #expect(text.title == "Placido Domingo Popular Favorites")
        #expect(text.titles == [1: "Somewhere, My Love", 8: "Menendez: Aquellos Ojos Verdes", 10: "Martinez: Adiós"])
        // The same title on one track only is still a title.
        #expect(CDNames.read(volumeName: "Single", trackFileNames: [1: "1 Hello.aiff"]).titles == [1: "Hello"])
    }

    @Test func namesAreCleaned() throws {
        let long = String(repeating: "é", count: 300)
        let text = CDNames.read(volumeName: "  Line\none\u{2028}two\t ", trackFileNames: [
            1: "1 Bad\u{0}Title\u{202E}.aiff", 2: "2   .aiff", 3: "3 \(long).aiff", 4: "../4 Up.aiff",
        ])
        #expect(text.title == "Line one two")
        #expect(text.titles[1] == "Bad Title")
        #expect(text.titles[2] == nil)
        #expect(text.titles[3]?.count == CDNames.maxLength)
        #expect(text.titles[4] == "../4 Up")
        // NFC, so it compares with what the user types.
        #expect(CDNames.read(volumeName: "Adio\u{301}s", trackFileNames: [:]).title == "Adiós")
    }

    @Test func splitsArtistFromAlbum() throws {
        // The artist in your collections (or MusicBrainz's), in its spelling, the longest that fits.
        let s = try #require(CDNames.split("Placido Domingo Popular Favorites", artists: ["Placido", "Plácido Domingo", "Sting"]))
        #expect(s.artist == "Plácido Domingo" && s.album == "Popular Favorites")
        #expect(CDNames.split("Simon & Garfunkel Bookends", artists: ["Simon & Garfunkel"])?.album == "Bookends")
        #expect(CDNames.split("Sting: Ten Summoner's Tales", artists: ["Sting"])?.album == "Ten Summoner's Tales")
        // A dash splits even without a known artist.
        let dashed = try #require(CDNames.split("Norah Jones - Feels Like Home", artists: []))
        #expect(dashed.artist == "Norah Jones" && dashed.album == "Feels Like Home")
        // Nothing left for the album, an artist only in the middle, or nothing known: no split.
        #expect(CDNames.split("Plácido Domingo", artists: ["Placido Domingo"]) == nil)
        #expect(CDNames.split("The Best of Sting", artists: ["Sting"]) == nil)
        #expect(CDNames.split("Popular Favorites", artists: []) == nil)
    }

    @Test func tagsSongsOfAnUnmatchedDisc() {
        let m = TrackMetadata.unmatchedDisc(album: " Popular  Favorites ", artist: "Plácido Domingo", title: "Somewhere, My Love",
                                            track: 1, of: 10)
        #expect(m.album == "Popular Favorites" && m.artist == "Plácido Domingo" && m.albumArtist == "Plácido Domingo")
        #expect(m.title == "Somewhere, My Love" && m.trackNo == 1 && m.trackTotal == 10 && m.discNo == 1 && m.discTotal == 1)
        // A song without a name keeps its number; control characters never reach the tags.
        let blank = TrackMetadata.unmatchedDisc(album: "A\nB", artist: "", title: "  ", track: 7, of: 10)
        #expect(blank.title == "Track 7" && blank.album == "A B" && blank.artist.isEmpty)
    }

    @Test func nonCDDirectoryIsNil() throws {
        #expect(try AudioCDVolume.load(at: try TestSupport.tempDir()) == nil)
    }
}

@Suite struct DiscLookupParsingTests {
    @Test func exactMatchPicksDiscMediumAndSorts() throws {
        let r = try MusicBrainzParser.parseDiscLookup(try TestSupport.fixture("cd_disc_exact"), discID: vectorDiscID, trackCount: 6)
        #expect(r.map(\.id) == ["rel-orig", "rel-2disc"])
        #expect(r.allSatisfy { $0.exactMatch })
        let two = try #require(r.first { $0.id == "rel-2disc" })
        #expect(two.mediumPosition == 2 && two.mediumCount == 2 && two.country == "DE" && two.format == "CD")
        #expect(two.label == "Deadred Records" && two.catalogNumber == "DR E006" && two.artist == "Ettella Diamant")
        #expect(two.year == 2010)
    }

    @Test func fuzzyMatchUsesTrackCount() throws {
        let r = try MusicBrainzParser.parseDiscLookup(try TestSupport.fixture("cd_disc_fuzzy"), discID: vectorDiscID, trackCount: 6)
        #expect(r.map(\.id) == ["rel-w", "rel-y", "rel-nodate"])
        #expect(r.allSatisfy { !$0.exactMatch })
        #expect(r.first { $0.id == "rel-y" }?.mediumPosition == 2)
    }

    @Test func releaseSearchParsing() throws {
        let r = try MusicBrainzParser.parseReleaseSearch(try TestSupport.fixture("cd_release_search"), trackCount: 6)
        let d = try #require(r.first)
        #expect(d.id == "d3dc4be9-9749-4959-99e5-133d0cb467fe" && d.title == "Ettella Diamant" && !d.exactMatch)
        #expect(d.label == "Deadred Records" && d.catalogNumber == "DR E006" && d.barcode == "8586010200415")
        #expect(try MusicBrainzParser.parseReleaseSearch(try TestSupport.fixture("cd_release_search"), trackCount: 9).isEmpty)
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct CDRipperTests {
    @Test func ripsAiffToFlacWithProgress() async throws {
        let dir = try TestSupport.tempDir()
        let src = dir.appendingPathComponent("1 Audio Track.aiff")
        try await TestSupport.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=5", "-ar", "44100", "-ac", "2", src.path])
        let dest = dir.appendingPathComponent("out.flac")
        let progress = Collector()
        try await CDRipper().rip(src, to: dest, expectedDuration: 5) { progress.add($0) }
        let info = try await TagReader().read(dest)
        #expect(info.audio?.codec == "flac" && info.audio?.sampleRate == 44100 && info.audio?.channels == 2)
        #expect(abs(info.duration - 5) < 0.2)
        #expect(progress.all.last == 1)
        #expect(progress.all.first == 0)
    }

    @Test func cancellationRemovesPartialFile() async throws {
        let dir = try TestSupport.tempDir()
        let fifo = dir.appendingPathComponent("slow.aiff")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let feeder = Process()
        feeder.executableURL = try TestSupport.tools.require("ffmpeg")
        feeder.arguments = ["-nostdin", "-v", "quiet", "-re", "-f", "lavfi", "-i", "sine=frequency=440:duration=600", "-f", "wav", "-y", fifo.path]
        try feeder.run()
        defer { feeder.terminate() }
        let dest = dir.appendingPathComponent("slow.flac")
        let task = Task { try await CDRipper().rip(fifo, to: dest, expectedDuration: 600) { _ in } }
        var existed = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if FileManager.default.fileExists(atPath: dest.path) { existed = true; break }
        }
        #expect(existed)
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func missingSourceFailsAndLeavesNothing() async throws {
        let dir = try TestSupport.tempDir()
        let dest = dir.appendingPathComponent("x.flac")
        await #expect(throws: (any Error).self) {
            try await CDRipper().rip(dir.appendingPathComponent("nope.aiff"), to: dest, expectedDuration: 1) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}

@Suite struct CDMappingAndImportTests {
    func release() throws -> ReleaseInfo { try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer")) }

    @Test func mappingByPosition() throws {
        let toc = try CDTOC.parse(try vectorPlist())
        let r = try release()
        let m = CDTrackMapping.map(audioTracks: toc.audioTracks, release: r, medium: 1)
        #expect(m.count == 3)
        #expect(m[1]?.title == "Airbag" && m[3]?.title == "Subterranean Homesick Alien")
        let m2 = CDTrackMapping.map(audioTracks: toc.audioTracks, release: r, medium: 2)
        #expect(m2[1]?.title.hasPrefix("Polyethylene") == true && m2[1]?.discNo == 2)
        let short = CDTrackMapping.map(audioTracks: Array(toc.audioTracks.prefix(2)), release: r, medium: 1)
        #expect(Set(short.keys) == [1, 2])
    }

    @Test func tracksByReleaseId() throws {
        let db = try Database(path: ":memory:")
        for (i, rid) in ["r1", "r1", "r2"].enumerated() {
            var m = TrackMetadata(title: "T\(i)", mbReleaseId: rid)
            m.trackNo = 2 - (i % 2)
            try db.insertTrack(Track(path: "p\(i)", metadata: m, duration: 1, format: "flac", sha256: "s\(i)"))
        }
        #expect(try db.tracks(releaseId: "r1").map(\.trackNo) == [1, 2])
        #expect(try db.tracks(releaseId: "none").isEmpty)
    }

    @Test func ripAndImportEndToEnd() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let volume = try await makeSimulatedCD()
        let r = try release()
        let rt = try #require(r.tracks.first { $0.title == "Airbag" && $0.discNo == 1 })
        let work = try TestSupport.tempDir().appendingPathComponent("work")
        let t = try await CDImporter().ripAndImport(volume: volume, cdTrack: 1, release: r, releaseTrack: rt, cover: nil,
                                                    service: service, workDir: work) { _ in }
        #expect(t.path == "Music/Radiohead/OK Computer (1997)/1-01 - Airbag.flac")
        let info = try await TagReader().read(root.appendingPathComponent(t.path))
        #expect(info.metadata.title == "Airbag" && info.metadata.album == "OK Computer" && info.metadata.discNo == 1)
        #expect(info.metadata.mbReleaseId == r.id && info.metadata.extended.label == "Capitol Records")
        #expect(info.audio?.codec == "flac")
        #expect(try db.tracks(releaseId: r.id).count == 1)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(leftovers.isEmpty)

        await #expect(throws: ImportError.self) {
            _ = try await CDImporter().ripAndImport(volume: volume, cdTrack: 1, release: r, releaseTrack: rt, cover: nil,
                                                    service: service, workDir: work) { _ in }
        }
        #expect(try db.trackCount() == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [] == [])
    }
}
