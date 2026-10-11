import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct ConcertTests {
    static let radiohead = "a74b1b7f-71a5-4011-9441-d0b5e4122711"
    /// Cambridge, MA (02139).
    static let home = GeoPoint(latitude: 42.3645, longitude: -71.1027)!
    static let now = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!

    static func day(_ s: String) -> PurchaseDay { PurchaseDay(string: s)! }

    // MARK: Places

    @Test func geohashAndDistance() {
        // The classic example from geohash.org.
        #expect(GeoPoint(latitude: 57.64911, longitude: 10.40744)!.geohash(precision: 11) == "u4pruydqqvj")
        #expect(Self.home.geohash().count == 9 && Self.home.geohash().hasPrefix("drt"))
        let tdGarden = GeoPoint(latitude: 42.366119, longitude: -71.06213)!
        #expect(abs(Self.home.kilometers(to: tdGarden) - 3.3) < 0.2)
        #expect(GeoPoint(latitude: 91, longitude: 0) == nil && GeoPoint(latitude: .nan, longitude: 0) == nil)
    }

    @Test func postalCodes() {
        #expect(PostalCode.normalized(" 02139 ", country: "US") == "02139")
        #expect(PostalCode.normalized("02139-4307", country: "US") == "02139")
        #expect(PostalCode.normalized("2139", country: "US") == nil)
        #expect(PostalCode.normalized("O2139", country: "US") == nil)
        #expect(PostalCode.normalized("", country: "US") == nil)
        #expect(PostalCode.normalized("sw1a   1aa", country: "GB") == "SW1A 1AA")
        #expect(PostalCode.normalized("10115; DROP", country: "DE") == nil)
    }

    @Test func distanceUnits() {
        #expect(DistanceUnit.preferred(locale: Locale(identifier: "en_US")) == .miles)
        #expect(DistanceUnit.preferred(locale: Locale(identifier: "de_DE")) == .kilometers)
        #expect(abs(DistanceUnit.miles.toKilometers(50) - 80.4672) < 0.001)
    }

    // MARK: Ticketmaster

    @Test func ticketmasterAttractions() throws {
        let found = try TicketmasterParser.parseAttractions(try TestSupport.fixture("tm_attractions_radiohead"))
        #expect(found.count == 3)
        let real = found[1]
        #expect(real.id == "K8vZ9171ob7" && real.musicBrainzIds == [Self.radiohead] && real.isMusic && real.upcomingEvents == 22)
        #expect(real.url?.host == "www.ticketmaster.com")
        // Untrusted fields: a script link and a non-UUID MBID are dropped; a sports team isn't music.
        #expect(found[2].url == nil && found[2].musicBrainzIds.isEmpty && !found[2].isMusic)
    }

    @Test func ticketmasterArtistMatching() throws {
        let found = try TicketmasterParser.parseAttractions(try TestSupport.fixture("tm_attractions_radiohead"))
        #expect(TicketmasterParser.match("Radiohead", mbid: Self.radiohead, in: found)?.id == "K8vZ9171ob7")
        #expect(TicketmasterParser.match("radiohead", mbid: nil, in: found)?.id == "K8vZ9171ob7")
        // The tribute act shares a word, not the name.
        #expect(TicketmasterParser.match("Karma Police", mbid: nil, in: found) == nil)
        // A namesake linked to another MusicBrainz artist is someone else.
        #expect(TicketmasterParser.match("Radiohead", mbid: "11111111-2222-3333-4444-555555555555", in: found) == nil)
        #expect(TicketmasterParser.match("", mbid: nil, in: found) == nil)
    }

    @Test func ticketmasterEvents() throws {
        let concerts = try TicketmasterParser.parseEvents(try TestSupport.fixture("tm_events_radiohead_boston"), home: Self.home)
        // The test event and the one with an unreadable date are skipped; soonest first.
        #expect(concerts.map(\.id) == ["ticketmaster:G5vYZb9Kc1aB2", "ticketmaster:G5vYZb9Kc1aB1", "ticketmaster:G5vYZb9Kc1aB3"])
        let mansfield = concerts[0]
        #expect(mansfield.status == .cancelled && mansfield.localTime == nil && mansfield.formattedTime() == nil)
        #expect(mansfield.title(for: "Radiohead") == "Radiohead - In Rainbows Tour")

        let garden = concerts[1]
        #expect(garden.day == Self.day("2026-11-14") && garden.localTime == "19:30" && garden.timeZone == "America/New_York")
        #expect(garden.formattedTime(locale: Locale(identifier: "en_US")) == "7:30\u{202F}PM")
        #expect(garden.venue == "TD Garden" && garden.place == "Boston, MA" && garden.country == "US")
        #expect(abs((garden.distanceKm ?? 0) - 3.3) < 0.2)
        #expect(garden.minPrice == Decimal(string: "89.5") && garden.currency == "USD")
        #expect(garden.lineup == ["Radiohead", "Sleater-Kinney"] && garden.otherActs(than: "radiohead") == ["Sleater-Kinney"])
        #expect(garden.title(for: "Radiohead") == nil && garden.sources == [.ticketmaster])
        #expect(garden.url?.host == "www.ticketmaster.com")

        // A file: link is not a web link.
        #expect(concerts[2].url == nil && concerts[2].status == .postponed)
    }

    @Test func ticketmasterEmptySearch() throws {
        #expect(try TicketmasterParser.parseEvents(try TestSupport.fixture("tm_events_empty"), home: Self.home).isEmpty)
        let page = try TicketmasterParser.parsePage(try TestSupport.fixture("tm_events_empty"), home: Self.home)
        #expect(page.events.isEmpty && page.totalElements == 0 && page.totalPages == 0)
        #expect(throws: (any Error).self) { try TicketmasterParser.parseEvents(Data("[]".utf8), home: nil) }
    }

    @Test func ticketmasterPagePerformers() throws {
        let page = try TicketmasterParser.parsePage(try TestSupport.fixture("tm_events_radiohead_boston"), home: Self.home)
        #expect(page.totalElements == 5 && page.events.count == 3)
        #expect(page.events[0].performers.map(\.name) == ["Radiohead", "Sleater-Kinney"])
        #expect(page.events[0].performers[0].musicBrainzIds == [Self.radiohead])
    }

    @Test func ticketmasterTimestamps() {
        #expect(TicketmasterClient.timestamp(Self.now) == "2026-10-11T12:00:00Z")
    }

    @Test func ticketmasterClientFindsNearbyConcerts() async throws {
        let requests = Requests()
        let client = TicketmasterClient(apiKey: " secret-key ", minInterval: 0) { request in
            let url = request.url!
            await requests.add(url)
            return try TestSupport.fixture(url.path.hasSuffix("attractions.json") ? "tm_attractions_radiohead" : "tm_events_radiohead_boston")
        }
        let result = try await client.upcomingConcerts(artist: "Radiohead", mbid: Self.radiohead, near: Self.home,
                                                       radius: 50, unit: .miles, now: Self.now)
        #expect(result.matched && result.upcomingTotal == 22 && result.artistURL?.host == "www.ticketmaster.com")
        // Mansfield is 27 miles away, the cancelled show still listed.
        #expect(result.concerts.count == 3)
        let urls = await requests.urls
        #expect(urls.count == 2)
        let events = try #require(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { events.first { $0.name == name }?.value }
        #expect(value("attractionId") == "K8vZ9171ob7" && value("apikey") == "secret-key")
        #expect(value("geoPoint") == Self.home.geohash() && value("radius") == "50" && value("unit") == "miles")

        // Within 10 miles, the arena in Boston only (the Fenway show is too).
        let close = try await client.upcomingConcerts(artist: "Radiohead", mbid: nil, near: Self.home, radius: 10, unit: .miles, now: Self.now)
        #expect(close.concerts.map(\.venue) == ["TD Garden", "MGM Music Hall at Fenway"])
        // Past shows are dropped.
        let later = try await client.upcomingConcerts(artist: "Radiohead", mbid: nil, near: Self.home, radius: 50, unit: .miles,
                                                      now: ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!)
        #expect(later.concerts.map(\.venue) == ["MGM Music Hall at Fenway"])
    }

    @Test func ticketmasterUnknownArtistMakesOneRequest() async throws {
        let requests = Requests()
        let client = TicketmasterClient(apiKey: "k", minInterval: 0) { request in
            await requests.add(request.url!)
            return try TestSupport.fixture("tm_attractions_radiohead")
        }
        let result = try await client.upcomingConcerts(artist: "Big Thief", mbid: nil, near: Self.home, radius: 50, unit: .miles, now: Self.now)
        #expect(!result.matched && result.concerts.isEmpty)
        #expect(await requests.urls.count == 1)
    }

    @Test func ticketmasterScanSplitsBusyMonths() async throws {
        let requests = Requests()
        let client = TicketmasterClient(apiKey: "k", minInterval: 0) { request in
            let url = request.url!
            await requests.add(url)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let start = q.first { $0.name == "startDateTime" }!.value!
            let end = q.first { $0.name == "endDateTime" }!.value!
            // The first month is too busy for one search until it's cut down to a week or less.
            if start.hasPrefix("2026-10"), let a = try? Date(start, strategy: .iso8601), let b = try? Date(end, strategy: .iso8601),
               b.timeIntervalSince(a) > 8 * 86_400 {
                return Data(#"{"page": {"size": 200, "totalElements": 4000, "totalPages": 20, "number": 0}}"#.utf8)
            }
            if start.hasPrefix("2026-11-11") { return try TestSupport.fixture("tm_events_radiohead_boston") }
            return try TestSupport.fixture("tm_events_empty")
        }
        let artists = ArtistDirectory([ConcertArtist(name: "Radiohead", mbid: Self.radiohead), ConcertArtist(name: "Sleater-Kinney"),
                                       ConcertArtist(name: "Various Artists")])
        let found = try await client.scan(artists, near: Self.home, radius: 50, unit: .miles, now: Self.now)
        // Both artists on the TD Garden bill, plus Radiohead's other shows on that page.
        #expect(Set(found.map(\.artist)) == ["Radiohead", "Sleater-Kinney"])
        #expect(found.filter { $0.concert.venue == "TD Garden" }.count == 2)
        let urls = await requests.urls
        #expect(urls.count < TicketmasterClient.maxScanRequests && urls.count > 12)
        #expect(urls.allSatisfy { $0.query?.contains("classificationName=music") == true })
    }

    // MARK: JamBase

    @Test func jambaseEventsForAnArtist() throws {
        let result = try JamBaseParser.parseEvents(try TestSupport.fixture("jambase_events_boston"), artist: "Big Thief",
                                                   trustArtist: false, home: Self.home)
        // The tribute night doesn't list Big Thief.
        #expect(result.concerts.count == 2)
        #expect(result.artistURL?.absoluteString == "https://www.jambase.com/band/big-thief" && result.upcomingTotal == 31)

        let paradise = result.concerts[0]
        #expect(paradise.id == "jambase:13800001")
        #expect(paradise.day == Self.day("2026-11-05") && paradise.localTime == "20:00" && paradise.timeZone == "America/New_York")
        #expect(paradise.place == "Boston, MA" && paradise.country == "US" && paradise.status == .scheduled)
        // Headliners first; the concert's "X at Venue" name gives way to the headliner.
        #expect(paradise.lineup == ["Big Thief", "Squirrel Flower"] && paradise.title(for: "Big Thief") == nil)
        #expect(paradise.otherActs(than: "Big Thief") == ["Squirrel Flower"])
        #expect(paradise.minPrice == 35 && paradise.currency == "USD" && paradise.sources == [.jambase])
        #expect(paradise.url?.host == "www.jambase.com")

        // At a festival, the artist's own day.
        let festival = result.concerts[1]
        #expect(festival.isFestival && festival.day == Self.day("2027-05-22") && festival.localTime == nil)
        #expect(festival.title(for: "Big Thief") == "Boston Calling 2027" && festival.status == .rescheduled)
    }

    @Test func jambaseOpeningActSeesTheHeadliner() throws {
        let result = try JamBaseParser.parseEvents(try TestSupport.fixture("jambase_events_boston"), artist: "Squirrel Flower",
                                                   trustArtist: false, home: Self.home)
        #expect(result.concerts.count == 1 && result.concerts[0].title(for: "Squirrel Flower") == "Big Thief")
        #expect(result.upcomingTotal == 12)
    }

    @Test func jambaseScanPage() throws {
        let artists = ArtistDirectory([ConcertArtist(name: "Big Thief"), ConcertArtist(name: "Hozier"), ConcertArtist(name: "Phish")])
        let page = try JamBaseParser.parseScanPage(try TestSupport.fixture("jambase_events_boston"), artists: artists, home: Self.home)
        #expect(page.totalPages == 1)
        #expect(page.items.map(\.artist).sorted() == ["Big Thief", "Big Thief", "Hozier"])
        // Hozier headlines the festival's first day; Big Thief plays the second.
        #expect(page.items.first { $0.artist == "Hozier" }?.concert.day == Self.day("2027-05-21"))
        // The tribute night's script link is gone.
        let untrusted = try JamBaseParser.parseEvents(try TestSupport.fixture("jambase_events_boston"), artist: "Thieves Like Us",
                                                      trustArtist: false, home: nil)
        #expect(untrusted.concerts.first?.url == nil && untrusted.concerts.first?.distanceKm == nil)
    }

    @Test func jambaseClientPrefersTheMusicBrainzID() async throws {
        let requests = Requests()
        let client = JamBaseClient(apiKey: "jb-key") { request in
            await requests.add(request.url!, auth: request.value(forHTTPHeaderField: "Authorization"))
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            // JamBase doesn't know this ID, so the name is tried.
            if q.contains(where: { $0.name == "artistId" }) { throw ConcertError.http(.jambase, 404) }
            return try TestSupport.fixture("jambase_events_boston")
        }
        let result = try await client.upcomingConcerts(artist: "Big Thief", mbid: "f5f5f5f5-0000-4000-8000-000000000001",
                                                       near: Self.home, radius: 50, unit: .miles, now: Self.now)
        #expect(result.matched && result.concerts.count == 2)
        let urls = await requests.urls
        #expect(urls.count == 2)
        #expect(urls[0].query?.contains("artistId=musicbrainz:f5f5f5f5-0000-4000-8000-000000000001") == true)
        #expect(urls[1].query?.contains("artistName=Big%20Thief") == true && urls[1].query?.contains("artistId") == false)
        #expect(urls[1].query?.contains("geoRadiusUnits=mi") == true && urls[1].query?.contains("geoRadiusAmount=50") == true)
        // The key goes in a header, never the URL.
        #expect(await requests.auth.allSatisfy { $0 == "Bearer jb-key" })
        #expect(urls.allSatisfy { !$0.absoluteString.contains("jb-key") })
    }

    @Test func jambaseBatches() {
        let names = (0..<200).map { "Band Number \($0)" } + ["A|B"]
        let batches = JamBaseClient.batches(names, maxLength: 500)
        #expect(batches.count > 1 && batches.flatMap { $0 } == Array(names.dropLast()))
        #expect(batches.allSatisfy { $0.joined(separator: "|").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!.count <= 500 })
    }

    // MARK: Merging

    @Test func sameShowFromTwoSourcesIsListedOnce() {
        let tm = Concert(id: "ticketmaster:1", name: "Big Thief", day: Self.day("2026-11-05"), venue: "Paradise Rock Club",
                         city: "Boston", venuePoint: GeoPoint(latitude: 42.3518, longitude: -71.1190),
                         url: URL(string: "https://www.ticketmaster.com/event/1"), sources: [.ticketmaster])
        let jb = Concert(id: "jambase:2", name: "Big Thief", day: Self.day("2026-11-05"), localTime: "20:00", venue: "The Paradise",
                         city: "Boston", venuePoint: GeoPoint(latitude: 42.3519, longitude: -71.1189), minPrice: 35, currency: "USD",
                         sources: [.jambase])
        let other = Concert(id: "jambase:3", name: "Big Thief", day: Self.day("2026-11-05"), venue: "Brighton Music Hall",
                            city: "Boston", venuePoint: GeoPoint(latitude: 42.3527, longitude: -71.1326), sources: [.jambase])
        let merged = ConcertMerger.merge([[tm], [jb, other]])
        #expect(merged.count == 2)
        let paradise = merged.first { $0.id == "ticketmaster:1" }!
        #expect(paradise.sources == [.ticketmaster, .jambase] && paradise.localTime == "20:00" && paradise.minPrice == 35)
        #expect(paradise.url?.host == "www.ticketmaster.com")

        let nearby = NearbyConcerts([SourceConcerts(source: .ticketmaster, matched: true, upcomingTotal: 10, concerts: [tm]),
                                     SourceConcerts(source: .jambase, matched: true, upcomingTotal: 31, concerts: [jb, other])])
        #expect(nearby.concerts.count == 2 && nearby.elsewhereCount == 29)

        let scan = ConcertScan.merge([[ArtistConcert(artist: "Big Thief", concert: tm)],
                                      [ArtistConcert(artist: "Big Thief", concert: jb), ArtistConcert(artist: "Squirrel Flower", concert: jb)]])
        #expect(scan.count == 2 && scan.map(\.artist).sorted() == ["Big Thief", "Squirrel Flower"])
    }

    @Test func artistDirectory() {
        let d = ArtistDirectory([ConcertArtist(name: "The National", mbid: "11111111-2222-3333-4444-555555555555"),
                                 ConcertArtist(name: "Simon & Garfunkel"), ConcertArtist(name: "Various Artists"), ConcertArtist(name: "")])
        #expect(d.artists.count == 2)
        #expect(d.match(name: "National") == "The National")
        #expect(d.match(name: "Simon and Garfunkel") == "Simon & Garfunkel")
        #expect(d.match(name: "Whoever", mbids: ["11111111-2222-3333-4444-555555555555"]) == "The National")
        // Same name, different MusicBrainz artist.
        #expect(d.match(name: "The National", mbids: ["99999999-2222-3333-4444-555555555555"]) == nil)
        #expect(d.match(name: "Various Artists") == nil)
    }

    // MARK: Finding

    @Test func oneFailingSourceDoesNotHideTheOther() async throws {
        let tm = TicketmasterClient(apiKey: "bad", minInterval: 0) { _ in throw ConcertError.invalidKey(.ticketmaster) }
        let jb = JamBaseClient(apiKey: "k") { _ in try TestSupport.fixture("jambase_events_boston") }
        let (found, errors) = try await ConcertFinder.find(artist: "Big Thief", mbid: nil, near: Self.home, radius: 50, unit: .miles,
                                                           providers: [tm, jb], now: Self.now)
        #expect(found.concerts.count == 2 && found.bySource.map(\.source) == [.jambase])
        #expect(errors == [.invalidKey(.ticketmaster)])
        // Error messages never include request URLs (they carry keys).
        #expect(ConcertError.http(.ticketmaster, 500).errorDescription == "Ticketmaster returned an error (HTTP 500).")

        await #expect(throws: ConcertError.invalidKey(.ticketmaster)) {
            try await ConcertFinder.find(artist: "Big Thief", mbid: nil, near: Self.home, radius: 50, unit: .miles, providers: [tm], now: Self.now)
        }
    }
}

private actor Requests {
    var urls: [URL] = []
    var auth: [String?] = []
    func add(_ url: URL, auth header: String? = nil) { urls.append(url); auth.append(header) }
}
