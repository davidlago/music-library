import Foundation
import SQLite3
import Testing
@testable import MusicLibraryCore

private let airbagRecording = "4a7fea2e-545b-4c63-bc9a-9943cc3a29d7"

@Suite struct ReleaseExtendedParsingTests {
    func release() throws -> ReleaseInfo { try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer")) }

    @Test func releaseLevelFields() throws {
        let r = try release()
        #expect(r.label == "Capitol Records")
        #expect(r.catalogNumber == "50999 6 93623 2 3")
        #expect(r.barcode == "5099969362323")
        #expect(r.asin == "B001PPF12Q")
        #expect(r.packaging == "Digipak")
        #expect(r.script == "Latn" && r.language == "eng")
        #expect(r.country == "US" && r.status == "Official")
        #expect(r.releaseType == "Album")
        #expect(r.originalDate == "1997-05-21" && r.originalYear == 1997)
        #expect(r.albumArtistSort == "Radiohead")
        #expect(r.albumArtistIds == ["a74b1b7f-71a5-4011-9441-d0b5e4122711"])
        #expect(r.credits.contains { $0.role == "conductor" && $0.name == "Nick Ingman" && $0.scope == .release })
    }

    @Test func airbagTrackDerivation() throws {
        let r = try release()
        let t = try #require(r.track(forRecording: airbagRecording))
        let e = r.extended(for: t)
        let writers = "Colin Greenwood; Jonny Greenwood; Ed O’Brien; Philip Selway; Thom Yorke"
        #expect(CreditDerivation.derive(t.credits + r.credits).composer == writers)
        #expect(e.writer == writers)
        #expect(e.producer.components(separatedBy: "; ").sorted() == ["Nigel Godrich", "Radiohead"])
        #expect(e.engineer.contains("Jon Bailey") && e.engineer.contains("Gerard Navarro") && e.engineer.contains("Chris Scard"))
        #expect(e.mixer == "Nigel Godrich")
        #expect(e.conductor == "Nick Ingman")
        #expect(e.arranger == "Radiohead")
        #expect(e.performers.contains("Jonny Greenwood (guitar)"))
        #expect(e.performers.contains("Thom Yorke (vocals)"))
        #expect(e.performers.contains("Ed O’Brien (background vocals)"))
        #expect(e.isrcs == ["GBAYE9701274", "GBBKS1700107"])
        #expect(e.workTitle == "Airbag")
        #expect(e.mbWorkIds == ["6bba3dc1-acc7-3319-84fd-c93883b1049c"])
        #expect(e.iswcs == ["T-010.257.770-7"])
        #expect(e.mbReleaseTrackId == "401a4d9b-7902-30d1-a21b-7eb8fb9ac1e6")
        #expect(e.trackNumberLabel == "1")
        #expect(e.mbGenres.prefix(3) == ["Alternative Rock", "Rock", "Art Rock"])
        #expect(e.artistSort == "Radiohead")
        #expect(e.mediaFormat == "CD")
        #expect(e.mbArtistIds == ["a74b1b7f-71a5-4011-9441-d0b5e4122711"])
        #expect(e.credits.contains { $0.scope == .work } && e.credits.contains { $0.scope == .recording } && e.credits.contains { $0.scope == .release })
    }

    @Test func applyFillsFieldsAndGenre() throws {
        let r = try release()
        let t = try #require(r.track(forRecording: airbagRecording))
        var m = TrackMetadata(title: "airbag")
        r.apply(t, to: &m)
        #expect(m.genre == "Alternative Rock; Rock; Art Rock")
        #expect(m.composer.hasPrefix("Colin Greenwood"))
        #expect(m.extended.label == "Capitol Records")
        #expect(m.year == 1997)
    }

    @Test func applyKeepsSourceValuesWhereMusicBrainzIsEmpty() {
        let r = ReleaseInfo(id: "r", releaseGroupId: nil, album: "A", albumArtist: "B", date: nil, year: nil, originalYear: nil, discTotal: 1,
                            tracks: [ReleaseTrack(recordingId: "x", title: "T", artist: "B", discNo: 1, trackNo: 1, trackTotal: 1, durationSeconds: nil)])
        var m = TrackMetadata(genre: "Jazz", composer: "Source Composer")
        m.extended.label = "Source Label"
        m.extended.isrcs = ["ISRC0001"]
        m.extended.conductor = "Source Conductor"
        r.apply(r.tracks[0], to: &m)
        #expect(m.genre == "Jazz")
        #expect(m.composer == "Source Composer")
        #expect(m.extended.label == "Source Label")
        #expect(m.extended.isrcs == ["ISRC0001"])
        #expect(m.extended.conductor == "Source Conductor")
    }

    @Test func applyReplacesWithNonEmptyAndSiblingReuseCarriesDetails() throws {
        let r = try release()
        var m = TrackMetadata(genre: "Pop", composer: "Old")
        m.extended.label = "Old Label"
        m.extended.isrcs = ["OLD"]
        let t = try #require(r.track(forRecording: airbagRecording))
        r.apply(t, to: &m)
        #expect(m.genre == "Pop")
        #expect(m.composer != "Old")
        #expect(m.extended.label == "Capitol Records")
        #expect(m.extended.isrcs == ["GBAYE9701274", "GBBKS1700107"])
        let hit = SiblingMatcher.match(tags: TrackMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer"), entryId: "e",
                                       siblings: [(TrackMetadata(artist: "Radiohead", album: "OK Computer"), r)])
        var other = TrackMetadata()
        if let (rel, track) = hit { rel.apply(track, to: &other) }
        #expect(other.extended.label == "Capitol Records")
    }

    @Test func genreTitleCaseAndSelection() {
        #expect(GenreSelection.titleCase("dance-punk") == "Dance-Punk")
        #expect(GenreSelection.titleCase("alternative rock") == "Alternative Rock")
        let rec = [Genre(name: "rock", count: 4), Genre(name: "art rock", count: 2), Genre(name: "alternative rock", count: 7), Genre(name: "punk", count: 2)]
        #expect(GenreSelection.names(track: rec, group: [Genre(name: "x", count: 9)], release: []) == ["Alternative Rock", "Rock", "Art Rock", "Punk"])
        #expect(GenreSelection.names(track: [], group: [Genre(name: "grp", count: 1)], release: [Genre(name: "rel", count: 5)]) == ["Grp"])
        #expect(GenreSelection.names(track: [], group: [], release: [Genre(name: "rel", count: 5)]) == ["Rel"])
    }

    @Test func derivationRules() {
        let credits = [
            Credit(role: "writer", name: "W1", scope: .work), Credit(role: "writer", name: "W1", scope: .work),
            Credit(role: "lyricist", name: "L", scope: .work), Credit(role: "librettist", name: "Lb", scope: .work),
            Credit(role: "orchestrator", name: "O", scope: .work), Credit(role: "vocal arranger", name: "VA", scope: .recording),
            Credit(role: "composer", name: "C", scope: .work),
            Credit(role: "vocal", name: "V", scope: .recording), Credit(role: "performer", name: "P", scope: .recording),
            Credit(role: "instrument", name: "I", attributes: ["piano", "organ"], scope: .recording),
            Credit(role: "mix", name: "M", scope: .recording), Credit(role: "mix", name: "M", scope: .release),
        ]
        let d = CreditDerivation.derive(credits)
        #expect(d.composer == "C")
        #expect(d.writer == "W1")
        #expect(d.lyricist == "L; Lb")
        #expect(d.arranger == "O; VA")
        #expect(d.mixer == "M")
        #expect(d.performers == ["V (vocals)", "P", "I (piano)", "I (organ)"])
    }

    @Test func creditFormatterGroupsPeople() {
        let credits = [
            Credit(role: "engineer", name: "Jon", attributes: ["assistant"], scope: .recording),
            Credit(role: "instrument", name: "Jonny", attributes: ["guitar"], scope: .recording),
            Credit(role: "mix", name: "Nigel", scope: .recording),
            Credit(role: "producer", name: "Nigel", scope: .recording),
            Credit(role: "recording", name: "Nigel", scope: .recording),
            Credit(role: "instrument", name: "Jonny", attributes: ["piano", "guitar"], scope: .recording),
            Credit(role: "vocal", name: "Thom", scope: .recording),
            Credit(role: "vocal", name: "Ed", attributes: ["background vocals"], scope: .recording),
            Credit(role: "writer", name: "Thom", scope: .work),
        ]
        let g = CreditFormatter.grouped(credits)
        #expect(g.map(\.name) == ["Jon", "Jonny", "Nigel", "Thom", "Ed"])
        #expect(g[0].roles == ["assistant engineer"])
        #expect(g[1].roles == ["guitar", "piano"])
        #expect(g[2].roles == ["mixer", "producer", "recording engineer"])
        #expect(g[3].roles == ["vocals", "writer"])
        #expect(g[4].roles == ["background vocals"])
    }
}

@Suite struct ExtendedTagTests {
    static func sample() -> TrackMetadata {
        var m = TrackMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead", year: 1997,
                              trackNo: 1, trackTotal: 12, discNo: 1, discTotal: 2, genre: "Rock",
                              mbRecordingId: airbagRecording, mbReleaseId: "d4635a34-caf5-3b35-9a5b-d805f1126633", composer: "Thom Yorke; Jonny Greenwood")
        var e = ExtendedMetadata()
        e.lyricist = "Thom Yorke"; e.writer = "Thom Yorke; Jonny Greenwood"; e.arranger = "Radiohead"; e.conductor = "Nick Ingman"
        e.producer = "Nigel Godrich"; e.engineer = "Jon Bailey"; e.mixer = "Nigel Godrich"; e.remixer = "Some Remixer"
        e.label = "Capitol Records"; e.catalogNumber = "50999 6 93623 2 3"; e.barcode = "5099969362323"; e.asin = "B001PPF12Q"
        e.releaseCountry = "US"; e.releaseStatus = "Official"; e.releaseType = "Album"; e.releaseSecondaryTypes = ["Live"]
        e.language = "eng"; e.script = "Latn"; e.originalDate = "1997-05-21"; e.mediaFormat = "CD"; e.discSubtitle = "Disc One"
        e.artistSort = "Radiohead, The"; e.albumArtistSort = "Radiohead, The"; e.workTitle = "Airbag"
        e.isrcs = ["GBAYE9701274", "GBBKS1700107"]
        e.performers = ["Jonny Greenwood (guitar)", "Thom Yorke (vocals)"]
        e.mbReleaseGroupId = "b1392450-e666-3926-a536-22c65f834433"; e.mbReleaseTrackId = "401a4d9b-7902-30d1-a21b-7eb8fb9ac1e6"
        e.mbArtistIds = ["a74b1b7f-71a5-4011-9441-d0b5e4122711"]; e.mbAlbumArtistIds = ["a74b1b7f-71a5-4011-9441-d0b5e4122711"]
        e.mbWorkIds = ["6bba3dc1-acc7-3319-84fd-c93883b1049c"]
        m.extended = e
        return m
    }

