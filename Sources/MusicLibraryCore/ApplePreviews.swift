import Foundation

// MARK: Models

/// A song on Apple Music with its preview clip (about 30 seconds of AAC audio).
public struct ApplePreviewTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var artist: String
    public var disc: Int
    public var number: Int
    public var duration: Double?
    /// The preview clip; only ever an https URL on an Apple host (see `ApplePreviewParser.isAppleURL`).
    public var previewURL: URL?
    /// The song on music.apple.com.
    public var pageURL: URL?

    public init(id: Int, title: String, artist: String, disc: Int = 1, number: Int, duration: Double? = nil,
                previewURL: URL? = nil, pageURL: URL? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.disc = disc; self.number = number
        self.duration = duration; self.previewURL = previewURL; self.pageURL = pageURL
    }
}

/// An album on Apple Music and its songs.
public struct AppleAlbum: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var artist: String
    public var trackCount: Int
    public var releaseYear: Int?
    /// The edited ("clean") version of an album that also has an explicit one.
    public var isClean: Bool
    /// The album on music.apple.com.
    public var pageURL: URL?
    public var tracks: [ApplePreviewTrack]

    public init(id: Int, title: String, artist: String, trackCount: Int = 0, releaseYear: Int? = nil, isClean: Bool = false,
                pageURL: URL? = nil, tracks: [ApplePreviewTrack] = []) {
        self.id = id; self.title = title; self.artist = artist; self.trackCount = trackCount; self.releaseYear = releaseYear
        self.isClean = isClean; self.pageURL = pageURL; self.tracks = tracks
    }

    public var previews: [ApplePreviewTrack] { tracks.filter { $0.previewURL != nil } }

    /// Drops URLs that aren't https on apple.com (for albums read back from a cache, which may come from elsewhere).
    public mutating func validateURLs() {
        func check(_ url: URL?) -> URL? { url.flatMap { ApplePreviewParser.isAppleURL($0) ? $0 : nil } }
        pageURL = check(pageURL)
        for i in tracks.indices {
            tracks[i].previewURL = check(tracks[i].previewURL)
            tracks[i].pageURL = check(tracks[i].pageURL)
        }
    }
}

/// The Apple Music album a catalog title was matched to, for its song previews. Cached in the library database
/// (`catalog_previews`).
public struct CatalogPreviews: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable { case link, barcode, search }

    public var workId: String
    public var album: AppleAlbum?
    public var match: Match?
    public var fetchedAt: Date

    public init(workId: String, album: AppleAlbum? = nil, match: Match? = nil, fetchedAt: Date = Date()) {
        self.workId = workId; self.album = album; self.match = match; self.fetchedAt = fetchedAt
    }

    public var isMatched: Bool { album != nil }

    static let maxAge: TimeInterval = 30 * 86_400
    static let notFoundRetry: TimeInterval = 7 * 86_400

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > (isMatched ? Self.maxAge : Self.notFoundRetry)
    }
}

// MARK: Parsing

