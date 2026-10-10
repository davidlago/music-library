import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct TagTests {
    let sample = TrackMetadata(
        title: "Airbag", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead", year: 1997,
        trackNo: 1, trackTotal: 12, discNo: 1, discTotal: 2, genre: "Rock",
        mbRecordingId: "4a7fea2e-545b-4c63-bc9a-9943cc3a29d7", mbReleaseId: "d4635a34-caf5-3b35-9a5b-d805f1126633")

    func roundTrip(ext: String, withCover: Bool) async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: ext, tags: ["title": "Old", "artist": "Old Artist"])
        let jpeg = try await TestSupport.makeJPEG(in: dir)
        let dest = dir.appendingPathComponent("out.\(ext)")
        try await TagWriter().writeTaggedCopy(source: src, destination: dest, metadata: sample, cover: withCover ? jpeg : nil)

        let reader = TagReader()
        let info = try await reader.read(dest)
        var expected = sample
        if ext == "m4a" { expected.mbRecordingId = nil; expected.mbReleaseId = nil }
        #expect(info.metadata == expected)
        #expect(info.format == ext)
        #expect(info.duration > 0.8 && info.duration < 1.5)
        #expect(info.hasEmbeddedCover == withCover)
        if withCover {
            let data = try await reader.extractCover(dest, info: info)
            #expect(data.map(ImageTools.isJPEG) == true)
        }
        // original untouched
        let orig = try await reader.read(src)
        #expect(orig.metadata.title == "Old")
        // no temp leftovers
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func flacRoundTrip() async throws { try await roundTrip(ext: "flac", withCover: false) }
    @Test func flacRoundTripWithCover() async throws { try await roundTrip(ext: "flac", withCover: true) }
    @Test func mp3RoundTrip() async throws { try await roundTrip(ext: "mp3", withCover: false) }
    @Test func mp3RoundTripWithCover() async throws { try await roundTrip(ext: "mp3", withCover: true) }
    @Test func m4aRoundTrip() async throws { try await roundTrip(ext: "m4a", withCover: false) }
    @Test func m4aRoundTripWithCover() async throws { try await roundTrip(ext: "m4a", withCover: true) }

    @Test func existingCoverKeptWhenNoNewCover() async throws {
        let dir = try TestSupport.tempDir()
        let src = try await TestSupport.makeAudio(in: dir, name: "src", ext: "flac")
        let jpeg = try await TestSupport.makeJPEG(in: dir)
        let withCover = dir.appendingPathComponent("a.flac")
        try await TagWriter().writeTaggedCopy(source: src, destination: withCover, metadata: sample, cover: jpeg)
        let retagged = dir.appendingPathComponent("b.flac")
        var m = sample; m.title = "Changed"
        try await TagWriter().writeTaggedCopy(source: withCover, destination: retagged, metadata: m, cover: nil)
        let info = try await TagReader().read(retagged)
        #expect(info.hasEmbeddedCover)
        #expect(info.metadata.title == "Changed")
    }

    @Test func readsUppercaseVorbisAndLowercaseId3Keys() async throws {
        let dir = try TestSupport.tempDir()
        let flac = try await TestSupport.makeAudio(in: dir, name: "a", ext: "flac", tags: [
            "TITLE": "T", "ARTIST": "A", "ALBUMARTIST": "AA", "DATE": "2001-05-06", "TRACKNUMBER": "3", "TRACKTOTAL": "9", "DISCNUMBER": "2/3"])
        let m = try await TagReader().read(flac).metadata
        #expect(m.title == "T" && m.artist == "A" && m.albumArtist == "AA")
        #expect(m.year == 2001 && m.trackNo == 3 && m.trackTotal == 9 && m.discNo == 2 && m.discTotal == 3)
        let mp3 = try await TestSupport.makeAudio(in: dir, name: "b", ext: "mp3", tags: ["title": "T2", "track": "4/10"])
        let m2 = try await TagReader().read(mp3).metadata
        #expect(m2.title == "T2" && m2.trackNo == 4 && m2.trackTotal == 10)
    }

    @Test func untaggedFileReadsEmpty() async throws {
        let dir = try TestSupport.tempDir()
        let wav = try await TestSupport.makeAudio(in: dir, name: "w", ext: "wav")
        let info = try await TagReader().read(wav)
        #expect(info.metadata.title.isEmpty)
        #expect(!info.hasEmbeddedCover)
    }

    @Test func toolLocatorFindsFfmpegAndMissingThrows() {
        #expect(TestSupport.tools.ffmpeg != nil)
        #expect(ToolLocator(searchPaths: ["/nonexistent"]).find("ffmpeg") == nil)
    }
}