    /// Fields that are database-only (not written to FLAC/MP3 tags).
    static func fileExpected() -> TrackMetadata {
        var m = sample()
        m.extended.releaseDate = ""; m.extended.trackNumberLabel = ""; m.extended.iswcs = []; m.extended.mbGenres = []; m.extended.credits = []
        return m
    }

    @Test(arguments: ["flac", "mp3"])
    func fullRoundTrip(ext: String) async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: ext)
        let dest = dir.appendingPathComponent("out.\(ext)")
        try await TagWriter().writeTaggedCopy(source: src, destination: dest, metadata: Self.sample(), cover: nil)
        let read = try await TagReader().read(dest).metadata
        #expect(read.extended == Self.fileExpected().extended)
        #expect(read == Self.fileExpected())
    }

    @Test func emptyExtendedWritesNoKeys() async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: "flac")
        let dest = dir.appendingPathComponent("out.flac")
        try await TagWriter().writeTaggedCopy(source: src, destination: dest, metadata: TrackMetadata(title: "T"), cover: nil)
        let probe = try await ProcessRunner.run(try TestSupport.tools.require("ffprobe"), ["-v", "quiet", "-print_format", "json", "-show_format", dest.path])
        let tags = ((try JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any])?["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]
        #expect(Set(tags.keys.map { $0.lowercased() }).isDisjoint(with: ["label", "isrc", "performer", "producer", "barcode", "composer"]))
    }

    @Test func m4aWritesComposerOnly() async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: "m4a")
        let dest = dir.appendingPathComponent("out.m4a")
        try await TagWriter().writeTaggedCopy(source: src, destination: dest, metadata: Self.sample(), cover: nil)
        let m = try await TagReader().read(dest).metadata
        #expect(m.composer == "Thom Yorke; Jonny Greenwood")
        #expect(m.extended.label.isEmpty && m.extended.artistSort.isEmpty)
    }

    static func id3Frames(_ url: URL) throws -> [(id: String, text: String)] {
        let b = [UInt8](try Data(contentsOf: url).prefix(65536))
        #expect(b[0] == 0x49 && b[3] == 3)
        let size = Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f)
        var pos = 10
        var out: [(String, String)] = []
        while pos + 10 < 10 + size, b[pos] != 0 {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let fs = Int(b[pos + 4]) << 24 | Int(b[pos + 5]) << 16 | Int(b[pos + 6]) << 8 | Int(b[pos + 7])
            let body = b[(pos + 11)..<(pos + 10 + fs)].map { $0 == 0 ? UInt8(ascii: "|") : $0 }
            out.append((id, String(decoding: body, as: UTF8.self)))
            pos += 10 + fs
        }
        return out
    }

    @Test func mp3NativeFramesAreWrittenAsFrames() async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: "mp3")
        let dest = dir.appendingPathComponent("out.mp3")
        try await TagWriter().writeTaggedCopy(source: src, destination: dest, metadata: Self.sample(), cover: nil)
        let frames = try Self.id3Frames(dest)
        let ids = Set(frames.map(\.id))
        for native in ["TCOM", "TPUB", "TEXT", "TSRC", "TMED", "TPE3", "TPE4", "TLAN", "TORY"] {
            #expect(ids.contains(native), "missing native frame \(native)")
        }
        let txxx = frames.filter { $0.id == "TXXX" }.map(\.text)
        for desc in ["ARTISTSORT", "CATALOGNUMBER", "ALBUMARTISTSORT", "PERFORMERS", "MusicBrainz Release Track Id", "originaldate"] {
            #expect(txxx.contains { $0.hasPrefix(desc + "|") }, "missing TXXX \(desc)")
        }
        #expect(!ids.contains("TSOP"))
    }
}