/// Reads the iTunes Search API's `/lookup` and `/search` responses (https://itunes.apple.com).
public enum ApplePreviewParser {
    /// The albums in a response, in order, each with the songs that came with it (sorted by disc and number).
    /// Songs whose album isn't in the response get one made from their own fields.
    public static func parseAlbums(_ data: Data) throws -> [AppleAlbum] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Apple Music response is not a JSON object")
        }
        var albums: [AppleAlbum] = []
        var index: [Int: Int] = [:]
        func str(_ r: [String: Any], _ key: String) -> String { r[key] as? String ?? "" }
        func year(_ r: [String: Any]) -> Int? { Int(str(r, "releaseDate").prefix(4)) }
        func album(_ r: [String: Any], id: Int) -> AppleAlbum {
            AppleAlbum(id: id, title: str(r, "collectionName"), artist: str(r, "artistName"),
                       trackCount: r["trackCount"] as? Int ?? 0, releaseYear: year(r),
                       isClean: str(r, "collectionExplicitness") == "cleaned",
                       pageURL: appleURL(str(r, "collectionViewUrl")).map(stripTracking))
        }
        for r in o["results"] as? [[String: Any]] ?? [] {
            guard let collectionId = r["collectionId"] as? Int else { continue }
            switch r["wrapperType"] as? String {
            case "collection":
                if let i = index[collectionId] {
                    let tracks = albums[i].tracks
                    albums[i] = album(r, id: collectionId)
                    albums[i].tracks = tracks
                } else {
                    index[collectionId] = albums.count
                    albums.append(album(r, id: collectionId))
                }
            case "track":
                guard r["kind"] as? String == "song", let trackId = r["trackId"] as? Int else { continue }
                let track = ApplePreviewTrack(
                    id: trackId, title: str(r, "trackName"), artist: str(r, "artistName"),
                    disc: r["discNumber"] as? Int ?? 1, number: r["trackNumber"] as? Int ?? 0,
                    duration: (r["trackTimeMillis"] as? Int).map { Double($0) / 1000 },
                    previewURL: appleURL(str(r, "previewUrl")), pageURL: appleURL(str(r, "trackViewUrl")).map(stripTracking))
                if index[collectionId] == nil {
                    // A song from a search: its album has the collection fields but not the album's own page.
                    index[collectionId] = albums.count
                    var a = album(r, id: collectionId)
                    a.pageURL = nil
                    albums.append(a)
                }
                albums[index[collectionId]!].tracks.append(track)
            default:
                continue
            }
        }
        for i in albums.indices {
            albums[i].tracks.sort { ($0.disc, $0.number) < ($1.disc, $1.number) }
        }
        return albums
    }

    /// A URL from the response, only if it is https on apple.com (previews come from audio-ssl.itunes.apple.com).
    static func appleURL(_ string: String) -> URL? {
        guard let url = URL(webLink: string), isAppleURL(url) else { return nil }
        return url
    }

    public static func isAppleURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    /// Drops the `uo=4` affiliate tracking parameter Apple adds to page links.
    static func stripTracking(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.queryItems = c.queryItems?.filter { $0.name != "uo" }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url ?? url
    }

    /// The album ID in an Apple Music link (from MusicBrainz): `https://music.apple.com/us/album/ok-computer/1097861387`,
    /// `https://itunes.apple.com/gb/album/id1097861387`. Nil for anything else (songs, artists, other hosts).
    public static func albumId(_ url: URL) -> Int? {
        guard url.isWebLink, let host = url.host?.lowercased(), host.hasSuffix(".apple.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.contains("album"), let last = parts.last else { return nil }
        let digits = last.hasPrefix("id") ? String(last.dropFirst(2)) : last
        guard !digits.isEmpty, digits.count <= 15, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

// MARK: Client

/// The iTunes Search API: no account or key needed. Apple allows roughly 20 requests a minute, so requests are
/// spaced out (3 s by default).
public actor ApplePreviewClient {
    public typealias Get = @Sendable (URL) async throws -> Data

    public static let baseURL = "https://itunes.apple.com"
    private let get: Get
    private let country: String
    private let minInterval: TimeInterval
    private var nextSlot = Date.distantPast

    /// `country` is the storefront (two letters), which decides what's available.
    public init(country: String = "US", minInterval: TimeInterval = 3, get: Get? = nil) {
        let code = country.uppercased()
        self.country = code.count == 2 && code.allSatisfy(\.isLetter) ? code : "US"
        self.minInterval = minInterval
        self.get = get ?? { url in
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw NetworkError.http(code, url.absoluteString) }
            return data
        }
    }

    /// The album with this barcode, with its songs.
    public func album(upc: String) async throws -> AppleAlbum? {
        let digits = upc.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 8 else { return nil }
        return try await fetch("lookup", ["upc": digits, "entity": "song", "limit": "200"]).first
    }

    /// The album with this Apple Music ID, with its songs.
    public func album(id: Int) async throws -> AppleAlbum? {
        try await fetch("lookup", ["id": String(id), "entity": "song", "limit": "200"]).first { $0.id == id }
    }

    /// Albums matching free text (artist and title), without their songs.
    public func searchAlbums(term: String) async throws -> [AppleAlbum] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await fetch("search", ["term": term, "media": "music", "entity": "album", "limit": "15"])
    }

    /// Songs matching free text (title and artist), each with its preview when Apple has one.
    public func searchSongs(term: String) async throws -> [ApplePreviewTrack] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return try await fetch("search", ["term": term, "media": "music", "entity": "song", "limit": "15"]).flatMap(\.tracks)
    }

    func fetch(_ endpoint: String, _ params: [String: String]) async throws -> [AppleAlbum] {
        try await throttle()
        return try ApplePreviewParser.parseAlbums(try await get(Self.url(endpoint, params, country: country)))
    }

    static func url(_ endpoint: String, _ params: [String: String], country: String) -> URL {
        var c = URLComponents(string: "\(baseURL)/\(endpoint)")!
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "country", value: country)]
        return c.url!
    }

    private func throttle() async throws {
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(minInterval)
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
}

