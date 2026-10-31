import Foundation
import Testing
@testable import MusicLibraryCore

/// Matches a real collection's CDs and records to Discogs releases, live (MusicBrainz, and Discogs' database without a
/// token, so about 20 requests a minute): to see what Sync to Discogs finds and why. Opt-in: set
/// `MUSICLIB_DISCOGS_REHEARSAL` to a COPY of a `library.sqlite` (read, never written; a path under `~/Music` is
/// refused). Only the items its last sync found nothing for are looked up, unless `MUSICLIB_DISCOGS_REHEARSAL_ALL=1`.
/// Prints each item's album and the release found.
///
///     MUSICLIB_DISCOGS_REHEARSAL=/tmp/copy/library.sqlite swift test --filter DiscogsMatchRehearsalTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_DISCOGS_REHEARSAL"] != nil))
struct DiscogsMatchRehearsalTests {
    @Test(.timeLimit(.minutes(60)))
    func matchTheCollection() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["MUSICLIB_DISCOGS_REHEARSAL"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        try #require(!resolved.hasPrefix(home + "/Music/"), "Refusing a library under ~/Music: pass a copy")
        let db = try Database(snapshotAt: resolved)
        let rows = try db.discogsSyncRows()
        let all = env["MUSICLIB_DISCOGS_REHEARSAL_ALL"] == "1"
        let items = try db.collectionItems().items.filter(DiscogsReleaseMatcher.isSynced).filter { item in
            item.discogsReleaseID == nil && (all || rows[item.id]?.releaseID == nil)
        }
        let musicBrainz = MusicBrainzClient()
        let discogs = DiscogsCollectionClient(token: nil, window: 20)
        let lookup = DiscogsReleaseLookup(
            musicBrainz: { try await musicBrainz.editionFacts(releaseId: $0, releaseGroupId: $1) },
            barcode: { try await discogs.searchBarcode($0, medium: $1) },
            versions: { try await discogs.versions(masterID: $0, medium: $1) },
            search: { try await discogs.search($0, medium: $1) })
        var found = 0
        for item in items {
            do {
                if let m = try await lookup.match(for: item) {
                    found += 1
                    print("FOUND  \(item.medium.name) \(item.album) → \(m.releaseID) (\(m.quality.rawValue))")
                } else {
                    print("NONE   \(item.medium.name) \(item.album)")
                }
            } catch {
                print("ERROR  \(item.medium.name) \(item.album): \(error)")
            }
        }
        print("Found \(found) of \(items.count)")
    }
}
