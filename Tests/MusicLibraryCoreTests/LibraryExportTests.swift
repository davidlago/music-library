import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibraryExporterTests {
    /// Two albums: "A" with two tracks and a cover, "B" with one track and no cover.
    private func makeLibrary() async throws -> (root: URL, db: Database, tracks: [Track]) {
        let (root, db, service) = try TestSupport.makeLibrary()
        let srcDir = try TestSupport.tempDir()
        let jpeg = try await TestSupport.makeJPEG(in: srcDir)
        var tracks: [Track] = []
        for (i, (album, title)) in [("A", "One"), ("A", "Two"), ("B", "Three")].enumerated() {
            let src = try await TestSupport.makeAudio(in: srcDir, name: "s\(i)", ext: "mp3", frequency: 300 + i * 100)
            let meta = TrackMetadata(title: title, artist: "Art", album: album, trackNo: i + 1)
            tracks.append(try await service.commit(try await service.prepare(src), metadata: meta, cover: album == "A" ? jpeg : nil))
        }
        return (root, db, tracks)
    }

    private func files(in dir: URL) -> [String] {
        let all = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(p).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    @Test func mirrorsLibraryLayoutWithCovers() async throws {
        let (root, _, tracks) = try await makeLibrary()
        let dest = try TestSupport.tempDir()
        var progress: [Int] = []
        let summary = try LibraryExporter().export(tracks: tracks + [tracks[0]], libraryRoot: root, to: dest) { done, _ in progress.append(done) }
        #expect(files(in: dest) == [
            "Music/Art/A/01 - One.mp3", "Music/Art/A/02 - Two.mp3", "Music/Art/A/cover.jpg", "Music/Art/B/03 - Three.mp3",
        ])
        #expect(summary.copied == 3 && summary.skipped == 0 && summary.covers == 1 && !summary.databaseBackedUp)
        #expect(summary.bytesCopied > 0)
        #expect(progress == [0, 1, 2, 3, 4])
        for t in tracks {
            #expect(try Data(contentsOf: dest.appendingPathComponent(t.path)) == Data(contentsOf: t.fileURL(root: root)))
        }
    }

    @Test func neverOverwritesExistingFiles() async throws {
        let (root, _, tracks) = try await makeLibrary()
        let dest = try TestSupport.tempDir()
        let existing = dest.appendingPathComponent(tracks[1].path)
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing)
        let cover = existing.deletingLastPathComponent().appendingPathComponent("cover.jpg")
        try Data("my cover".utf8).write(to: cover)

        let first = try LibraryExporter().export(tracks: Array(tracks.prefix(2)), libraryRoot: root, to: dest)
        #expect(first.copied == 1 && first.skipped == 1 && first.covers == 0)
        #expect(try Data(contentsOf: existing) == Data("mine".utf8))
        #expect(try Data(contentsOf: cover) == Data("my cover".utf8))

        let again = try LibraryExporter().export(tracks: tracks, libraryRoot: root, to: dest)
        #expect(again.copied == 1 && again.skipped == 2)
        #expect(try Data(contentsOf: existing) == Data("mine".utf8))
    }

    @Test func backsUpDatabaseReplacingThePreviousCopy() async throws {
        let (root, db, tracks) = try await makeLibrary()
        let p = try db.createPlaylist(name: "Mix")
        try db.addTracks([tracks[2].id], toPlaylist: p.id)
        let dest = try TestSupport.tempDir()
        let target = dest.appendingPathComponent("library.sqlite")
        try Data("old backup".utf8).write(to: target)
        try Data("stale wal".utf8).write(to: URL(fileURLWithPath: target.path + "-wal"))

        let summary = try LibraryExporter().export(tracks: [], database: db, libraryRoot: root, to: dest)
        #expect(summary.databaseBackedUp && summary.copied == 0)
        #expect(files(in: dest) == ["library.sqlite"])
        let copy = try Database(path: target.path)
        #expect(try copy.fetchAllTracks().map(\.path) == tracks.map(\.path))
        #expect(try copy.playlistTracks(p.id).map(\.id) == [tracks[2].id])

        // Later changes reach the destination on the next backup.
        try db.deleteTrack(id: tracks[0].id)
        try LibraryExporter().export(tracks: [], database: db, libraryRoot: root, to: dest)
        #expect(try Database(path: target.path).trackCount() == 2)
    }

    @Test func writesPlaylistsPointingAtTheExportedMusic() async throws {
        let (root, _, tracks) = try await makeLibrary()
        let dest = try TestSupport.tempDir()
        let summary = try LibraryExporter().export(
            tracks: tracks,
            playlists: [ExportPlaylist(name: "Road: Trip", tracks: [tracks[2], tracks[0]]),
                        ExportPlaylist(name: "road: trip", tracks: [tracks[1]]),
                        ExportPlaylist(name: "Empty", tracks: [])],
            libraryRoot: root, to: dest)
        #expect(summary.playlists == 2)
        let folder = dest.appendingPathComponent("Playlists")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Road_ Trip.m3u", "road_ trip (2).m3u"])
        let m3u = try String(contentsOf: folder.appendingPathComponent("Road_ Trip.m3u"), encoding: .utf8)
        #expect(m3u == "#EXTM3U\n#EXTINF:1,Art - Three\n../Music/Art/B/03 - Three.mp3\n#EXTINF:1,Art - One\n../Music/Art/A/01 - One.mp3\n")
        for line in m3u.split(separator: "\n") where !line.hasPrefix("#") {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(line)).standardized.path))
        }
    }

    @Test func missingLibraryFileFailsBeforeCopying() async throws {
        let (root, _, tracks) = try await makeLibrary()
        try FileManager.default.removeItem(at: tracks[2].fileURL(root: root))
        let dest = try TestSupport.tempDir()
        #expect(throws: LibraryExportError.self) { try LibraryExporter().export(tracks: tracks, libraryRoot: root, to: dest) }
        #expect(files(in: dest).isEmpty)
    }

    @Test func cancellingLeavesOnlyCompleteFiles() async throws {
        let (root, _, tracks) = try await makeLibrary()
        let dest = try TestSupport.tempDir()
        let result = await Task {
            Result {
                try LibraryExporter().export(tracks: tracks, libraryRoot: root, to: dest) { done, _ in
                    if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }.value
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(files(in: dest) == ["Music/Art/A/01 - One.mp3"])
    }

    @Test func planCountsOnlyWhatIsMissing() async throws {
        let (root, _, tracks) = try await makeLibrary()
        let dest = try TestSupport.tempDir()
        try LibraryExporter().export(tracks: [tracks[0]], libraryRoot: root, to: dest)
        let plan = try LibraryExporter().plan(tracks: tracks, libraryRoot: root, destination: dest)
        #expect(plan.files.map(\.path) == [tracks[1].path, tracks[2].path])
        #expect(plan.covers.isEmpty && plan.skipped == 1)
        #expect(plan.bytesNeeded == plan.files.reduce(0) { $0 + $1.size })
    }
}