// MARK: Matching

public enum ApplePreviewMatcher {
    /// The candidate that is this album: a title form in common (with or without "(Deluxe Edition)" or
    /// ": subtitle", but "Anthology 2" is not "Anthology") by a compatible artist ("Various Artists" for compilations).
    /// Among matches, the closest track count wins (when known), then the exact title ("Album" over
    /// "Album (Deluxe Edition)"), the explicit version over the clean one, and the closest year.
    public static func bestAlbum(_ candidates: [AppleAlbum], titles: [String], artists: [String],
                                 trackCount: Int? = nil, year: Int? = nil) -> AppleAlbum? {
        let exact = Set(titles.map(CatalogText.key).filter { !$0.isEmpty })
        let wanted = exact.union(titles.flatMap(titleForms))
        let artistTokens = artists.map(CatalogOwnership.tokens).filter { !$0.isEmpty }
        let matches = candidates.filter { album in
            guard !Set(titleForms(album.title)).isDisjoint(with: wanted) else { return false }
            let theirs = CatalogOwnership.tokens(album.artist)
            if artistTokens.isEmpty { return CatalogText.key(album.artist) == "various artists" || exact.contains(CatalogText.key(album.title)) }
            return artistTokens.contains { CatalogOwnership.compatible($0, theirs) }
        }
        func rank(_ a: AppleAlbum) -> (Int, Int, Int, Int) {
            let tracks = trackCount.map { abs(a.trackCount - $0) } ?? 0
            let titleRank = exact.contains(CatalogText.key(a.title)) ? 0 : 1
            let years = year.flatMap { y in a.releaseYear.map { abs($0 - y) } } ?? 0
            return (tracks, titleRank, a.isClean ? 1 : 0, years)
        }
        return matches.min { rank($0) < rank($1) }
    }

    /// An album title's keys, with and without trailing bracketed notes and ": subtitle" (unless the subtitle is a
    /// number: "Anthology: 2").
    static func titleForms(_ title: String) -> [String] {
        var s = title.trimmingCharacters(in: .whitespaces)
        var forms = [CatalogText.key(s)]
        while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression), r.lowerBound > s.startIndex {
            s.removeSubrange(r)
            forms.append(CatalogText.key(s))
        }
        for separator in [": ", " - "] {
            if let r = s.range(of: separator), r.lowerBound > s.startIndex,
               !CatalogOwnership.isNumbering(String(s[r.upperBound...])) {
                forms.append(CatalogText.key(String(s[..<r.lowerBound])))
            }
        }
        return forms.filter { !$0.isEmpty }
    }

    /// A song title's key without trailing "(Remastered)", "[Live]" or " - 2011 Remaster".
    static func songKey(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression), r.lowerBound > s.startIndex {
            s.removeSubrange(r)
        }
        if let r = s.range(of: " - "), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
        return CatalogText.key(s)
    }

    /// The search result that is this song with a preview: the same title (without "(Remastered)" and the like) by a
    /// compatible artist (any, when no artist is given), the shortest title first.
    public static func bestSong(_ candidates: [ApplePreviewTrack], title: String, artist: String?) -> ApplePreviewTrack? {
        let key = songKey(title)
        let artistTokens = artist.map(CatalogOwnership.tokens) ?? []
        return candidates
            .filter { $0.previewURL != nil && songKey($0.title) == key }
            .filter { artistTokens.isEmpty || CatalogOwnership.compatible(artistTokens, CatalogOwnership.tokens($0.artist)) }
            .min { $0.title.count < $1.title.count }
    }

    /// A song of a track list (disc, number, title).
    public struct Song: Hashable, Sendable {
        public var disc: Int
        public var number: Int
        public var title: String
        public init(disc: Int = 1, number: Int, title: String) { self.disc = disc; self.number = number; self.title = title }
    }

    /// Lines Apple's songs up with a track list: by title first (the nearest one on the same disc when a title
    /// repeats), then by position for the rest, but only where the disc has as many songs on both sides.
    /// Keyed by the song's index in `songs`; only songs with a preview.
    public static func lineUp(_ songs: [Song], with album: AppleAlbum) -> [Int: ApplePreviewTrack] {
        var out: [Int: ApplePreviewTrack] = [:]
        var used = Set<Int>()
        let apple = album.tracks
        var byKey: [String: [Int]] = [:]
        for (i, t) in apple.enumerated() { byKey[songKey(t.title), default: []].append(i) }
        for (i, song) in songs.enumerated() {
            let options = (byKey[songKey(song.title)] ?? []).filter { !used.contains($0) }
            let best = options.min { a, b in
                let ta = apple[a], tb = apple[b]
                return (ta.disc == song.disc ? 0 : 1, abs(ta.number - song.number)) < (tb.disc == song.disc ? 0 : 1, abs(tb.number - song.number))
            }
            if let best {
                used.insert(best)
                out[i] = apple[best]
            }
        }
        var ours: [Int: Int] = [:], theirs: [Int: Int] = [:]
        for s in songs { ours[s.disc, default: 0] += 1 }
        for t in apple { theirs[t.disc, default: 0] += 1 }
        for (i, song) in songs.enumerated() where out[i] == nil && ours[song.disc] == theirs[song.disc] {
            if let j = apple.indices.first(where: { apple[$0].disc == song.disc && apple[$0].number == song.number }), !used.contains(j) {
                used.insert(j)
                out[i] = apple[j]
            }
        }
        return out.filter { $0.value.previewURL != nil }
    }
}

