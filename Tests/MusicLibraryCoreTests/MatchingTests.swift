import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct MatchingTests {
    @Test func parsesMusicBrainzSearch() throws {
        let c = try MusicBrainzParser.parseSearch(try TestSupport.fixture("mb_search_airbag"))
        #expect(!c.isEmpty)
        let first = try #require(c.first)
        #expect(first.score == 100)
        #expect(first.title == "Airbag")
        #expect(first.artist == "Radiohead")
        let ok = try #require(c.first { $0.releaseId == "d4635a34-caf5-3b35-9a5b-d805f1126633" })
        #expect(ok.album == "OK Computer")
        #expect(ok.year == 2009)
        #expect(ok.releaseType == "Album")
        #expect(ok.releaseStatus == "Official")
        #expect(ok.releaseGroupId == "b1392450-e666-3926-a536-22c65f834433")
        #expect(ok.durationSeconds == 289.066)
        #expect(c.count <= 25)
        let scores = c.map(\.score)
        #expect(scores == scores.sorted(by: >))
    }

    @Test func parsesRelease() throws {
        let r = try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer"))
        #expect(r.album == "OK Computer")
        #expect(r.albumArtist == "Radiohead")
        #expect(r.year == 2009)
        #expect(r.discTotal == 2)
        #expect(r.releaseGroupId == "b1392450-e666-3926-a536-22c65f834433")
        let airbag = try #require(r.track(forRecording: "4a7fea2e-545b-4c63-bc9a-9943cc3a29d7"))
        #expect(airbag.trackNo == 1 && airbag.discNo == 1 && airbag.trackTotal == 12)
        #expect(airbag.title == "Airbag")
        let poly = try #require(r.tracks.first { $0.title.hasPrefix("Polyethylene") })
        #expect(poly.discNo == 2 && poly.trackTotal == 15 && poly.trackNo == 1)
        var meta = TrackMetadata(title: "airbag", genre: "Rock")
        r.apply(airbag, to: &meta)
        #expect(meta.album == "OK Computer" && meta.discTotal == 2 && meta.trackTotal == 12 && meta.genre == "Rock")
        #expect(meta.mbReleaseId == r.id)
    }

    @Test func parsesAcoustID() throws {
        let c = try AcoustIDParser.parse(try TestSupport.fixture("acoustid_lookup"))
        #expect(c.count == 2)
        #expect(c[0].score == 97)
        #expect(c[0].source == .acoustID)
        #expect(c[0].album == "OK Computer")
        #expect(c[0].date == "2009-03-24" && c[0].year == 2009)
        #expect(c[1].releaseId.hasPrefix("0d2c4b2a") && c[1].date == "1997")
        #expect(c[0].releaseType == "Album" && c[0].durationSeconds == 284)
    }

    @Test func acoustIDErrorStatusThrows() {
        let bad = Data(#"{"status":"error","error":{"message":"invalid API key"}}"#.utf8)
        #expect(throws: NetworkError.self) { try AcoustIDParser.parse(bad) }
    }

    @Test func acoustIDUnavailableWithoutKeyOrFpcalc() {
        #expect(AcoustIDClient(apiKey: "") == nil)
        #expect(AcoustIDClient(apiKey: "key", tools: ToolLocator(searchPaths: ["/nonexistent"])) == nil)
    }

    @Test func fpcalcJSON() throws {
        let r = try AcoustIDClient.parseFingerprint(Data(#"{"duration": 284.4, "fingerprint": "AQAA"}"#.utf8))
        #expect(r.duration == 284 && r.fingerprint == "AQAA")
    }

    @Test func luceneEscaping() {
        #expect(MusicBrainzClient.luceneEscape(#"AC/DC (live) "x""#) == #"AC\/DC \(live\) \"x\""#)
        #expect(MusicBrainzClient.searchQuery(title: "Airbag", artist: "Radiohead", album: "") == #"recording:"Airbag" AND artist:"Radiohead""#)
        #expect(MusicBrainzClient.searchQuery(title: "A", artist: "B", album: "C") == #"recording:"A" AND artist:"B" AND release:"C""#)
        #expect(MusicBrainzClient.searchQuery(title: "", artist: "", album: "").isEmpty)
    }

    @Test func titleNormalization() {
        #expect(TextNormalizer.normalize("Pearly*") == "pearly")
        #expect(TextNormalizer.normalize("Café — Déjà Vu!") == "cafe deja vu")
    }

    @Test func releaseMatcherByTitleThenTrackNumber() throws {
        let r = try MusicBrainzParser.parseRelease(try TestSupport.fixture("mb_release_okcomputer"))
        let items = [
            ReleaseMatcher.Input(id: "a", title: "AIRBAG", trackNo: nil),
            ReleaseMatcher.Input(id: "b", title: "pearly", trackNo: 9),
            ReleaseMatcher.Input(id: "c", title: "Wrong Name", trackNo: 3, discNo: 1),
            ReleaseMatcher.Input(id: "d", title: "Unknown", trackNo: nil),
            ReleaseMatcher.Input(id: "e", title: "Dup", trackNo: 1),
        ]
        let m = ReleaseMatcher.match(items, to: r)
        #expect(m["a"]?.title == "Airbag")
        #expect(m["b"]?.title == "Pearly*")
        #expect(m["c"]?.title == "Subterranean Homesick Alien")
        #expect(m["d"] == nil)
        #expect(m["e"]?.title.hasPrefix("Polyethylene") == true)
    }

    @Test func autoMatchRule() {
        let c = MatchCandidate(recordingId: "r", releaseId: "x", title: "T", artist: "A", album: "B", durationSeconds: 100, score: 96)
        #expect(AutoMatch.isConfident(c, trackDuration: 103))
        #expect(!AutoMatch.isConfident(c, trackDuration: 106))
        var low = c; low.score = 90
        #expect(!AutoMatch.isConfident(low, trackDuration: 100))
    }
}

@Suite struct MBIDValidationTests {
    let okComputer = "d4635a34-caf5-3b35-9a5b-d805f1126633"

    @Test func onlyUUIDsAreAccepted() {
        #expect(MBID.validated(okComputer) == okComputer)
        #expect(MBID.validated(" D4635A34-CAF5-3B35-9A5B-D805F1126633\n") == okComputer)
        for bad in [nil, "", "a b", "r1", "../../artist/x", "\(okComputer)?inc=x", "{\(okComputer)}", "\(okComputer)#x"] {
            #expect(MBID.validated(bad) == nil)
        }
        #expect(MBID.validated([okComputer, "a b"]) == [okComputer])
    }

    @Test func lookupURLsRejectInvalidIDs() async throws {
        let url = try MusicBrainzClient.lookupURL("release", id: okComputer, query: "inc=genres+ratings&fmt=json")
        #expect(url.absoluteString == "https://musicbrainz.org/ws/2/release/\(okComputer)?inc=genres+ratings&fmt=json")
        for bad in ["a b", "\"<>", "../../x", "x?y#z"] {
            #expect(throws: NetworkError.self) { try MusicBrainzClient.lookupURL("artist", id: bad, query: "fmt=json") }
        }
        // Rejected before any request is made.
        let mb = MusicBrainzClient(contact: "musiclibrary-tests")
        await #expect(throws: NetworkError.self) { try await mb.fetchRelease(id: "a b") }
        await #expect(throws: NetworkError.self) { try await mb.lookupReleaseGroup(id: "a b") }
        await #expect(throws: NetworkError.self) { try await mb.lookupArtist(id: "a b") }
    }

    @Test func tagsDropInvalidIDs() throws {
        let probe = """
        {"format": {"tags": {"title": "T", "MUSICBRAINZ_ALBUMID": "a b", "MUSICBRAINZ_TRACKID": "4A7FEA2E-545B-4C63-BC9A-9943CC3A29D7",
          "MUSICBRAINZ_RELEASEGROUPID": "../x", "MUSICBRAINZ_ARTISTID": "a74b1b7f-71a5-4011-9441-d0b5e4122711; <bad>"}}}
        """
        let m = try TagReader.parse(probeJSON: Data(probe.utf8)).metadata
        #expect(m.mbReleaseId == nil)
        #expect(m.mbRecordingId == "4a7fea2e-545b-4c63-bc9a-9943cc3a29d7")
        #expect(m.extended.mbReleaseGroupId.isEmpty)
        #expect(m.extended.mbArtistIds == ["a74b1b7f-71a5-4011-9441-d0b5e4122711"])
    }

    @Test func databaseRowsDropInvalidIDs() throws {
        let db = try Database(path: ":memory:")
        var m = TrackMetadata(title: "T", mbRecordingId: "a b", mbReleaseId: okComputer)
        m.extended.mbReleaseGroupId = "x y"
        m.extended.mbAlbumArtistIds = ["<bad>", "a74b1b7f-71a5-4011-9441-d0b5e4122711"]
        let t = try db.insertTrack(Track(path: "p", metadata: m, duration: 1, format: "flac", sha256: "s"))
        let loaded = try #require(try db.track(id: t.id)).metadata
        #expect(loaded.mbRecordingId == nil && loaded.mbReleaseId == okComputer)
        #expect(loaded.extended.mbReleaseGroupId.isEmpty)
        #expect(loaded.extended.mbAlbumArtistIds == ["a74b1b7f-71a5-4011-9441-d0b5e4122711"])
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_LIVE_TESTS"] == "1"))
struct LiveDiscTests {
    @Test func vectorDiscLookup() async throws {
        let toc = CDTOC(firstTrack: 1, lastTrack: 6, leadout: 95462, tracks: [150, 15363, 32314, 46592, 63414, 80489].enumerated().map {
            CDTrack(number: $0.offset + 1, startBlock: $0.element, isData: false, session: 1)
        })
        let found = try await MusicBrainzClient(contact: "musiclibrary-tests").lookupDisc(toc)
        print("LIVE disc: \(found.map { "\($0.title) / \($0.artist) (\($0.date)) medium \($0.mediumPosition) exact=\($0.exactMatch)" })")
        let r = try #require(found.first)
        #expect(r.exactMatch && r.mediumPosition == 1 && r.artist == "Ettella Diamant")
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_LIVE_TESTS"] == "1"))
struct LiveExtendedTests {
    @Test func okComputerExtendedFields() async throws {
        let mb = MusicBrainzClient(contact: "musiclibrary-tests")
        let release = try await mb.fetchRelease(id: "d4635a34-caf5-3b35-9a5b-d805f1126633")
        let track = try #require(release.tracks.first { $0.title == "Airbag" && $0.discNo == 1 })
        let e = release.extended(for: track)
        let composer = CreditDerivation.derive(track.credits + release.credits).composer
        print("LIVE extended: label=\(e.label) catalog=\(e.catalogNumber) composer=\(composer) credits=\(e.credits.count) isrcs=\(e.isrcs) genres=\(e.mbGenres.prefix(3)) performers=\(e.performers.count)")
        #expect(!e.label.isEmpty)
        #expect(!e.credits.isEmpty)
        #expect(!composer.isEmpty)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_LIVE_TESTS"] == "1"))
struct LiveTests {
    @Test func musicBrainzSearchReleaseAndCover() async throws {
        let mb = MusicBrainzClient(contact: "musiclibrary-tests")
        let candidates = try await mb.searchRecordings(title: "Airbag", artist: "Radiohead", album: "OK Computer")
        print("LIVE search: \(candidates.count) candidates; top: \(candidates.first.map { "\($0.title) / \($0.artist) / \($0.album) (\($0.year ?? 0)) score \($0.score) \($0.releaseType ?? "") \($0.secondaryTypes)" } ?? "-")")
        let okc = try #require(candidates.first { $0.album == "OK Computer" && $0.releaseStatus == "Official" })
        let release = try await mb.fetchRelease(id: okc.releaseId)
        let track = try #require(release.track(forRecording: okc.recordingId) ?? release.tracks.first { $0.title == "Airbag" })
        print("LIVE release: \(release.album) by \(release.albumArtist), \(release.tracks.count) tracks, discs \(release.discTotal); year \(release.year ?? 0), originalYear \(release.originalYear ?? 0); Airbag = \(track.discNo)-\(track.trackNo)/\(track.trackTotal)")
        #expect(release.tracks.count > 10)
        let cover = try await CoverArtClient().fetchFront(releaseId: release.id, releaseGroupId: release.releaseGroupId)
        print("LIVE cover: \(cover?.count ?? 0) bytes, jpeg=\(cover.map(ImageTools.isJPEG) ?? false)")
        #expect((cover?.count ?? 0) > 1000)
    }

    @Test func artistPhotoSearch() async throws {
        let finder = ArtistPhotoFinder()
        let found = try await finder.search("Radiohead")
        print("LIVE artist photos: \(found.filter { $0.source == .deezer }.count) Deezer, \(found.filter { $0.source == .commons }.count) Commons")
        let deezer = try #require(found.first { $0.source == .deezer })
        #expect((try await finder.thumbnail(deezer)?.count ?? 0) > 1000)
        let commons = try #require(found.first { $0.source == .commons })
        let photo = try await finder.image(for: commons)
        print("LIVE Commons photo \(commons.title): \(photo?.count ?? 0) bytes")
        #expect((photo?.count ?? 0) > 1000)
    }
}
