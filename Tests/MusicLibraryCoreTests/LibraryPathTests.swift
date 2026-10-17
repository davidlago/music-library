import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibraryPathTests {
    @Test func acceptsOnlyPlainRelativePaths() {
        #expect(LibraryPath.isPlainRelative("Music/Art/Alb (1999)/01 - One.flac"))
        #expect(LibraryPath.isPlainRelative("Music/..hidden/a.mp3"))
        for bad in ["", "/etc/passwd", "../x.mp3", "Music/../../x.mp3", "Music/./a.mp3", "Music//a.mp3", "Music/a.mp3/", "Music/..", "a\0b"] {
            #expect(!LibraryPath.isPlainRelative(bad), "\(bad)")
        }
    }

    @Test func resolvesInsideTheRootOnly() throws {
        let root = try TestSupport.tempDir().appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music/A"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Music/A/1.mp3"))
        #expect(LibraryPath.resolve("Music/A/1.mp3", in: root) == root.appendingPathComponent("Music/A/1.mp3"))
        #expect(LibraryPath.resolve("Music/New/2.mp3", in: root) != nil)
        #expect(LibraryPath.resolve("../outside.mp3", in: root) == nil)
        #expect(LibraryPath.resolve("/etc/passwd", in: root) == nil)
        #expect(LibraryPath.coverURL(forTrackAt: "Music/A/1.mp3", root: root) == root.appendingPathComponent("Music/A/cover.jpg"))
        #expect(LibraryPath.coverURL(forTrackAt: "../../1.mp3", root: root) == nil)
    }

    @Test func rejectsSymlinksLeadingOutside() throws {
        let base = try TestSupport.tempDir()
        let root = base.appendingPathComponent("lib"), outside = base.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Music/In"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("id_rsa"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Music/Out"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Music/key.mp3"), withDestinationURL: outside.appendingPathComponent("id_rsa"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Music/dangling.mp3"), withDestinationURL: outside.appendingPathComponent("new"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Music/Alias"), withDestinationURL: root.appendingPathComponent("Music/In"))
        #expect(LibraryPath.resolve("Music/Out/id_rsa", in: root) == nil)
        #expect(LibraryPath.resolve("Music/Out/New/file.mp3", in: root) == nil)
        #expect(LibraryPath.resolve("Music/key.mp3", in: root) == nil)
        #expect(LibraryPath.resolve("Music/dangling.mp3", in: root) == nil)
        #expect(LibraryPath.resolve("Music/Alias/a.mp3", in: root) != nil)
    }

    @Test func findsFoldersEmptiedByRemovingFiles() throws {
        let root = try TestSupport.tempDir().appendingPathComponent("lib")
        let fm = FileManager.default
        func file(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            return url
        }
        // Art's only album loses its last song: the artist folder goes. Band keeps one album; Solo keeps a song.
        let removed = [try file("Music/Art/One (2001)/01 - A.flac"), try file("Music/Band/Two (2002)/01 - B.flac"),
                       try file("Music/Solo/Three (2003)/01 - C.flac"), try file("Music/Loose.flac")]
        _ = try file("Music/Art/One (2001)/cover.jpg")
        _ = try file("Music/Art/.DS_Store")
        _ = try file("Music/Band/Two (2002)/cover.jpg")
        _ = try file("Music/Band/Four (2004)/01 - D.flac")
        _ = try file("Music/Solo/Three (2003)/02 - E.flac")
        for url in removed { try fm.removeItem(at: url) }
        let emptied = LibraryPath.emptiedFolders(after: removed, root: root).map(\.path)
        #expect(Set(emptied) == [root.appendingPathComponent("Music/Art").path, root.appendingPathComponent("Music/Band/Two (2002)").path])
    }
}
