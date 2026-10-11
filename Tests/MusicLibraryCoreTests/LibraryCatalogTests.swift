import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct LibraryCatalogTests {
    // MARK: Queries

    @Test func queryPaths() {
        let q = CatalogQuery(libraries: ["Natick"])
        #expect(q.path() == "/Search/Results?lookfor=&searchIndex=Keyword&filter%5B%5D=format%3A%22Music%20CD%22&filter%5B%5D=owning_location%3A%22Natick%22&sort=relevance&view=list&searchSource=local")
        let r = CatalogQuery(text: "  miles davis ", field: .artist, libraries: ["Natick", "Acton West"], availableAt: "Natick", sort: .newest)
        let path = r.path(page: 3)
        #expect(path.contains("lookfor=miles%20davis&searchIndex=Author"))
        #expect(path.contains("owning_location%3A%22Acton%20West%22") && path.contains("available_at%3A%22Natick%22"))
        #expect(path.contains("sort=year%20desc%2Ctitle%20asc") && path.hasSuffix("&page=3"))
        #expect(CatalogPaths.copies(workId: "abc-eng") == "/GroupedWork/abc-eng/AJAX?method=getCopyDetails&format=Music%20CD&recordId=abc-eng")
        #expect(CatalogPaths.editions(workId: "abc-eng", variationId: "42").hasSuffix("format=Music_CD&variationId=42"))
        #expect(CatalogPaths.loginBody(username: "2 1&2", password: "p=w") == "username=2%201%262&password=p%3Dw&rememberMe=true")
        #expect(CatalogPaths.siteLibrary(URL(string: "https://natick.minlib.net")!) == "Natick")
        #expect(CatalogPaths.siteLibrary(URL(string: "https://minlib.net")!) == nil)
    }

    // MARK: Results pages

    @Test func resultsPage() throws {
        let page = try CatalogParser.parseResults(try TestSupport.html("minlib_results_natick"))
        #expect(page.total == 2176 && page.items.count == 20 && page.hasMore && page.searchId == "88781706")
        let hamilton = try #require(page.items.first { $0.id == "d0797869-8043-715e-f883-2100b5c2cd80-eng" })
        #expect(hamilton.title == "Hamilton" && hamilton.subtitle == "original Broadway cast recording")
        #expect(hamilton.displayTitle == "Hamilton: Original Broadway Cast Recording")
        #expect(hamilton.author == "Miranda, Lin-Manuel, 1980-" && hamilton.artist == "Lin-Manuel Miranda")
        #expect(hamilton.recordId == ".b34105876" && hamilton.variationId == "1668895")
        #expect(hamilton.availability == .here && hamilton.statusText == "On Shelf")
        #expect(hamilton.shelfLocation == "Natick - Audiovisual" && hamilton.callNumber == "[CD] Musical/H217" && hamilton.availableCopies == 1)
        #expect(hamilton.pagePath == "/GroupedWork/d0797869-8043-715e-f883-2100b5c2cd80-eng/Home")
        // A single-record work links to its record, and compilations have no author.
        let hitsville = try #require(page.items.first { $0.title == "Hitsville U.S.A" })
        #expect(hitsville.author == nil && hitsville.artist == "" && hitsville.year == 1993 && hitsville.pagePath == "/Record/.b15060536")
        #expect(page.items.first { $0.title == "The dark side of the moon" }?.artist == "Pink Floyd")
    }

    @Test func statusesOutsideTheLibrary() throws {
        let page = try CatalogParser.parseResults(try TestSupport.html("minlib_results_beatles"))
        #expect(page.total == 145 && page.items.count == 20)
        let counts = Dictionary(grouping: page.items, by: \.availability).mapValues(\.count)
        #expect(counts[.elsewhere, default: 0] > 0 && counts[.unavailable, default: 0] > 0)
        let anthology = try #require(page.items.first { $0.id == "5dfd0d51-9ae4-2e76-c5f7-f02ae13df1b8-eng" })
        #expect(anthology.title == "Anthology" && anthology.subtitle == "4" && anthology.year == 2025 && anthology.shelfLocation == nil)
        #expect(CatalogAvailability(statusClass: "status-checked-out-available-elsewhere") == .elsewhere)
        #expect(CatalogAvailability(statusClass: "status-on-order") == .onOrder)
    }

    @Test func laterPage() throws {
        let page = try CatalogParser.parseResults(try TestSupport.html("minlib_results_available"), page: 2)
        #expect(page.total == 1975 && page.items.count == 20 && page.page == 2)
        #expect(page.items.allSatisfy { $0.availability == .here })
        let kids = try #require(page.items.first { $0.title == "That Friday feeling" })
        #expect(kids.shelfLocation == "Natick - Children's" && kids.callNumber == "J/CHILDREN'S SONGS/Rymer/Compact Disc/Storyhour Shelf")
    }

    @Test func emptyResults() throws {
        let page = try CatalogParser.parseResults("<html><body><div>No Results Found</div></body></html>")
        #expect(page.total == 0 && page.items.isEmpty && !page.hasMore)
    }

    // MARK: AJAX replies

    @Test func copiesAcrossTheNetwork() throws {
        let copies = try CatalogParser.parseCopies(try TestSupport.fixture("minlib_copies_hamilton"))
        #expect(copies.count == 28)
        #expect(copies.first == CatalogCopy(library: "Natick", location: "Natick - Audiovisual", callNumber: "[CD] Musical/H217", available: 1, total: 1))
        let newton = try #require(copies.first { $0.library == "Newton" })
        #expect(newton.available == 4 && newton.total == 5 && newton.location == "Newton - Music")
        #expect(copies.first { $0.library == "Medford" }?.isAvailable == false)
        #expect(copies.contains { $0.library == "Concord Fowler" })
        #expect(throws: CatalogError.self) { try CatalogParser.parseCopies(Data(#"{"success":false,"error":"Missing recordId parameter"}"#.utf8)) }
    }

    @Test func editionsWithBarcodes() throws {
        let editions = try CatalogParser.parseEditions(try TestSupport.fixture("minlib_editions_hamilton"))
        #expect(editions.count == 2)
        #expect(editions[0].recordId == ".b34105876" && editions[0].year == 2015 && editions[0].publisher == "Atlantic Recording Company")
        #expect(editions[0].edition == "[Explicit version]" && editions[0].upc == "00075678668432" && editions[0].availability == .here)
        #expect(editions[1].upc == "075678664045" && editions[1].availability == .elsewhere)
    }

    @Test func libraries() throws {
        let libraries = try CatalogParser.parseLibraryFacet(try TestSupport.fixture("minlib_facet_owning"))
        #expect(libraries.count == 52)
        #expect(libraries.first == CatalogLibrary(name: "Natick", count: nil))
        #expect(libraries.contains(CatalogLibrary(name: "Cambridge O'Connell", count: 57)))
        #expect(libraries.first { $0.name == "Newton" }?.count == 14419)
    }

    @Test func workPage() throws {
        let work = try CatalogParser.parseWork(try TestSupport.html("minlib_work_hamilton"))
        #expect(work.upcs == ["00075678668432", "075678664045", "075678668432"])
        #expect(work.contributors.first == .init(name: "Cephas-Jones, Jasmine", role: "Performer"))
        #expect(work.subjects.first == "Founding Fathers of the United States")
        #expect(work.contents.count == 2 && work.contents[0].heading == "From the Music CD - [Explicit version]")
        #expect(work.contents[0].tracks.count == 46 && work.contents[0].tracks[1] == "Aaron Burr, sir")
    }

    @Test func signIn() throws {
        #expect(try CatalogParser.parseLogin(Data(#"{"result":{"success":true,"name":"Pat"}}"#.utf8)) == "Pat")
        #expect(throws: CatalogError.signIn("Sorry, that login information was not recognized, please try again.")) {
            try CatalogParser.parseLogin(Data(#"{"result":{"success":false,"message":"Sorry, that login information was not recognized, please try again."}}"#.utf8))
        }
        // Some server errors come back unwrapped.
        #expect(throws: CatalogError.signIn("Something broke")) {
            try CatalogParser.parseLogin(Data(#"{"success":false,"message":"Something broke"}"#.utf8))
        }
    }

    @Test func checkouts() throws {
        // The shape of My Account's checkout list (values made up; the id comes before the class).
        let html = """
        <div class="striped"><div id="record1" class="result row"><div class="col-xs-3"><a href="/Record/.b100?searchId=1"><img src="https://natick.minlib.net/bookcover.php?id=.b100&amp;size=small&amp;isn=1"></a></div>
        <div class="col-xs-9"><div class="row"><div class="col-xs-12"><span class="result-index">1)</span> <a href="/Record/.b100" class="result-title notranslate">Kind of blue</a></div></div>
        <div class="row"><div class="resultDetails col-xs-12">
        <div class="row"><div class="result-label col-md-5">Author</div><div class="col-md-7 result-value"><a href="/Author/Home?author=x">Davis, Miles</a></div></div>
        <div class="row"><div class="result-label col-md-5">Format</div><div class="col-md-7 result-value">Music CD</div></div>
        <div class="row"><div class="result-label col-md-5">Due</div><div class="col-md-7 result-value">Oct 20, 2026</div></div>
        <div class="row"><div class="result-label col-md-5">Renewed</div><div class="col-md-7 result-value">1 times</div></div>
        </div></div></div></div>
        <div class="result row"><div class="col-xs-9"><a href="/Record/.b200" class="result-title">Hooked: a novel</a>
        <div class="row"><div class="result-label">Format</div><div class="result-value">Book</div></div></div></div></div>
        """
        let json = try JSONSerialization.data(withJSONObject: ["success": true, "checkouts": html])
        let items = try CatalogParser.parseCheckouts(json)
        #expect(items.count == 2)
        #expect(items[0].title == "Kind of blue" && items[0].artist == "Miles Davis" && items[0].format == "Music CD")
        #expect(items[0].recordId == ".b100" && items[0].due == "Oct 20, 2026" && items[0].renewed == "1 times")
        #expect(items[0].coverPath == "/bookcover.php?id=.b100&size=small&isn=1")
        #expect(Calendar(identifier: .gregorian).component(.day, from: try #require(items[0].dueDate)) == 20)
        #expect(items[1].displayTitle == "Hooked: A Novel" && items[1].format == "Book")
        #expect(throws: CatalogError.notSignedIn) { try CatalogParser.parseCheckouts(Data(#"{"success":false,"message":"You must be logged in"}"#.utf8)) }
    }

    // MARK: Lists

    @Test func userLists() throws {
        let body = """
        <form><input type="hidden" name="sourceId" id="sourceId" value="lists"><div class="form-group">
        <label for="addToList-list">Choose a List</label>
        <select name="list" id="addToList-list" class="form-control"><option value="101">Music to borrow</option><option value="102">Books &amp; more</option></select>
        </div><textarea id="addToList-notes" name="notes"></textarea></form>
        """
        let data = try JSONSerialization.data(withJSONObject: ["title": "Add To List", "modalBody": body, "modalButtons": ""])
        #expect(try CatalogParser.parseUserLists(data) == [CatalogUserList(id: "101", title: "Music to borrow"), CatalogUserList(id: "102", title: "Books & more")])
        #expect(CatalogPaths.addToList(listId: "101", workId: "abc-eng") == "/MyAccount/AJAX?method=saveToList&notes=&listId=101&source=GroupedWork&sourceId=abc-eng")
        #expect(CatalogPaths.removeFromList(listId: "101", entryId: "9") == "/MyAccount/MyList/101?delete=9")
        #expect(try CatalogParser.parseSaveToList(Data(#"{"success":true,"message":"This title was saved to your list successfully."}"#.utf8)) == "This title was saved to your list successfully.")
        #expect(throws: CatalogError.self) { try CatalogParser.parseSaveToList(Data(#"{"success":false,"message":"Unable to find that list"}"#.utf8)) }
    }

    @Test func listPage() throws {
        // The shape of a list page (values made up): entries link to records; the work ID is in "Add to List".
        func entry(_ n: Int, entry: Int, work: String, title: String, author: String, status: String) -> String {
            """
            <div class="result"><div id="listEntry\(entry)" class="resultsList listEntry"><div class="row">
            <div class="selectTitle col-xs-12 col-sm-1"><input type="checkbox" id="selected\(entry)" class="titleSelect"></div>
            <div class="col-xs-3"><a href="/Record/.b\(n)00?searchId=5&amp;recordIndex=\(n)&amp;page="><img src="/bookcover.php?id=\(work)&amp;size=small" class="listResultImage"></a></div>
            <div class="col-xs-6"><div class="row"><div class="col-xs-12"><span class="result-index">\(n))</span> <a href="/Record/.b\(n)00?searchId=5" class="result-title notranslate">\(title)</a></div></div>
            <div class="row"><div class="result-label col-xs-3">Author</div><div class="result-value col-xs-9 notranslate"><a href="/Author/Home?author=x">\(author)</a></div></div>
            <div class="row"><div class="col-xs-12 formatDisplayVertical"><div class="related-manifestations"><div class="row related-manifestation grouped "><div class="col-xs-12"><div class="row">
            <div class="col-tn-4 manifestation-format"><a class="btn btn-xs btn-primary" href="/Record/.b\(n)00">Music CD</a><br><a href="#" onclick="return AspenDiscovery.ResultsList.showRelatedManifestations('\(work)','Music_CD', '77\(n)');"><span>Show Edition</span></a></div>
            <div class="col-tn-8"><div class="related-manifestation-shelf-status \(status) label">Status</div></div>
            </div></div></div></div></div></div>
            <div class="result-tools-horizontal"><a href="/Record/.b\(n)00?searchId=5" class="btn btn-sm btn-tools">More Info</a>
            <button onclick="return AspenDiscovery.Account.showSaveToListForm(this, 'GroupedWork', '\(work)');" class="btn btn-sm btn-tools">Add to List</button></div>
            </div>
            <div class="col-xs-2"><a href="#" onclick="return AspenDiscovery.Account.getEditListForm(\(entry),101,1)" class="btn btn-sm">Edit</a>
            <a href="#" onclick="AspenDiscovery.confirm('Delete Title ', 'Are you sure?', 'Yes', 'No', true, 'AspenDiscovery.Lists.deleteEntryFromList(101, \(entry))');" class="btn btn-sm btn-danger">Delete</a></div>
            </div></div></div>
            """
        }
        let html = """
        <html><body><div class="resultHead">Showing 1 - 2 of 2 (2 total entries)</div><div id="UserList">
        \(entry(1, entry: 9001, work: "d0797869-8043-715e-f883-2100b5c2cd80-eng", title: "Hamilton: original Broadway cast recording", author: "Miranda, Lin-Manuel, 1980-", status: "status-on-shelf"))
        \(entry(2, entry: 9002, work: "101115d3-1111-c274-3bd5-fe16b40c1524-eng", title: "The dark side of the moon", author: "Pink Floyd (Musical group)", status: "status-checked-out"))
        </div></body></html>
        """
        let page = try CatalogParser.parseList(html)
        #expect(page.total == 2 && page.entries.count == 2)
        let first = page.entries[0]
        #expect(first.entryId == "9001" && first.item.id == "d0797869-8043-715e-f883-2100b5c2cd80-eng")
        #expect(first.item.displayTitle == "Hamilton: Original Broadway Cast Recording" && first.item.artist == "Lin-Manuel Miranda")
        #expect(first.item.availability == .here && first.item.variationId == "771" && first.item.recordId == ".b100")
        #expect(page.entries[1].item.artist == "Pink Floyd" && page.entries[1].item.availability == .unavailable)
        #expect(try CatalogParser.parseList("<html><body>This list is empty.</body></html>").entries.isEmpty)
    }

    // MARK: Text

    @Test func names() {
        #expect(CatalogText.displayName("Miranda, Lin-Manuel, 1980-") == "Lin-Manuel Miranda")
        #expect(CatalogText.displayName("Osbourne, Ozzy, 1948-2025") == "Ozzy Osbourne")
        #expect(CatalogText.displayName("Bach, Johann Sebastian, 1685-1750") == "Johann Sebastian Bach")
        #expect(CatalogText.displayName("Baldwin, Bob (Keyboard player)") == "Bob Baldwin")
        #expect(CatalogText.displayName("Dropkick Murphys (Musical group)") == "Dropkick Murphys")
        #expect(CatalogText.displayName("Earth, Wind & Fire (Musical group)") == "Earth, Wind & Fire")
        #expect(CatalogText.displayName("Beyoncé, 1981-") == "Beyoncé")
        #expect(CatalogText.displayName("Beatles") == "Beatles")
    }

    @Test func titles() {
        #expect(CatalogText.titleCase("sgt. pepper's lonely hearts club band") == "Sgt. Pepper's Lonely Hearts Club Band")
        #expect(CatalogText.titleCase("the dark side of the moon") == "The Dark Side of the Moon")
        #expect(CatalogText.titleCase("NOW that's what I call music") == "NOW That's What I Call Music")
        #expect(CatalogText.key("The Beatles & Friends: Live!") == "beatles and friends live")
        #expect(CatalogText.key("Lin‐Manuel Miranda") == CatalogText.key("Lin-Manuel Miranda"))
        #expect(CatalogText.barcodeVariants("00075678668432") == ["075678668432", "0075678668432"])
        #expect(CatalogText.barcodeVariants("5099902987422") == ["5099902987422"])
        #expect(CatalogText.year("p2015, c2016") == 2015 && CatalogText.year("[2025]") == 2025 && CatalogText.year("n.d.") == nil)
    }

    // MARK: Ownership

    private func album(_ title: String, _ artist: String) -> AlbumSummary {
        AlbumSummary(album: title, artist: artist, year: nil, trackCount: 10, firstTrackPath: "")
    }

    @Test func ownership() {
        let pepper = album("Sgt. Pepper’s Lonely Hearts Club Band (Remastered)", "The Beatles")
        let anthology1 = album("Anthology 1", "The Beatles")
        let anthology = album("Anthology", "The Beatles")
        let dsotm = album("The Dark Side of the Moon", "Pink Floyd")
        let hamilton = album("Hamilton: An American Musical", "Lin‐Manuel Miranda")
        let now = album("Now That's What I Call Music! 10", "Various Artists")
        let owned = CatalogOwnership(albums: [pepper, anthology1, anthology, dsotm, hamilton, now],
                                     releaseGroups: ["4c615b1c-5af9-432b-9342-e39137ade143": hamilton])

        let sgt = CatalogItem(id: "1", title: "Sgt. Pepper's lonely hearts club band", author: "Beatles")
        #expect(owned.album(for: sgt) == pepper)
        // The volume is part of the title.
        let four = CatalogItem(id: "2", title: "Anthology", subtitle: "4", author: "Beatles")
        #expect(owned.album(for: four) == nil)
        // A different artist with the same album title doesn't count.
        let cover = CatalogItem(id: "3", title: "The dark side of the moon", author: "Easy Star All-Stars (Musical group)")
        #expect(owned.album(for: cover) == nil)
        #expect(owned.album(for: CatalogItem(id: "4", title: "The dark side of the moon", author: "Pink Floyd (Musical group)")) == dsotm)
        // Catalog and tags name Hamilton differently: the main title and artist still agree…
        let cast = CatalogItem(id: "5", title: "Hamilton", subtitle: "original Broadway cast recording", author: "Miranda, Lin-Manuel, 1980-")
        #expect(owned.album(for: cast) == hamilton)
        // …and when they don't, the MusicBrainz release group links them.
        let renamed = CatalogItem(id: "5", title: "Original Broadway cast recording of Hamilton", author: "Miranda, Lin-Manuel, 1980-")
        #expect(owned.album(for: renamed) == nil)
        var details = CatalogAlbumDetails(workId: "5")
        details.releaseGroupId = "4c615b1c-5af9-432b-9342-e39137ade143"
        #expect(owned.album(for: renamed, details: details) == hamilton)
        // Without an artist, only an exact title counts.
        #expect(owned.album(for: CatalogItem(id: "6", title: "Now that's what I call music!", subtitle: "10")) == now)
        #expect(owned.album(for: CatalogItem(id: "7", title: "Anthology", subtitle: "the best of")) == nil)
        let checkout = CatalogCheckout(title: "Anthology", author: "Beatles")
        #expect(owned.album(for: checkout) == anthology)
    }

    // MARK: MusicBrainz

    @Test func barcodeMatch() throws {
        let releases = try MusicBrainzParser.parseReleaseList(try TestSupport.fixture("mb_barcode_hamilton"))
        #expect(releases.count == 2 && releases.allSatisfy(\.isCD))
        #expect(releases[0].releaseGroupId == "4c615b1c-5af9-432b-9342-e39137ade143" && releases[0].label == "Atlantic")
        #expect(releases[0].trackCount == 46 && releases[0].mediaLabel == "2×CD")
        #expect(MusicBrainzParser.bestRelease(releases, year: 2015)?.id == "2eece058-39a8-4dd7-af54-b94ae39ec7fa")
        #expect(MusicBrainzParser.bestRelease(releases, year: 2016)?.date == "2016-01-29")
        #expect(MusicBrainzParser.bestRelease(releases, year: nil)?.date == "2015-10-16")
    }

    @Test func detailsRoundTripThroughTheDatabase() throws {
        let dir = try TestSupport.tempDir()
        let db = try Database(path: dir.appendingPathComponent("library.sqlite").path)
        var details = CatalogAlbumDetails(workId: "w1", fetchedAt: Date(timeIntervalSince1970: 1_000))
        details.releaseId = "r1"
        details.album = AlbumInfo(title: "Hamilton")
        details.editions = try CatalogParser.parseEditions(try TestSupport.fixture("minlib_editions_hamilton"))
        try db.saveCatalogDetails(details)
        #expect(try db.catalogDetails()["w1"] == details)
    }
}