@Suite struct ExtendedDatabaseTests {
    @Test func extendedRoundTripsAndIsSearchable() throws {
        let db = try Database(path: ":memory:")
        var m = ExtendedTagTests.sample()
        m.extended.credits = [Credit(role: "producer", name: "Nigel Godrich", artistId: "id", attributes: ["x"], scope: .recording)]
        let t = try db.insertTrack(Track(path: "a.flac", metadata: m, duration: 1, format: "flac", sha256: "s"))
        let read = try #require(try db.track(id: t.id))
        #expect(read.metadata == m)
        #expect(try db.search("capitol").count == 1)
        #expect(try db.search("yorke").count == 1)
        #expect(try db.search("ingman").count == 1)
        #expect(try db.search("godrich").isEmpty)
        #expect(try db.search("CAPITOL airbag").count == 1)

        var updated = read
        updated.metadata.composer = "Someone Else"
        updated.metadata.extended = ExtendedMetadata()
        try db.updateTrack(updated)
        #expect(try db.search("capitol").isEmpty)
        #expect(try db.search("someone").count == 1)
        #expect(try db.track(id: t.id)?.metadata.extended == ExtendedMetadata())
    }

    @Test func v2DatabaseMigratesToV3() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("v2.sqlite").path
        var raw: OpaquePointer?
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        let sql = """
        CREATE TABLE tracks(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT, artist TEXT, album TEXT, album_artist TEXT,
          year INT, track_no INT, track_total INT, disc_no INT, disc_total INT, genre TEXT, duration REAL, format TEXT,
          mb_recording_id TEXT, mb_release_id TEXT, sha256 TEXT UNIQUE, added_at REAL, search_text TEXT);
        CREATE TABLE playlists(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at REAL);
        CREATE TABLE playlist_tracks(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
          track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, position INT NOT NULL, PRIMARY KEY(playlist_id, position));
        INSERT INTO tracks(path,title,artist,album,album_artist,sha256,added_at,search_text) VALUES('a.mp3','Déjà Vu','Beyoncé','Lemonade','','sha',0,'deja vu beyonce lemonade');
        PRAGMA user_version=2;
        """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let db = try Database(path: path)
        #expect(try db.query("PRAGMA user_version") { $0.int(0) }.first == Database.schemaVersion)
        var t = try #require(try db.search("deja beyonce").first)
        #expect(t.metadata.composer.isEmpty && t.metadata.extended == ExtendedMetadata())
        t.metadata.composer = "Composer Name"
        t.metadata.extended.label = "Parkwood"
        try db.updateTrack(t)
        #expect(try db.search("parkwood composer").count == 1)
    }
}
