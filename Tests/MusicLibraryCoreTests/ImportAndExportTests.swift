import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ImportServiceTests {
    @Test func commitFlacWithCover() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let src = try await TestSupport.makeAudio(in: try TestSupport.tempDir(), name: "raw", ext: "flac")
        let jpeg = try await TestSupport.makeJPEG(in: try TestSupport.tempDir())
        let item = try await service.prepare(src)
        #expect(item.duplicateOf == nil)
        #expect(item.sha256.count == 64)

        let meta = TrackMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead", year: 1997, trackNo: 1, trackTotal: 12)
        let track = try await service.commit(item, metadata: meta, cover: jpeg)
        #expect(track.path == "Music/Radiohead/OK Computer (1997)/01 - Airbag.flac")
        let dest = root.appendingPathComponent(track.path)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(FileManager.default.fileExists(atPath: dest.deletingLastPathComponent().appendingPathComponent("cover.jpg").path))
        let info = try await TagReader().read(dest)
        #expect(info.metadata.title == "Airbag" && info.metadata.trackTotal == 12 && info.metadata.year == 1997)
        #expect(info.hasEmbeddedCover)
        #expect(try db.fetchAllTracks().map(\.path) == [track.path])
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func duplicateDetectionAndCollisions() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let srcDir = try TestSupport.tempDir()
        let a = try await TestSupport.makeAudio(in: srcDir, name: "a", ext: "mp3", frequency: 440)
        let b = try await TestSupport.makeAudio(in: srcDir, name: "b", ext: "mp3", frequency: 880)
        let meta = TrackMetadata(title: "Same", artist: "X", album: "Y", trackNo: 1)
        let t1 = try await service.commit(try await service.prepare(a), metadata: meta, cover: nil)
        let again = try await service.prepare(a)
        #expect(again.duplicateOf?.id == t1.id)
        await #expect(throws: ImportError.self) { _ = try await service.commit(again, metadata: meta, cover: nil) }
        let t2 = try await service.commit(try await service.prepare(b), metadata: meta, cover: nil)
        #expect(t2.path == "Music/X/Y/01 - Same (2).mp3")
        #expect(try db.trackCount() == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(t2.path).path))
    }

    @Test func wavIsCopiedWithoutTagging() async throws {
        let (root, _, service) = try TestSupport.makeLibrary()
        let src = try await TestSupport.makeAudio(in: try TestSupport.tempDir(), name: "w", ext: "wav")
        let t = try await service.commit(try await service.prepare(src), metadata: TrackMetadata(title: "W", artist: "A", album: "B", trackNo: 2), cover: nil)
        #expect(t.path == "Music/A/B/02 - W.wav")
        #expect(try Data(contentsOf: root.appendingPathComponent(t.path)) == Data(contentsOf: src))
    }

    @Test func failureLeavesNoPartialFiles() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let dir = try TestSupport.tempDir()
        let bogus = dir.appendingPathComponent("bogus.mp3")
        try Data("not audio".utf8).write(to: bogus)
        let item = ImportItem(sourceURL: bogus, sha256: "abc", tags: TrackMetadata(), duration: 0, format: "mp3", embeddedCover: nil, duplicateOf: nil)
        await #expect(throws: (any Error).self) {
            _ = try await service.commit(item, metadata: TrackMetadata(title: "T", artist: "A", album: "B"), cover: nil)
        }
        #expect(try db.trackCount() == 0)
        let music = root.appendingPathComponent("Music")
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: music.path))?.filter { !$0.isEmpty } ?? []
        #expect(left.isEmpty)
    }

    @Test func discoverRecursesAndFilters() throws {
        let dir = try TestSupport.tempDir()
        let sub = dir.appendingPathComponent("sub/deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for f in ["a.mp3", "b.txt", "sub/c.FLAC", "sub/deeper/d.m4a", "sub/.hidden.mp3", "sub/e.jpg"] {
            try Data().write(to: dir.appendingPathComponent(f))
        }
        let names = ImportService.discover([dir]).map(\.lastPathComponent)
        #expect(Set(names) == ["a.mp3", "c.FLAC", "d.m4a"])
        #expect(ImportService.discover([dir.appendingPathComponent("b.txt")]).isEmpty)
    }
}

@Suite struct PlaylistExporterTests {
    @Test func exportsFilesAndM3UIncrementally() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let srcDir = try TestSupport.tempDir()
        var tracks: [Track] = []
        for (i, title) in ["Intro / Part 1", "Second"].enumerated() {
            let src = try await TestSupport.makeAudio(in: srcDir, name: "s\(i)", ext: "mp3", frequency: 300 + i * 100)
            let meta = TrackMetadata(title: title, artist: "Art", album: "Alb", trackNo: i + 1)
            tracks.append(try await service.commit(try await service.prepare(src), metadata: meta, cover: nil))
        }
        _ = db
        let dest = try TestSupport.tempDir()
        var progress: [Int] = []
        let folder = try PlaylistExporter().export(name: "Road: Trip", tracks: tracks, libraryRoot: root, to: dest) { done, _ in progress.append(done) }
        #expect(folder.lastPathComponent == "Road_ Trip")
        #expect(progress == [0, 1, 2])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["01 - Art - Intro _ Part 1.mp3", "02 - Art - Second.mp3", "Road_ Trip.m3u"])
        let m3u = try String(contentsOf: folder.appendingPathComponent("Road_ Trip.m3u"), encoding: .utf8)
        #expect(m3u.hasPrefix("#EXTM3U\n"))
        #expect(m3u.contains("#EXTINF:1,Art - Intro / Part 1\n01 - Art - Intro _ Part 1.mp3\n"))
        #expect(m3u.hasSuffix("02 - Art - Second.mp3\n"))

        let first = folder.appendingPathComponent(files[0])
        let mtime = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try PlaylistExporter().export(name: "Road: Trip", tracks: tracks, libraryRoot: root, to: dest)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        #expect(mtime == mtime2)

        try Data("junk".utf8).write(to: first)
        try PlaylistExporter().export(name: "Road: Trip", tracks: tracks, libraryRoot: root, to: dest)
        #expect(try Data(contentsOf: first) == Data(contentsOf: tracks[0].fileURL(root: root)))
    }

    @Test func numberingWidthGrows() {
        #expect(PlaylistExporter.m3uContents(entries: [("a.mp3", "A", "T", 61.4)]) == "#EXTM3U\n#EXTINF:61,A - T\na.mp3\n")
    }
}
