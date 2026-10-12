import Foundation
import Testing
@testable import MusicLibraryCore

/// The iPhone app's sample library (`scripts/make-sample-library.sh`), as the app opens it: read-only, in place.
@Suite struct SampleLibraryTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("iOS/MusicLibraryMobile/SampleLibrary.bundle", isDirectory: true)

    @Test func opensWithEverySongCoverAndPhoto() throws {
        let s = try LibrarySnapshot(root: Self.root, datesRelativeToNow: true)
        #expect(s.tracks.count >= 30)
        #expect(s.presentIDs.count == s.tracks.count)
        #expect(s.albums.allSatisfy { a in s.coverURL(album: a).map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(s.artists.allSatisfy { a in s.artistImageURL(a.name).map { FileManager.default.fileExists(atPath: $0.path) } == true })
        #expect(s.artists.allSatisfy { s.artistInfo($0.name)?.bio != nil })
        #expect(!s.playlists.isEmpty && !s.likedDates.isEmpty && !s.purchases.isEmpty)
        #expect(s.libraryID != nil)
        // Its history reaches today, however long ago it was made.
        let last = try #require(s.plays.last?.startedAt)
        #expect(Date().timeIntervalSince(last) < 86_400)
        #expect(s.collaborations.people.count > s.artists.count)
    }

    /// A WAL database can't be opened read-only inside an app bundle.
    @Test func databaseIsNotInWALMode() throws {
        let header = try FileHandle(forReadingFrom: LibraryLocation.databaseURL(root: Self.root)).read(upToCount: 20) ?? Data()
        #expect(header.count == 20 && header[18] == 1 && header[19] == 1)
    }

    @Test func shiftsHistoryByWholeDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(-3.5 * 86_400), now: now) == 3 * 86_400)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(-3600), now: now) == 0)
        #expect(LibrarySnapshot.dayShift(latest: now.addingTimeInterval(3600), now: now) == 0)
        #expect(LibrarySnapshot.dayShift(latest: nil, now: now) == 0)
    }
}
