import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct OrganizerTests {
    @Test func basicPath() {
        let m = TrackMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer", year: 1997, trackNo: 1)
        #expect(Organizer.relativePath(for: m, sourceStem: "x", ext: "flac") == "Music/Radiohead/OK Computer (1997)/01 - Airbag.flac")
    }

    @Test func albumArtistWinsAndCompilations() {
        let m = TrackMetadata(title: "Song", artist: "Guest", album: "Hits", albumArtist: "Various Artists", trackNo: 12)
        #expect(Organizer.relativePath(for: m, sourceStem: "x", ext: "mp3") == "Music/Various Artists/Hits/12 - Song.mp3")
    }

    @Test func unknownsAndMissingTrack() {
        let m = TrackMetadata()
        #expect(Organizer.relativePath(for: m, sourceStem: "my file", ext: "mp3") == "Music/Unknown Artist/Unknown Album/my file.mp3")
    }

    @Test func multiDisc() {
        let m = TrackMetadata(title: "T", artist: "A", album: "B", trackNo: 3, discNo: 2, discTotal: 2)
        #expect(Organizer.relativePath(for: m, sourceStem: "x", ext: "flac") == "Music/A/B/2-03 - T.flac")
        let single = TrackMetadata(title: "T", artist: "A", album: "B", trackNo: 3, discNo: 1, discTotal: 1)
        #expect(Organizer.relativePath(for: single, sourceStem: "x", ext: "flac") == "Music/A/B/03 - T.flac")
    }

    @Test func sanitizeReplacesIllegalCharacters() {
        #expect(Organizer.sanitize("AC/DC: Back in \"Black\"?") == "AC_DC_ Back in _Black__")
        #expect(Organizer.sanitize("a\u{0}b\tc") == "a_b_c")
    }

    @Test func sanitizeTrimsDotsAndSpaces() {
        #expect(Organizer.sanitize("  ..Hidden. . ") == "Hidden")
        #expect(Organizer.sanitize("Wait...") == "Wait")
        #expect(Organizer.sanitize("...") == "")
    }

    @Test func sanitizeNormalizesNFC() {
        let decomposed = "Cafe\u{301}"
        #expect(Organizer.sanitize(decomposed).unicodeScalars.count == 4)
        #expect(Organizer.sanitize(decomposed) == "Caf\u{E9}")
    }

    @Test func sanitizeTruncatesWithoutSplittingGraphemes() {
        let long = String(repeating: "日本語", count: 40)
        let out = Organizer.sanitize(long)
        #expect(out.utf8.count <= 120)
        #expect(out.count == 40)
        let flags = String(repeating: "🇯🇵", count: 30)
        let f = Organizer.sanitize(flags)
        #expect(f.utf8.count <= 120)
        #expect(f.count == 120 / 8)
        let family = Organizer.sanitize("a" + String(repeating: "👨‍👩‍👧", count: 10))
        #expect(family.unicodeScalars.count % 5 == 1)
    }

    @Test func longTitleKeepsExtension() {
        let m = TrackMetadata(title: String(repeating: "x", count: 300), artist: "A", album: "B", trackNo: 1)
        let p = Organizer.relativePath(for: m, sourceStem: "s", ext: "flac")
        #expect(p.hasSuffix(".flac"))
        #expect((p as NSString).lastPathComponent.utf8.count <= 120)
    }

    @Test func yearOmittedWhenUnknown() {
        let m = TrackMetadata(title: "T", artist: "A", album: "B")
        #expect(Organizer.relativePath(for: m, sourceStem: "s", ext: "wav") == "Music/A/B/T.wav")
    }

    @Test func collisionsGetSuffix() {
        var taken: Set<String> = ["a/b.mp3", "a/b (2).mp3"]
        #expect(Organizer.uniquePath("a/b.mp3") { taken.contains($0) } == "a/b (3).mp3")
        #expect(Organizer.uniquePath("a/c.mp3") { taken.contains($0) } == "a/c.mp3")
        taken.insert("a/b (3).mp3")
        #expect(Organizer.uniquePath("a/b.mp3") { taken.contains($0) } == "a/b (4).mp3")
    }
}

@Suite struct FilenameParserTests {
    @Test(arguments: [
        ("01 - Radiohead - Airbag", ParsedFilename(trackNo: 1, artist: "Radiohead", title: "Airbag")),
        ("Radiohead - Airbag", ParsedFilename(trackNo: nil, artist: "Radiohead", title: "Airbag")),
        ("01. Airbag", ParsedFilename(trackNo: 1, artist: nil, title: "Airbag")),
        ("07 - Airbag", ParsedFilename(trackNo: 7, artist: nil, title: "Airbag")),
        ("Airbag", ParsedFilename(trackNo: nil, artist: nil, title: "Airbag")),
        ("03_Paranoid_Android", ParsedFilename(trackNo: 3, artist: nil, title: "Paranoid Android")),
        ("12 Karma Police", ParsedFilename(trackNo: 12, artist: nil, title: "Karma Police")),
    ])
    func parses(stem: String, expected: ParsedFilename) {
        #expect(FilenameParser.parse(stem: stem) == expected)
    }
}