// MARK: Finding

/// Finds a catalog title on Apple Music: through an Apple Music link on its MusicBrainz release, then its
/// barcodes (Apple's often differ from the CD's), then a search on artist and title.
public struct ApplePreviewFinder: Sendable {
    let client: ApplePreviewClient

    public init(client: ApplePreviewClient) { self.client = client }

    public func previews(for item: CatalogItem, details: CatalogAlbumDetails?, upcs: [String] = [], now: Date = Date()) async throws -> CatalogPreviews {
        var result = CatalogPreviews(workId: item.id, fetchedAt: now)
        let expected = details?.tracklist.count
        if let id = details?.album?.links.lazy.filter({ $0.kind == .appleMusic }).compactMap({ ApplePreviewParser.albumId($0.url) }).first,
           let album = try await client.album(id: id), !album.tracks.isEmpty {
            result.album = album
            result.match = .link
            return result
        }
        // The matched release's barcode, then the shown edition's, then the others (at most three).
        let editions = (details?.editions ?? []).filter { $0.recordId == item.recordId } + (details?.editions ?? []).filter { $0.recordId != item.recordId }
        var tried = Set<String>()
        for upc in [details?.barcode].compactMap({ $0 }) + editions.compactMap(\.upc) + upcs {
            guard tried.count < 3, let code = CatalogText.barcodeVariants(upc).first, tried.insert(code).inserted else { continue }
            if let album = try await client.album(upc: code), !album.tracks.isEmpty {
                result.album = album
                result.match = .barcode
                return result
            }
        }
        let titles = [details?.mbTitle, item.subtitle.map { "\(item.title): \($0)" }, item.title].compactMap { $0 }.filter { !$0.isEmpty }
        let artists = [item.artist, details?.mbArtist ?? ""].filter { !$0.isEmpty }
        let artist = details?.mbArtist ?? item.artist
        var searched = Set<String>()
        for title in titles {
            let term = artist.isEmpty || CatalogText.key(artist) == "various artists" ? title : "\(artist) \(title)"
            guard searched.insert(CatalogText.key(term)).inserted else { continue }
            let candidates = try await client.searchAlbums(term: term)
            if let best = ApplePreviewMatcher.bestAlbum(candidates, titles: titles, artists: artists, trackCount: expected,
                                                         year: details?.year ?? item.year),
               let album = try await client.album(id: best.id), !album.tracks.isEmpty {
                result.album = album
                result.match = .search
                return result
            }
        }
        return result
    }
}
