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

    // MARK: Scans

    /// A library of `total` titles (ids "t0"…), page `n` of it as the catalog lists it.
    func catalogPage(_ n: Int, total: Int, reported: Int? = nil) -> CatalogPage {
        let start = (n - 1) * CatalogPage.pageSize
        let items = (start..<min(start + CatalogPage.pageSize, total)).map { item("t\($0)", "Title \($0)") }
        return CatalogPage(items: items, total: reported ?? total, page: n)
    }

    /// Scans pages until the scan finishes or a page is suspect, folding them into `records` as the app does.
    func scan(_ pages: (Int) -> CatalogPage, into records: inout [String: CatalogRecord]) -> (CatalogScan, CatalogScan.Step) {
        var scan = CatalogScan()
        while true {
            let page = pages(scan.nextPage)
            let step = scan.add(page)
            guard step != .suspect else { return (scan, step) }
            for r in CatalogRecord.upsert(records, page: page.items, library: "Natick", startRank: 0, firstDownload: false, now: now) {
                records[r.id] = r
            }
            if step == .finished { return (scan, step) }
        }
    }

    func storedLibrary(_ total: Int) -> [String: CatalogRecord] {
        Dictionary(uniqueKeysWithValues: (0..<total).map {
            ("t\($0)", CatalogRecord(item: item("t\($0)", "Title \($0)"), libraries: ["Natick"], firstSeen: nil, lastSeen: now, addedRank: $0))
        })
    }

    /// A refresh of Natick's 2,172 CDs while the site was throttling: page 23 came back as a page with no result
    /// count and no results, which used to end the scan as complete and prune all but the 440 titles seen.
    @Test func throttledPageDoesNotPrune() throws {
        let throttled = try CatalogParser.parseResults("<html><head><title>Just a moment...</title></head><body></body></html>", page: 23)
        #expect(throttled.items.isEmpty && throttled.total == 0)
        var records = storedLibrary(2172)
        let (scan, step) = self.scan({ $0 == 23 ? throttled : catalogPage($0, total: 2172) }, into: &records)
        #expect(step == .suspect && scan.nextPage == 23 && scan.seen.count == 440 && scan.total == 2172 && !scan.finished)
        #expect(scan.pruning(records, library: "Natick") == nil)

        // A page reporting a much smaller count (with or without results) doesn't shrink the scan either.
        for shrunk in [catalogPage(23, total: 2172, reported: 440), CatalogPage(items: [], total: 440, page: 23)] {
            var records = storedLibrary(2172)
            let (scan, step) = self.scan({ $0 == 23 ? shrunk : catalogPage($0, total: 2172) }, into: &records)
            #expect(step == .suspect && scan.total == 2172 && scan.pruning(records, library: "Natick") == nil)
        }

        // Reading the page again once the site recovers finishes the scan, and then nothing is missing.
        var resumed = scan
        while !resumed.finished { #expect(resumed.add(catalogPage(resumed.nextPage, total: 2172)) != .suspect) }
        #expect(resumed.seen.count == 2172 && resumed.pruning(records, library: "Natick")?.removed == [])
    }

    @Test func completeScansStillPrune() {
        // One title weeded out (t5 gone, so the catalog lists 2,171).
        var records = storedLibrary(2172)
        let weeded: (Int) -> CatalogPage = { n in
            var page = catalogPage(n, total: 2172, reported: 2171)
            page.items.removeAll { $0.id == "t5" }
            return page
        }
        let (scan, step) = self.scan(weeded, into: &records)
        #expect(step == .finished && scan.pageCount == 109)
        #expect(scan.pruning(records, library: "Natick")?.removed == ["t5"])

        // Titles leaving mid-scan can empty the last page; a page that says it's past the end is the end. Having
        // seen 2,160 of the 2,172 it started with, the scan leaves pruning to the next one.
        var shrinking = storedLibrary(2172)
        let (late, lateStep) = self.scan({ $0 == 109 ? CatalogPage(items: [], total: 2160, page: 109) : catalogPage($0, total: 2172) },
                                         into: &shrinking)
        #expect(lateStep == .finished && late.seen.count == 2160 && late.pruning(shrinking, library: "Natick") == nil)
    }

    @Test func scansFarSmallerThanLastTimeDoNotPrune() {
        // The site consistently reporting 400 of 2,172 (or nothing at all) is a site problem, not a weeding.
        var records = storedLibrary(2172)
        let (scan, step) = self.scan({ catalogPage($0, total: 400) }, into: &records)
        #expect(step == .finished && scan.pruning(records, library: "Natick") == nil)

        var emptied = storedLibrary(2172)
        let (none, noneStep) = self.scan({ CatalogPage(items: [], total: 0, page: $0) }, into: &emptied)
        #expect(noneStep == .finished && none.pruning(emptied, library: "Natick") == nil)

        // A library with nothing downloaded yet and no CDs finishes with nothing to do.
        var fresh: [String: CatalogRecord] = [:]
        let (empty, _) = self.scan({ CatalogPage(items: [], total: 0, page: $0) }, into: &fresh)
        #expect(empty.pruning(fresh, library: "Natick")?.removed == [])
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
