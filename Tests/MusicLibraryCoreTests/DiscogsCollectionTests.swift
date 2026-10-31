import Foundation
import Testing
@testable import MusicLibraryCore

/// A Discogs account from fixtures (`discogs_identity`, `discogs_folders`, `discogs_collection_page1`/`2`: written
/// from Discogs' documented schemas, not captured), recording every request; adds return instances from 2,000,000 up.
final class DiscogsAccountStub: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var nextInstance = 2_000_000
    /// Status codes for paths ("POST /users/example_user/…"), instead of the usual answer.
    var failures: [String: Int] = [:]

    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var calls: [String] { all.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

    var transport: DiscogsCollectionClient.Transport {
        { [self] request in try self.answer(request) }
    }

    func client() -> DiscogsCollectionClient {
        DiscogsCollectionClient(token: String(repeating: "a", count: 40), transport: transport)
    }

    private func answer(_ request: URLRequest) throws -> (Data, Int) {
        lock.lock()
        requests.append(request)
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let key = "\(method) \(url.path)"
        if let code = failures[key] { lock.unlock(); return (Data(), code) }
        defer { lock.unlock() }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        switch (method, url.path) {
        case ("GET", "/oauth/identity"): return (try TestSupport.fixture("discogs_identity"), 200)
        case ("GET", "/users/example_user/collection/folders"): return (try TestSupport.fixture("discogs_folders"), 200)
        case ("GET", "/users/example_user/collection/folders/0/releases"):
            return (try TestSupport.fixture(page == "2" ? "discogs_collection_page2" : "discogs_collection_page1"), 200)
        case ("GET", "/database/search"): return (try TestSupport.fixture("discogs_search_barcode_astley"), 200)
        case ("POST", let p) where p.hasPrefix("/users/example_user/collection/folders/"):
            nextInstance += 1
            return (Data(#"{"instance_id": \#(nextInstance), "resource_url": "https://api.discogs.com/x"}"#.utf8), 201)
        case ("DELETE", let p) where p.hasPrefix("/users/example_user/collection/folders/"): return (Data(), 204)
        default: return (Data(), 404)
        }
    }
}

@Suite struct DiscogsCollectionTests {
    func item(_ id: String, _ medium: CollectionMedium = .cd, album: String, discogs: Int? = nil, release: String? = nil,
              barcode: String? = nil, catno: String? = nil) -> CollectionItem {
        var i = CollectionItem(id: id, medium: medium, album: album, artist: "Artist", now: Date(timeIntervalSince1970: 0))
        i.discogsReleaseID = discogs
        i.releaseID = release
        i.barcode = barcode
        i.catalogNumber = catno
        return i
    }

    func instance(_ id: Int, release: Int, folder: Int = 1) -> DiscogsInstance {
        DiscogsInstance(instanceID: id, releaseID: release, folderID: folder, title: "Release \(release)")
    }

    // MARK: Tokens and names

    @Test func tokensAreLettersAndDigits() {
        #expect(DiscogsToken.cleaned("  " + String(repeating: "aB3", count: 13) + "x\n") == String(repeating: "aB3", count: 13) + "x")
        #expect(DiscogsToken.cleaned(String(repeating: "a", count: 39) + "\r\nX-Evil: 1") == nil)
        #expect(DiscogsToken.cleaned("short") == nil)
        #expect(DiscogsToken.cleaned(String(repeating: "é", count: 40)) == nil)
    }

    @Test func usernamesGoInPathsOnlyWhenPlain() {
        #expect(DiscogsIdentity.isValidUsername("example_user"))
        #expect(DiscogsIdentity.isValidUsername("dj.k-9"))
        #expect(!DiscogsIdentity.isValidUsername("../releases"))
        #expect(!DiscogsIdentity.isValidUsername(".."))
        #expect(!DiscogsIdentity.isValidUsername("a b"))
        #expect(!DiscogsIdentity.isValidUsername(""))
        #expect(throws: DiscogsError.badResponse) { try DiscogsCollectionClient.user("a/b") }
    }

    // MARK: Parsing

    @Test func collectionPage() throws {
        let (instances, pages) = try DiscogsCollectionParser.page(try TestSupport.fixture("discogs_collection_page1"))
        #expect(pages == 2)
        #expect(instances.count == 2)
        let blue = instances[0]
        #expect(blue.instanceID == 1450001 && blue.releaseID == 2772432 && blue.folderID == 4183920)
        #expect(blue.title == "Kind Of Blue" && blue.artist == "Miles Davis" && blue.year == 1959)
        #expect(blue.medium == .vinyl && blue.catalogNumber == "CL 1355")
        #expect(blue.dateAdded == ISO8601DateFormatter().date(from: "2024-03-02T17:15:00Z"))
        let wall = instances[1]
        #expect(wall.medium == .cd && wall.formatDetail.contains("CD") && wall.catalogNumber == "C2K 68519")
        // A release without an id is left out.
        let (second, _) = try DiscogsCollectionParser.page(try TestSupport.fixture("discogs_collection_page2"))
        #expect(second.map(\.releaseID) == [249504])
    }

    @Test func identityAndFolders() throws {
        #expect(try DiscogsCollectionParser.identity(try TestSupport.fixture("discogs_identity")) == DiscogsIdentity(id: 1578108, username: "example_user"))
        let folders = try DiscogsCollectionParser.folders(try TestSupport.fixture("discogs_folders"))
        #expect(folders.map(\.id) == [0, 1, 4183920])
        #expect(folders[2].name == "Records" && folders[2].count == 1)
        #expect(throws: DiscogsError.badResponse) {
            try DiscogsCollectionParser.identity(Data(#"{"id": 1, "username": "../x"}"#.utf8))
        }
    }

    // MARK: Client

    @Test func clientSendsTheTokenAndReadsEveryPage() async throws {
        let stub = DiscogsAccountStub()
        let client = stub.client()
        #expect(try await client.identity().username == "example_user")
        let pages = Counter()
        let all = try await client.collection(username: "example_user") { read, of in pages.add(read * 10 + of) }
        #expect(all.map(\.instanceID) == [1450001, 1450002, 1450003])
        #expect(pages.values == [12, 22])
        let first = try #require(stub.all.first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Discogs token=" + String(repeating: "a", count: 40))
        #expect(first.value(forHTTPHeaderField: "User-Agent") == AppInfo.userAgent)
        let query = stub.all[1].url!.query ?? ""
        #expect(query.contains("per_page=100") && query.contains("sort=added"))
    }

    @Test func clientAddsAndRemovesCopies() async throws {
        let stub = DiscogsAccountStub()
        let client = stub.client()
        let id = try await client.add(releaseID: 2772432, folderID: 1, username: "example_user")
        #expect(id == 2_000_001)
        try await client.remove(instance(1450001, release: 2772432, folder: 4183920), username: "example_user")
        // A copy in "All" (0) is removed from Uncategorized.
        try await client.remove(instance(7, release: 3, folder: 0), username: "example_user")
        #expect(stub.calls == [
            "POST /users/example_user/collection/folders/1/releases/2772432",
            "DELETE /users/example_user/collection/folders/4183920/releases/2772432/instances/1450001",
            "DELETE /users/example_user/collection/folders/1/releases/3/instances/7",
        ])
        await #expect(throws: DiscogsError.badResponse) { try await client.add(releaseID: 1, folderID: 0, username: "example_user") }
    }

    @Test func clientErrors() async throws {
        let stub = DiscogsAccountStub()
        stub.failures = ["GET /oauth/identity": 401, "DELETE /users/example_user/collection/folders/1/releases/5/instances/6": 404,
                         "POST /users/example_user/collection/folders/1/releases/9": 429]
        let client = stub.client()
        await #expect(throws: DiscogsError.unauthorized) { try await client.identity() }
        // Already gone counts as removed.
        try await client.remove(instance(6, release: 5), username: "example_user")
        await #expect(throws: DiscogsError.busy) { try await client.add(releaseID: 9, folderID: 1, username: "example_user") }
    }

    // MARK: Matching

    @Test func knownReleases() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        var cd = item("a", album: "A", release: "f5093c06-23e3-404f-aeaa-40f72885ee3a")
        #expect(DiscogsReleaseMatcher.known(cd, row: nil, now: now) == .none)
        let basis = DiscogsReleaseMatcher.basis(of: cd)
        let found = DiscogsSyncRow(itemID: "a", basis: basis, releaseID: 42, checkedAt: .distantPast, quality: .closest)
        #expect(DiscogsReleaseMatcher.known(cd, row: found, now: now) == .release(42, .closest))
        // The first matcher's matches were exact.
        let first = DiscogsSyncRow(itemID: "a", basis: basis, releaseID: 42, checkedAt: .distantPast, matcher: 1)
        #expect(DiscogsReleaseMatcher.known(cd, row: first, now: now) == .release(42, .exact))
        let recent = DiscogsSyncRow(itemID: "a", basis: basis, releaseID: nil, checkedAt: now.addingTimeInterval(-3600))
        #expect(DiscogsReleaseMatcher.known(cd, row: recent, now: now) == .noMatch)
        let stale = DiscogsSyncRow(itemID: "a", basis: basis, releaseID: nil, checkedAt: now.addingTimeInterval(-31 * 24 * 3600))
        #expect(DiscogsReleaseMatcher.known(cd, row: stale, now: now) == .none)
        // What an older matcher didn't find is looked up again.
        let older = DiscogsSyncRow(itemID: "a", basis: basis, releaseID: nil, checkedAt: now.addingTimeInterval(-3600), matcher: 1)
        #expect(DiscogsReleaseMatcher.known(cd, row: older, now: now) == .none)
        // A new edition is matched again.
        cd.barcode = "074646851925"
        #expect(DiscogsReleaseMatcher.known(cd, row: found, now: now) == .none)
        // Its own Discogs edition needs no lookup.
        cd.discogsReleaseID = 7
        #expect(DiscogsReleaseMatcher.known(cd, row: found, now: now) == .release(7, .exact))
    }

    /// The facts of the Canadian CD of Céline Dion (1992), as MusicBrainz gives them (real responses).
    func celineDion() throws -> DiscogsEditionFacts {
        var mb = try MusicBrainzEditionFacts.parse(try TestSupport.fixture("mb_release_celinedion"))
        #expect(mb.barcode == "074645247328" && mb.catalogNumbers == ["CK 52473"] && mb.country == "CA" && mb.year == 1992)
        #expect(mb.links.discogsRelease == nil && mb.releaseGroupID != nil)
        mb.links.discogsMaster = try CDShopLinks.parse(try TestSupport.fixture("mb_releasegroup_celinedion")).discogsMaster
        #expect(mb.links.discogsMaster == 90727)
        // The item itself has only what it was added with.
        var facts = DiscogsEditionFacts(item: item("c", album: "Céline Dion"))
        facts.add(mb)
        return facts
    }

    @Test func barcodeAndCatalogNumberFindTheEdition() throws {
        let facts = try celineDion()
        let results = try DiscogsParser.parseSearch(try TestSupport.fixture("discogs_search_barcode_celinedion")).compactMap(DiscogsCandidate.init)
        #expect(results.count == 14)
        // Canada, CK 52473, 1992, not a repress: the original, though 14 pressings share the barcode.
        #expect(DiscogsReleaseMatcher.best(results, for: facts, byBarcode: true) == DiscogsMatch(releaseID: 10507602, quality: .exact))
        // Without the country and year, the barcode and catalog number still say which edition.
        var less = facts
        less.country = nil
        less.year = nil
        #expect(DiscogsReleaseMatcher.best(results, for: less, byBarcode: true)?.quality == .exact)
    }

    @Test func mastersVersionsFindAPressing() throws {
        let (versions, pages) = try DiscogsCollectionParser.versions(try TestSupport.fixture("discogs_versions_90727"))
        #expect(pages == 1 && versions.count == 60)
        let canada = try #require(versions.first { $0.releaseID == 10507602 })
        #expect(canada.country == "Canada" && canada.catalogNumbers == ["CK 52473"] && canada.year == 1992 && canada.medium == .cd)
        var facts = try celineDion()
        facts.barcode = nil
        #expect(DiscogsReleaseMatcher.best(versions, for: facts) == DiscogsMatch(releaseID: 10507602, quality: .edition))
        // Only the album known: the plainest, oldest pressing, as the closest.
        var album = DiscogsEditionFacts(item: item("c", album: "Céline Dion"))
        album.country = "GB"
        let uk = try #require(DiscogsReleaseMatcher.best(versions, for: album))
        #expect(uk.quality == .closest && versions.first { $0.releaseID == uk.releaseID }?.country == "UK")
        // Never another medium's.
        #expect(DiscogsReleaseMatcher.best(versions, for: DiscogsEditionFacts(item: item("v", .vinyl, album: "Céline Dion"))) == nil)
    }

    @Test func catalogNumbersAndCountries() {
        #expect(DiscogsReleaseMatcher.sharesCatalogNumber(DiscogsReleaseMatcher.normalized("539 786-2"), DiscogsReleaseMatcher.normalized("314 539 786-2")))
        #expect(!DiscogsReleaseMatcher.sharesCatalogNumber("1234", "912345"))
        #expect(DiscogsReleaseMatcher.discogsCountries("CA") == ["canada"])
        #expect(DiscogsReleaseMatcher.discogsCountries("GB") == ["uk"])
        #expect(DiscogsReleaseMatcher.discogsCountries("US") == ["us"])
        #expect(DiscogsReleaseMatcher.discogsCountries("XE") == ["europe"])
        #expect(DiscogsReleaseMatcher.discogsCountries("ZA") == ["south africa"])
        #expect(DiscogsReleaseMatcher.discogsCountries("Germany") == ["germany"])
        #expect(DiscogsReleaseMatcher.barcodeDigits("0731453978621") == DiscogsReleaseMatcher.barcodeDigits("731453978621"))
        // "UK & Europe" is both.
        let facts = { (country: String) -> DiscogsEditionFacts in
            var f = DiscogsEditionFacts(item: self.item("a", album: "A"))
            f.country = country
            return f
        }
        let candidates = [DiscogsCandidate(releaseID: 1, medium: .cd, country: "US"), DiscogsCandidate(releaseID: 2, medium: .cd, country: "UK & Europe")]
        #expect(DiscogsReleaseMatcher.best(candidates, for: facts("GB"))?.releaseID == 2)
        #expect(DiscogsReleaseMatcher.best(candidates, for: facts("US"))?.releaseID == 1)
        // The album's own title beats one that only holds its words.
        var domingo = DiscogsEditionFacts(item: item("p", album: "Popular Favorites"))
        domingo.country = "US"
        let titled = [DiscogsCandidate(releaseID: 8953371, title: "Tenors On Tour (Popular Favorites By The World's Greatest Tenors)", medium: .cd, country: "US"),
                      DiscogsCandidate(releaseID: 35639503, title: "Popular Favorites", medium: .cd, country: "US")]
        #expect(DiscogsReleaseMatcher.best(titled, for: domingo)?.releaseID == 35639503)
    }

    @Test func sameAlbumNames() {
        #expect(DiscogsReleaseMatcher.isSameAlbum("Celine Dion", "Céline Dion"))
        #expect(DiscogsReleaseMatcher.isSameAlbum("...Nothing Like The Sun", "…Nothing Like the Sun"))
        #expect(DiscogsReleaseMatcher.isSameAlbum("Chronicle: The 20 Greatest Hits", "Chronicle"))
        #expect(!DiscogsReleaseMatcher.isSameAlbum("Chronicle Volume Two", "Chronicles"))
        #expect(!DiscogsReleaseMatcher.isSameAlbum("Breathe", "Breathless"))
        #expect(DiscogsReleaseMatcher.isSameAlbum("The Best Of The Decca Years, Vol. One - The Singer", "The Best of the Decca Years, Volume 1: The Singer"))
        #expect(DiscogsReleaseMatcher.isSameAlbum("The Traveling Wilburys Vol. 3", "Traveling Wilburys, Vol. 3"))
        #expect(!DiscogsReleaseMatcher.isSameAlbum("The Traveling Wilburys Vol. 1", "Traveling Wilburys, Vol. 3"))
        #expect(!DiscogsReleaseMatcher.isSameAlbum("Greatest Hits Volume 2", "Greatest Hits"))
        #expect(!DiscogsReleaseMatcher.isSameAlbum("Untitled", "Unplugged"))
    }

    @Test func lookupOrder() async throws {
        let calls = Log()
        let master: @Sendable (String) -> MusicBrainzEditionFacts = { mb in
            var f = MusicBrainzEditionFacts()
            if mb == "f5093c06-23e3-404f-aeaa-40f72885ee3a" { f.links.discogsRelease = 111 }
            if mb == "0383dadf-2a4e-4d10-a46a-e9e041da8eb3" { f.links.discogsMaster = 900; f.catalogNumbers = ["ABC 1"] }
            return f
        }
        let lookup = DiscogsReleaseLookup(
            musicBrainz: { id, _ in calls.add("mb"); return master(id) },
            barcode: { _, _ in calls.add("barcode"); return [] },
            versions: { _, _ in calls.add("versions"); return [DiscogsCandidate(releaseID: 5, medium: .cd, catalogNumbers: ["ABC-1"])] },
            search: { params, _ in
                calls.add(params.keys.sorted().joined(separator: "+"))
                var other = CollectionEdition(id: "discogs-7", title: "Another Album", artist: "Artist", medium: .cd)
                other.discogsReleaseID = 7
                var same = CollectionEdition(id: "discogs-8", title: "Album Name", artist: "Artist", medium: .cd)
                same.discogsReleaseID = 8
                same.catalogNumber = params["catno"] ?? ""
                return [other, same]
            })
        // A release link: exact, nothing else asked.
        #expect(try await lookup.match(for: item("a", album: "A", release: "f5093c06-23e3-404f-aeaa-40f72885ee3a"))
                == DiscogsMatch(releaseID: 111, quality: .exact))
        #expect(calls.values == ["mb"])
        // A master: its versions, by MusicBrainz's catalog number.
        #expect(try await lookup.match(for: item("b", album: "B", release: "0383dadf-2a4e-4d10-a46a-e9e041da8eb3"))
                == DiscogsMatch(releaseID: 5, quality: .edition))
        #expect(calls.values == ["mb", "mb", "versions"])
        // Nothing on MusicBrainz: a catalog number search, keeping only releases named like the album.
        #expect(try await lookup.match(for: item("c", album: "Album Name", catno: "X 1")) == DiscogsMatch(releaseID: 8, quality: .edition))
        #expect(calls.values.last == "catno")
        // Then artist and title.
        #expect(try await lookup.match(for: item("d", album: "Album Name")) == DiscogsMatch(releaseID: 8, quality: .closest))
        #expect(calls.values.last == "artist+release_title")
        #expect(try await lookup.match(for: item("e", album: "Unknown")) == nil)
        // A barcode search's results must be named like the album too: Discogs returns near-misses.
        let near = DiscogsReleaseLookup(
            musicBrainz: { _, _ in MusicBrainzEditionFacts() },
            barcode: { _, _ in
                var other = CollectionEdition(id: "discogs-9", title: "Untitled", artist: "The Rembrandts", medium: .cd)
                other.discogsReleaseID = 9
                return [other]
            },
            versions: { _, _ in [] }, search: { _, _ in [] })
        #expect(try await near.match(for: item("g", album: "Unplugged", barcode: "020831446129")) == nil)
        #expect(try await lookup.match(for: item("f", album: "F", discogs: 5)) == DiscogsMatch(releaseID: 5, quality: .exact))
    }

    // MARK: Plan

    @Test func firstSyncAdoptsWhatsThereAndAddsTheRest() {
        let items = [item("a", album: "A"), item("b", album: "B"), item("b2", album: "B"), item("u", album: "Unmatched"),
                     item("d", .download, album: "D")]
        let releases = ["a": 10, "b": 20, "b2": 20, "d": 40]
        let remote = [instance(1, release: 20), instance(2, release: 99)]
        let plan = DiscogsSyncPlan.make(items: items, releases: releases, links: [:], remote: remote)
        #expect(plan.adoptions.map(\.itemID) == ["b"])
        #expect(plan.additions.map(\.id) == ["a", "b2"])
        #expect(plan.additions.allSatisfy { $0.reason == .new })
        #expect(plan.removals.map(\.id) == [2] && plan.removals[0].reason == .onlyOnDiscogs)
        #expect(plan.unmatched.map(\.id) == ["u"])
        #expect(plan.inSync == 0)
    }

    @Test func laterSyncs() {
        let link = { (i: Int, r: Int) in DiscogsSyncRow.Link(instanceID: i, releaseID: r) }
        let items = [item("same", album: "Same"), item("gone", album: "Gone There"), item("moved", album: "Moved"),
                     item("lost", album: "Lost Match"), item("fixed", album: "Fixed There")]
        let releases = ["same": 1, "gone": 2, "moved": 30, "fixed": 50]
        let links = ["same": link(11, 1), "gone": link(12, 2), "moved": link(13, 3), "lost": link(14, 4),
                     "fixed": link(15, 5), "deleted": link(16, 6)]
        let remote = [instance(11, release: 1), instance(13, release: 3), instance(14, release: 4), instance(15, release: 5),
                      instance(16, release: 6), instance(17, release: 50)]
        let plan = DiscogsSyncPlan.make(items: items, releases: releases, links: links, remote: remote)
        // "lost" keeps its copy though no release is matched now.
        #expect(plan.inSync == 2)
        #expect(plan.additions.map { "\($0.id) \($0.releaseID)" } == ["gone 2", "moved 30"])
        #expect(plan.additions[0].reason == .removedOnDiscogs && plan.additions[1].reason == .editionChanged)
        // A copy of the new edition already there is taken instead of adding one.
        #expect(plan.adoptions.map { "\($0.itemID) \($0.instance.instanceID)" } == ["fixed 17"])
        #expect(plan.removals.map(\.id) == [13, 15, 16])
        #expect(plan.removals.map(\.reason) == [.editionChanged(itemID: "moved"), .editionChanged(itemID: "fixed"), .removedHere])
        #expect(plan.unmatched.isEmpty)
    }

    @Test func emptyPlanWhenInSync() {
        let plan = DiscogsSyncPlan.make(items: [item("a", album: "A")], releases: ["a": 1],
                                        links: ["a": .init(instanceID: 9, releaseID: 1)], remote: [instance(9, release: 1)])
        #expect(plan.isEmpty && plan.inSync == 1)
    }

    // MARK: Saved links and running

    @Test func rowsRoundTripAndAreUntrusted() throws {
        let lib = try TestSupport.makeLibrary()
        let db = lib.db
        try db.saveDiscogsMatches([DiscogsSyncRow(itemID: "a", basis: "cd|x", releaseID: 5, checkedAt: Date(timeIntervalSince1970: 10)),
                                   DiscogsSyncRow(itemID: "b", basis: "cd|y", releaseID: nil, checkedAt: Date(timeIntervalSince1970: 20))])
        try db.linkDiscogsInstance(itemID: "a", username: "example_user", instance: instance(77, release: 5, folder: 3))
        // Matching again keeps the link.
        try db.saveDiscogsMatches([DiscogsSyncRow(itemID: "a", basis: "cd|z", releaseID: 6, checkedAt: Date(timeIntervalSince1970: 30))])
        try db.exec("INSERT INTO discogs_sync(item_id,basis,release_id,checked_at,username,instance_id,instance_release_id) VALUES('BAD/ID','',1,0,NULL,NULL,NULL)")
        try db.exec("INSERT INTO discogs_sync(item_id,basis,release_id,checked_at,username,instance_id,instance_release_id) VALUES('c','',-4,0,'../x',5,5)")
        let rows = try db.discogsSyncRows()
        #expect(Set(rows.keys) == ["a", "b", "c"])
        let a = try #require(rows["a"])
        #expect(a.basis == "cd|z" && a.releaseID == 6 && a.folderID == 3)
        #expect(a.link(for: "Example_User") == .init(instanceID: 77, releaseID: 5))
        #expect(a.link(for: "someone_else") == nil)
        #expect(rows["b"]?.releaseID == nil && rows["b"]?.checkedAt == Date(timeIntervalSince1970: 20))
        #expect(rows["c"]?.releaseID == nil && rows["c"]?.instanceID == nil)
        // Unlinking forgets the copy; unlinked rows of items no longer here go.
        try db.unlinkDiscogsInstance(77, username: "example_user")
        #expect(try Set(db.discogsSyncRows().keys) == ["c"])
    }

    @Test func runAddsLinksAndRemoves() async throws {
        let lib = try TestSupport.makeLibrary()
        let db = lib.db
        let a = item("a", album: "A"), b = item("b", album: "B"), c = item("c", album: "C")
        try db.saveCollectionItems([a, b, c])
        try db.linkDiscogsInstance(itemID: "gone", username: "example_user", instance: instance(50, release: 9))
        let plan = DiscogsSyncPlan.make(items: [a, b, c], releases: ["a": 1, "b": 2, "c": 3],
                                        links: ["gone": .init(instanceID: 50, releaseID: 9)],
                                        remote: [instance(40, release: 3), instance(50, release: 9), instance(60, release: 8)])
        let stub = DiscogsAccountStub()
        stub.failures = ["POST /users/example_user/collection/folders/4183920/releases/2": 404]
        let outcome = try await DiscogsSync.run(plan, additions: plan.additions, removals: plan.removals.filter { $0.id == 50 },
                                                client: stub.client(), username: "example_user", folderID: 4183920, database: db)
        #expect(outcome.added == 1 && outcome.linked == 1 && outcome.removed == 1)
        #expect(outcome.failures == ["B: Discogs answered with an error (HTTP 404)."])
        #expect(stub.calls == [
            "POST /users/example_user/collection/folders/4183920/releases/1",
            "POST /users/example_user/collection/folders/4183920/releases/2",
            "DELETE /users/example_user/collection/folders/1/releases/9/instances/50",
        ])
        let rows = try db.discogsSyncRows()
        #expect(rows["a"]?.link(for: "example_user") == .init(instanceID: 2_000_001, releaseID: 1))
        #expect(rows["a"]?.folderID == 4183920)
        #expect(rows["c"]?.link(for: "example_user") == .init(instanceID: 40, releaseID: 3))
        #expect(rows["b"] == nil && rows["gone"] == nil)
        // Planned again, only what was left is offered.
        let links = rows.compactMapValues { $0.link(for: "example_user") }
        let again = DiscogsSyncPlan.make(items: [a, b, c], releases: ["a": 1, "b": 2, "c": 3], links: links,
                                         remote: [instance(40, release: 3), instance(60, release: 8), instance(2_000_001, release: 1, folder: 4183920)])
        #expect(again.additions.map(\.id) == ["b"] && again.removals.map(\.id) == [60] && again.inSync == 2)
    }

    @Test func runStopsOnARefusedToken() async throws {
        let lib = try TestSupport.makeLibrary()
        let a = item("a", album: "A"), b = item("b", album: "B")
        let plan = DiscogsSyncPlan.make(items: [a, b], releases: ["a": 1, "b": 2], links: [:], remote: [])
        let stub = DiscogsAccountStub()
        stub.failures = ["POST /users/example_user/collection/folders/1/releases/1": 401]
        await #expect(throws: DiscogsError.unauthorized) {
            _ = try await DiscogsSync.run(plan, additions: plan.additions, removals: [], client: stub.client(),
                                          username: "example_user", folderID: 1, database: lib.db)
        }
        #expect(stub.calls.count == 1)
    }

    @Test func phoneSnapshotsLeaveTheLinksOut() throws {
        let lib = try TestSupport.makeLibrary()
        try lib.db.linkDiscogsInstance(itemID: "a", username: "example_user", instance: instance(1, release: 1))
        let dir = try TestSupport.tempDir()
        let target = dir.appendingPathComponent("snapshot.sqlite")
        try lib.db.writeSyncSnapshot(to: target, scratch: dir.appendingPathComponent("scratch"))
        let copy = try Database(path: target.path)
        #expect(try copy.discogsSyncRows().isEmpty)
    }
}

/// Strings reported from `@Sendable` closures.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ v: String) { lock.lock(); list.append(v); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

/// Values reported from `@Sendable` closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    func add(_ v: Int) { lock.lock(); list.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return list }
}
