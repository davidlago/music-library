import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct AlbumCoverTests {
    @Test func releaseListKeepsAnyTrackCount() throws {
        let data = try TestSupport.fixture("cd_release_search")
        let list = try MusicBrainzParser.parseCoverSearch(data)
        #expect(list.map(\.id) == ["d3dc4be9-9749-4959-99e5-133d0cb467fe"])
        #expect(list.first?.format == "CD")
        #expect(list.first?.releaseGroupId == "1e18709f-ae50-39de-aef5-3cce3229791b")
        // The CD search still requires a matching medium.
        #expect(try MusicBrainzParser.parseReleaseSearch(data, trackCount: 9).isEmpty)
    }

    @Test func releaseListDropsInvalidIds() throws {
        let json = #"{"releases":[{"id":"../../evil","title":"X","media":[{"track-count":3}]},{"id":"D3DC4BE9-9749-4959-99E5-133D0CB467FE","title":"Y","release-group":{"id":"nope"},"media":[]}]}"#
        let list = try MusicBrainzParser.parseCoverSearch(Data(json.utf8))
        #expect(list.map(\.id) == ["d3dc4be9-9749-4959-99e5-133d0cb467fe"])
        #expect(list.first?.releaseGroupId == nil)
    }

    @Test func replacesCoverFileAndEmbeddedArt() async throws {
        let (root, db, _) = try TestSupport.makeLibrary()
        let scratch = try TestSupport.tempDir()
        let albumDir = root.appendingPathComponent("Music/Artist/Album (2020)")
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        let red = try await TestSupport.makeJPEG(in: scratch, name: "red", color: "red")
        let blue = try await TestSupport.makeJPEG(in: scratch, name: "blue", color: "blue")
        try red.write(to: albumDir.appendingPathComponent("cover.jpg"))

        var tracks: [Track] = []
        for (n, ext) in [(1, "flac"), (2, "mp3"), (3, "m4a"), (4, "wav")] {
            let src = try await TestSupport.makeAudio(in: scratch, name: "src\(n)", ext: ext)
            let rel = "Music/Artist/Album (2020)/0\(n) - Song \(n).\(ext)"
            var m = TrackMetadata(title: "Song \(n)", artist: "Artist", album: "Album")
            m.trackNo = n
            if ext == "wav" {
                try FileManager.default.copyItem(at: src, to: root.appendingPathComponent(rel))
            } else {
                try await TagWriter().writeTaggedCopy(source: src, destination: root.appendingPathComponent(rel), metadata: m, cover: red)
            }
            tracks.append(try db.insertTrack(Track(path: rel, metadata: m, duration: 1, format: ext, sha256: "sha\(n)")))
        }
        // A stored path leading outside the library is never touched.
        tracks.append(Track(id: 99, path: "../outside.flac", metadata: TrackMetadata(title: "x"), duration: 1, format: "flac", sha256: "x"))

        #expect(AlbumCoverWriter.embeddable(tracks).count == 4)
        let result = try await AlbumCoverWriter(root: root).apply(blue, to: tracks, embed: true)
        #expect(result.embedded == 3)
        #expect(result.failures.map(\.file) == ["outside.flac"])
        #expect(try Data(contentsOf: albumDir.appendingPathComponent("cover.jpg")) == blue)

        let reader = TagReader()
        for t in tracks.prefix(3) {
            let url = root.appendingPathComponent(t.path)
            let info = try await reader.read(url)
            #expect(info.metadata.title == t.title)
            #expect(info.duration > 0.8)
            #expect(try await reader.extractCover(url, info: info) == blue)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: albumDir.path).filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func coverOnlyLeavesFilesAlone() async throws {
        let (root, _, _) = try TestSupport.makeLibrary()
        let scratch = try TestSupport.tempDir()
        let dir = root.appendingPathComponent("Music/A/B")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try await TestSupport.makeAudio(in: scratch, name: "s", ext: "flac")
        try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("01 - x.flac"))
        let before = try Data(contentsOf: dir.appendingPathComponent("01 - x.flac"))
        let blue = try await TestSupport.makeJPEG(in: scratch, name: "blue", color: "blue")
        let track = Track(id: 1, path: "Music/A/B/01 - x.flac", metadata: TrackMetadata(title: "x"), duration: 1, format: "flac", sha256: "s")

        let result = try await AlbumCoverWriter(root: root).apply(blue, to: [track], embed: false)
        #expect(result.embedded == 0 && result.failures.isEmpty)
        #expect(try Data(contentsOf: dir.appendingPathComponent("cover.jpg")) == blue)
        #expect(try Data(contentsOf: dir.appendingPathComponent("01 - x.flac")) == before)
    }

    @Test func rejectsNonJPEGAndAlbumsOutsideTheLibrary() async throws {
        let root = try TestSupport.tempDir()
        let outside = Track(id: 1, path: "../x/y.flac", metadata: TrackMetadata(title: "y"), duration: 1, format: "flac", sha256: "y")
        let inside = Track(id: 2, path: "Music/A/B/y.flac", metadata: TrackMetadata(title: "y"), duration: 1, format: "flac", sha256: "z")
        await #expect(throws: (any Error).self) { try await AlbumCoverWriter(root: root).apply(Data("png?".utf8), to: [inside], embed: false) }
        await #expect(throws: (any Error).self) { try await AlbumCoverWriter(root: root).apply(Data([0xFF, 0xD8, 0xFF, 0xE0]), to: [outside], embed: false) }
    }
}
