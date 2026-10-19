import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CatalogIndexTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func item(_ id: String, _ title: String, author: String? = nil, year: Int? = nil, availability: CatalogAvailability = .here) -> CatalogItem {
        CatalogItem(id: id, title: title, author: author, year: year, availability: availability)
    }

    @Test func mergingDownloads() {
        let a = item("a", "Kind of blue", author: "Davis, Miles"), b = item("b", "Blue train"), c = item("c", "Giant steps")
        // The first download doesn't know when titles arrived.
        let first = CatalogRecord.merge([:], scanned: [a, b], library: "Natick", firstDownload: true, now: now)
        #expect(first.changed.count == 2 && first.removed.isEmpty && first.changed.allSatisfy { $0.firstSeen == nil })
        var stored = Dictionary(uniqueKeysWithValues: first.changed.map { ($0.id, $0) })
        #expect(stored["b"]?.addedRank == 1)

        // Later: c is new (dated), a was weeded out, b changed status.
        var checkedOut = b
        checkedOut.availability = .unavailable
        let later = now.addingTimeInterval(86_400)
        let second = CatalogRecord.merge(stored, scanned: [c, checkedOut], library: "Natick", firstDownload: false, now: later)
        #expect(second.removed == ["a"])
        for r in second.changed { stored[r.id] = r }
        for id in second.removed { stored[id] = nil }
        #expect(stored["c"]?.firstSeen == later && stored["c"]?.addedRank == 0)
        #expect(stored["b"]?.item.availability == .unavailable && stored["b"]?.firstSeen == nil)

        // Another library owning b too keeps it when Natick drops it.
        let acton = CatalogRecord.merge(stored, scanned: [checkedOut], library: "Acton", firstDownload: true, now: later)
        for r in acton.changed { stored[r.id] = r }
        #expect(stored["b"]?.libraries == ["Natick", "Acton"])
        let dropped = CatalogRecord.merge(stored, scanned: [c], library: "Natick", firstDownload: false, now: later)
        #expect(dropped.removed.isEmpty && dropped.changed.first { $0.id == "b" }?.libraries == ["Acton"])
    }

    func index() throws -> (CatalogIndex, [CatalogRecord]) {
        let page = try CatalogParser.parseResults(try TestSupport.html("minlib_results_natick"))
        let records = page.items.enumerated().map { CatalogRecord(item: $1, libraries: ["Natick"], firstSeen: nil, lastSeen: now, addedRank: $0) }
        var hamilton = CatalogAlbumDetails(workId: "d0797869-8043-715e-f883-2100b5c2cd80-eng")
        hamilton.releaseId = "r"; hamilton.releaseGroupId = "rg"
        hamilton.mbTitle = "Hamilton: An American Musical"; hamilton.mbArtist = "Lin‐Manuel Miranda"; hamilton.label = "Atlantic"
        var info = AlbumInfo(title: "Hamilton: An American Musical")
        info.genres = ["musical", "hip hop"]; info.firstReleaseDate = "2015-09-25"; info.rating = 4.5; info.secondaryTypes = ["Soundtrack"]
        info.tracklist = [TracklistEntry(disc: 1, number: 1, title: "Alexander Hamilton", artist: "Lin‐Manuel Miranda", duration: 237),
                          TracklistEntry(disc: 2, number: 1, title: "What'd I Miss", artist: "Daveed Diggs", duration: 237)]
        hamilton.album = info
        var dsotm = CatalogAlbumDetails(workId: "101115d3-1111-c274-3bd5-fe16b40c1524-eng")
        dsotm.releaseId = "r2"
        var rock = AlbumInfo(title: "The Dark Side of the Moon")
        rock.genres = ["progressive rock", "rock"]; rock.firstReleaseDate = "1973-03-01"; rock.rating = 4.6
        dsotm.album = rock
        return (CatalogIndex(records: records, details: [hamilton.workId: hamilton, dsotm.workId: dsotm]), records)
    }

    func titles(_ r: CatalogSearchResult) -> [String] { r.records.map(\.item.title) }

    @Test func searchesLikeTheLibrary() throws {
        let (index, records) = try index()
        #expect(index.count == 20)
        #expect(index.search(.parse("")).records.count == 20)
        // Genres, years and songs come from MusicBrainz; free text covers everything.
        #expect(titles(index.search(.parse("genre:rock"))) == ["The dark side of the moon"])
        #expect(titles(index.search(.parse("decade:70s"))) == ["The dark side of the moon"])
        #expect(titles(index.search(.parse("title:\"what'd i miss\""))) == ["Hamilton"])
        #expect(titles(index.search(.parse("diggs"))) == ["Hamilton"])
        let swift = index.search(.parse("artist:\"taylor swift\""), sort: .title).records.map(\.item.displayTitle)
        #expect(swift.count >= 3 && swift.contains("Folklore") && swift == swift.sorted { CatalogText.key($0) < CatalogText.key($1) })
        #expect(titles(index.search(.parse("label:atlantic OR genre:\"progressive rock\""), sort: .oldest)) == ["The dark side of the moon", "Hamilton"])
        #expect(index.search(.parse("-artist:swift")).records.count == 20 - swift.count)
        #expect(titles(index.search(.parse("time:>7m"))) == ["Hamilton"])
        #expect(titles(index.search(.parse("rating:>=4.6"))) == ["The dark side of the moon"])
        #expect(index.search(.parse("is:matched")).records.count == 2)
        // Catalog-only filters.
        let context = CatalogSearchContext(owned: [records[4].id], onList: [records[1].id])
        #expect(index.search(.parse("is:owned"), context: context).records.map(\.id) == [records[4].id])
        #expect(index.search(.parse("-is:owned"), context: context).records.count == 19)
        #expect(index.search(.parse("is:onlist"), context: context).records.map(\.id) == [records[1].id])
        // In your collection (own:) isn't in your library (is:owned).
        let collection = CatalogSearchContext(owned: [records[4].id], collection: [records[2].id: ["cd"], records[3].id: ["vinyl", "cd"],
                                                                                    records[5].id: ["download"]])
        #expect(index.search(.parse("is:owned"), context: collection).records.map(\.id) == [records[4].id])
        #expect(index.search(.parse("own:any"), context: collection).records.map(\.id) == [records[2].id, records[3].id, records[5].id])
        #expect(index.search(.parse("own:cd"), context: collection).records.map(\.id) == [records[2].id, records[3].id])
        #expect(index.search(.parse("own:vinyl"), context: collection).records.map(\.id) == [records[3].id])
        #expect(index.search(.parse("own:lp"), context: collection).records.map(\.id) == [records[3].id])
        #expect(index.search(.parse("own:download"), context: collection).records.map(\.id) == [records[5].id])
        #expect(index.search(.parse("own:physical"), context: collection).records.map(\.id) == [records[2].id, records[3].id])
        #expect(index.search(.parse("own:none"), context: collection).records.count == 17)
        #expect(index.search(.parse("-own:any"), context: collection).records.count == 17)
        #expect(index.search(.parse("own:vinyl is:owned"), context: collection).records.isEmpty)
        // Without the collection, nothing is in it.
        #expect(index.search(.parse("own:any"), context: context).records.isEmpty)
        #expect(CatalogSearchQuery.parse("own:cd").filters == [.init(kind: .collection("cd"), negated: false)])
        #expect(CatalogSearchQuery.parse("own:bogus/x").filters.isEmpty)
        let onShelf = records.filter { $0.item.availability == .here }.count
        #expect(onShelf < 20 && index.search(.parse("is:available")).records.count == onShelf)
        #expect(index.search(.parse("is:out")).records.count == 20 - onShelf)
        #expect(index.search(.parse("library:natick")).records.count == 20 && index.search(.parse("library:acton")).records.isEmpty)
        #expect(index.search(.parse(""), libraries: ["Acton"]).records.isEmpty)
    }

    @Test func rankingAndFacets() throws {
        let (index, _) = try index()
        let result = index.search(.parse("moon"))
        #expect(result.records.first?.item.title == "The dark side of the moon")
        let all = index.search(.parse(""))
        #expect(all.records.first?.addedRank == 0)
        #expect(all.genres.map(\.name).contains("musical") && all.genres.first?.count == 1)
        #expect(all.decades.map(\.decade) == [2010, 1990, 1970])
        #expect(index.search(.parse(""), sort: .newest).records.first?.item.title == "Hamilton")
        #expect(index.search(.parse(""), sort: .rating).records.prefix(2).map(\.item.title) == ["The dark side of the moon", "Hamilton"])
    }

    @Test func recordsRoundTripThroughTheDatabase() throws {
        let db = try Database(path: try TestSupport.tempDir().appendingPathComponent("library.sqlite").path)
        let (_, records) = try index()
        try db.saveCatalogRecords(records)
        #expect(try db.catalogRecords().count == 20)
        try db.saveCatalogRecords([], removing: [records[0].id])
        let stored = try db.catalogRecords()
        #expect(stored.count == 19 && stored[records[1].id] == records[1])
    }
}
