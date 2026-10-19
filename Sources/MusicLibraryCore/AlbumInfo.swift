import Foundation

/// What we know about an album from the internet: the MusicBrainz release group (type, first release,
/// community rating, genres, links to reviews and databases), a Wikipedia (or Last.fm, or Wikidata)
/// description, and the full track list of the release the library's copy was matched to.
public struct AlbumInfo: Codable, Hashable, Sendable {
    public var title: String
    public var releaseGroupId: String?
    /// Album, EP, Single…
    public var primaryType: String?
    /// Live, Compilation, Soundtrack…
    public var secondaryTypes: [String] = []
    public var firstReleaseDate: String?
    public var genres: [String] = []
    /// MusicBrainz community rating, 0–5.
    public var rating: Double?
    public var ratingVotes: Int = 0
    public var description: String?
    public var descriptionSource: String?
    public var descriptionURL: URL?
    public var links: [ArtistLink] = []
    public var tracklist: [TracklistEntry] = []
    /// The release's own credits (players, producers, engineers… on the whole release), from the same MusicBrainz
    /// lookup as the track list. Nil in info cached before they were kept. Music DNA reads them for copies with no
    /// tracks in the library.
    public var releaseCredits: [Credit]?
    public var lastfmListeners: Int?
    public var lastfmUserPlaycount: Int?
    public var fetchedAt: Date = Date()
    public var notFound: Bool = false

    public init(title: String) { self.title = title }

    public var firstReleaseYear: Int? { firstReleaseDate.flatMap { Int($0.prefix(4)) } }

    /// "Live Album", "Compilation", "EP"…
    public var typeLabel: String? {
        let primary = primaryType ?? "Album"
        guard let secondary = secondaryTypes.first else { return primaryType }
        return primary == "Album" ? "\(secondary) Album" : "\(secondary) \(primary)"
    }

    public var reviews: [ArtistLink] { links.filter { $0.kind == .review } }
}

public struct TracklistEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(disc)-\(number)" }
    public var disc: Int
    public var number: Int
    public var title: String
    public var artist: String
    public var duration: Double?
    public var recordingId: String
    /// The position printed on the release when it isn't just the track number: a record's side and track ("A1",
    /// "B2"). Nil in info cached before positions were kept, and for plain numbers.
    public var position: String?
    /// The recording's and its work's credits (performers, writers…). Nil in info cached before they were kept.
    public var credits: [Credit]?

    public init(disc: Int, number: Int, title: String, artist: String = "", duration: Double? = nil, recordingId: String = "",
                position: String? = nil, credits: [Credit]? = nil) {
        self.disc = disc; self.number = number; self.title = title; self.artist = artist
        self.duration = duration; self.recordingId = recordingId
        self.position = Self.position(position, number: number)
        self.credits = credits.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "A1" for a record's track, else the track number.
    public var displayPosition: String { position ?? String(number) }

    /// The printed position, unless it's empty, the plain track number or too long to be one (it's from the network).
    static func position(_ raw: String?, number: Int) -> String? {
        guard let p = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty, p.count <= 12, p != String(number) else {
            return nil
        }
        return p
    }
}

/// The parts of a MusicBrainz release group we use.
public struct MBReleaseGroup: Sendable {
    public var id: String
    public var title: String
    public var primaryType: String?
    public var secondaryTypes: [String]
    public var firstReleaseDate: String?
    public var genres: [String]
    public var rating: Double?
    public var ratingVotes: Int
    public var score: Int?
    public var artist: String
    public var urls: [(String, URL)]
}

extension ArtistInfoParser {
    /// Community genre votes are noisy (a Beatles album collects "trance" and "house"); keep the genres
    /// with at least a quarter of the top genre's votes.
    static func topGenres(_ raw: Any?, limit: Int = 6) -> [String] {
        let all = (raw as? [[String: Any]] ?? []).compactMap { g -> (String, Int)? in
            guard let name = g["name"] as? String else { return nil }
            return (name, g["count"] as? Int ?? 0)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        guard let top = all.first?.1 else { return [] }
        return all.filter { Double($0.1) >= Double(top) * 0.25 }.prefix(limit).map(\.0)
    }

    static func releaseGroup(_ o: [String: Any]) -> MBReleaseGroup? {
        guard let id = o["id"] as? String, let title = o["title"] as? String else { return nil }
        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let rating = o["rating"] as? [String: Any]
        let urls: [(String, URL)] = (o["relations"] as? [[String: Any]] ?? []).compactMap { r in
            guard let type = r["type"] as? String, let res = (r["url"] as? [String: Any])?["resource"] as? String,
                  let url = URL(webLink: res), r["ended"] as? Bool != true else { return nil }
            return (type, url)
        }
        return MBReleaseGroup(
            id: id, title: title, primaryType: str(o["primary-type"]),
            secondaryTypes: o["secondary-types"] as? [String] ?? [], firstReleaseDate: str(o["first-release-date"]),
            genres: topGenres(o["genres"]), rating: (rating?["value"] as? NSNumber)?.doubleValue,
            ratingVotes: rating?["votes-count"] as? Int ?? 0,
            score: (o["score"] as? Int) ?? Int(o["score"] as? String ?? ""),
            artist: MusicBrainzParser.creditString(o["artist-credit"]), urls: urls)
    }

    public static func parseReleaseGroup(_ data: Data) throws -> MBReleaseGroup {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rg = releaseGroup(o) else {
            throw NetworkError.badResponse("MusicBrainz release group is not a release group object")
        }
        return rg
    }

    public static func parseReleaseGroupSearch(_ data: Data) throws -> [MBReleaseGroup] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz release group search is not a JSON object")
        }
        return (o["release-groups"] as? [[String: Any]] ?? []).compactMap(releaseGroup)
    }

    public struct LastFMAlbum: Equatable, Sendable {
        public var wiki: String?
        public var url: URL?
        public var listeners: Int?
        public var userPlaycount: Int?
    }

    public static func parseLastFMAlbum(_ data: Data) throws -> LastFMAlbum? {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Last.fm album info is not a JSON object")
        }
        guard let a = o["album"] as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? Int(v as? String ?? "") }
        let wiki = ((a["wiki"] as? [String: Any])?["summary"] as? String).map(cleanLastFMBio)
        return LastFMAlbum(wiki: wiki.flatMap { $0.isEmpty ? nil : $0 }, url: (a["url"] as? String).flatMap(URL.init(webLink:)),
                           listeners: int(a["listeners"]), userPlaycount: int(a["userplaycount"]))
    }
}

extension ArtistLink {
    /// Publication names for review links, by host.
    static let publications: [String: String] = [
        "bbc.co.uk": "BBC Music", "pitchfork.com": "Pitchfork", "allmusic.com": "AllMusic",
        "theguardian.com": "The Guardian", "rollingstone.com": "Rolling Stone", "nme.com": "NME",
        "metacritic.com": "Metacritic", "sputnikmusic.com": "Sputnikmusic", "popmatters.com": "PopMatters",
        "consequence.net": "Consequence", "consequenceofsound.net": "Consequence", "spin.com": "SPIN",
        "avclub.com": "The A.V. Club", "npr.org": "NPR", "nytimes.com": "The New York Times",
        "latimes.com": "Los Angeles Times", "allaboutjazz.com": "All About Jazz", "downbeat.com": "DownBeat",
        "jazztimes.com": "JazzTimes", "thequietus.com": "The Quietus", "stereogum.com": "Stereogum",
        "mojo4music.com": "Mojo", "uncut.co.uk": "Uncut", "clashmusic.com": "Clash", "slantmagazine.com": "Slant",
        "musicomh.com": "musicOMH", "exclaim.ca": "Exclaim!", "residentadvisor.net": "Resident Advisor",
    ]

    static func publication(for url: URL) -> String {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if let name = publications.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value { return name }
        // "example.co.uk" → "Example"
        let parts = host.split(separator: ".")
        let name = parts.count >= 3 && ["co", "com", "org"].contains(parts[parts.count - 2]) ? parts[parts.count - 3] : parts.dropLast().last ?? Substring(host)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

extension AlbumInfo {
    public static func assemble(title: String, releaseGroup rg: MBReleaseGroup?, release: ReleaseInfo?,
                                wikidata: ArtistInfoParser.WikidataEntity?, wikipedia: ArtistInfoParser.WikipediaSummary?,
                                lastfm: ArtistInfoParser.LastFMAlbum?, now: Date = Date()) -> AlbumInfo {
        var info = AlbumInfo(title: rg?.title ?? title)
        info.fetchedAt = now
        if let rg {
            info.releaseGroupId = rg.id
            info.primaryType = rg.primaryType
            info.secondaryTypes = rg.secondaryTypes
            info.firstReleaseDate = rg.firstReleaseDate
            info.genres = rg.genres
            if rg.ratingVotes > 0 { info.rating = rg.rating; info.ratingVotes = rg.ratingVotes }
            var seen = Set<ArtistLink.Kind>()
            for (type, url) in rg.urls {
                if type.lowercased() == "review" {
                    guard url.isWebLink else { continue }
                    var link = ArtistLink(kind: .review, url: url)
                    link.label = ArtistLink.publication(for: url)
                    if !info.links.contains(where: { $0.url == url }) { info.links.append(link) }
                    continue
                }
                guard let kind = ArtistLink.classify(relationType: type, url: url), seen.insert(kind).inserted else { continue }
                info.links.append(ArtistLink(kind: kind, url: url))
            }
            if let url = URL(string: "https://musicbrainz.org/release-group/\(rg.id)") {
                info.links.append(ArtistLink(kind: .musicbrainz, url: url))
            }
        }
        if let release {
            info.tracklist = release.tracks.map {
                TracklistEntry(disc: $0.discNo, number: $0.trackNo, title: $0.title, artist: $0.artist,
                               duration: $0.durationSeconds, recordingId: $0.recordingId, position: $0.numberLabel,
                               credits: $0.credits)
            }
            info.releaseCredits = release.credits.isEmpty ? nil : release.credits
        }
        if let wikipedia {
            info.description = wikipedia.extract
            info.descriptionSource = "Wikipedia"
            info.descriptionURL = wikipedia.pageURL
            if let page = wikipedia.pageURL, !info.links.contains(where: { $0.kind == .wikipedia }) {
                info.links.append(ArtistLink(kind: .wikipedia, url: page))
            }
        } else if let wiki = lastfm?.wiki {
            info.description = wiki
            info.descriptionSource = "Last.fm"
            info.descriptionURL = lastfm?.url
        } else if let d = wikidata?.description {
            info.description = d.prefix(1).uppercased() + d.dropFirst() + "."
            info.descriptionSource = "Wikidata"
        }
        if let lastfm {
            info.lastfmListeners = lastfm.listeners
            info.lastfmUserPlaycount = lastfm.userPlaycount
            if let url = lastfm.url, !info.links.contains(where: { $0.kind == .lastfm }) {
                info.links.append(ArtistLink(kind: .lastfm, url: url))
            }
        }
        let order = ArtistLink.Kind.allCases
        info.links = info.links.enumerated().sorted { a, b in
            let ia = order.firstIndex(of: a.element.kind)!, ib = order.firstIndex(of: b.element.kind)!
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        info.notFound = rg == nil && release == nil && wikipedia == nil && lastfm?.wiki == nil
        return info
    }
}

/// Matches the release's track list against the tracks in the library.
public enum AlbumTracklist {
    public enum Row: Identifiable, Hashable, Sendable {
        case owned(Track, TracklistEntry?)
        case missing(TracklistEntry)

        public var id: String {
            switch self {
            case .owned(let t, _): "t\(t.id)"
            case .missing(let e): "m\(e.id)"
            }
        }

        public var disc: Int {
            switch self {
            case .owned(let t, let e): e?.disc ?? t.metadata.discNo ?? 1
            case .missing(let e): e.disc
            }
        }
    }

    /// The release's order with library tracks filled in (by recording ID, then disc and number); library
    /// tracks the release doesn't list come last. Without a track list, just the library tracks.
    public static func merge(library: [Track], tracklist: [TracklistEntry]) -> [Row] {
        guard !tracklist.isEmpty else { return library.map { .owned($0, nil) } }
        var remaining = library
        var rows: [Row] = []
        for entry in tracklist {
            let byRecording = entry.recordingId.isEmpty ? nil
                : remaining.firstIndex { $0.metadata.mbRecordingId == entry.recordingId }
            let byPosition = remaining.firstIndex { ($0.metadata.discNo ?? 1) == entry.disc && $0.trackNo == entry.number }
            if let i = byRecording ?? byPosition {
                rows.append(.owned(remaining.remove(at: i), entry))
            } else {
                rows.append(.missing(entry))
            }
        }
        return rows + remaining.map { .owned($0, nil) }
    }
}

extension InfoFetcher {
    /// Release group (by ID, via the release, or by search), release track list, Wikipedia and Last.fm.
    public func fetchAlbum(title: String, artist: String, releaseGroupId: String?, releaseId: String?) async throws -> AlbumInfo {
        var release: ReleaseInfo?
        if let releaseId, !releaseId.isEmpty { release = try await musicBrainz.fetchRelease(id: releaseId) }
        var rgId = releaseGroupId.flatMap { $0.isEmpty ? nil : $0 } ?? release?.releaseGroupId
        if rgId == nil {
            let wanted = ArtistResolver.normalized(title)
            rgId = try await musicBrainz.searchReleaseGroups(title: title, artist: artist)
                .first { ArtistResolver.normalized($0.title) == wanted && ($0.score ?? 100) >= 90 }?.id
        }
        var rg: MBReleaseGroup?
        if let rgId { rg = try await musicBrainz.lookupReleaseGroup(id: rgId) }

        let (wikidata, wikipedia) = await wikiInfo(urls: rg?.urls ?? [])
        var lastfmAlbum: ArtistInfoParser.LastFMAlbum?
        if let lastfm, await lastfm.isConfigured {
            lastfmAlbum = try? await lastfm.albumInfo(album: title, artist: artist, username: lastfmUser)
        }
        return AlbumInfo.assemble(title: title, releaseGroup: rg, release: release, wikidata: wikidata,
                                  wikipedia: wikipedia, lastfm: lastfmAlbum)
    }
}

extension MusicBrainzClient {
    public func lookupReleaseGroup(id: String) async throws -> MBReleaseGroup {
        let url = try Self.lookupURL("release-group", id: id, query: "inc=url-rels+genres+ratings&fmt=json")
        return try ArtistInfoParser.parseReleaseGroup(try await fetchData(url))
    }

    public func searchReleaseGroups(title: String, artist: String) async throws -> [MBReleaseGroup] {
        var parts = ["releasegroup:\"\(Self.luceneEscape(title))\""]
        if !artist.isEmpty { parts.append("artist:\"\(Self.luceneEscape(artist))\"") }
        var c = URLComponents(string: "\(Self.baseURL)/release-group")!
        c.queryItems = [.init(name: "query", value: parts.joined(separator: " AND ")),
                        .init(name: "fmt", value: "json"), .init(name: "limit", value: "8")]
        return try ArtistInfoParser.parseReleaseGroupSearch(try await fetchData(c.url!))
    }
}

extension LastFMClient {
    public func albumInfo(album: String, artist: String, username: String?) async throws -> ArtistInfoParser.LastFMAlbum? {
        var p = ["album": album, "artist": artist, "autocorrect": "1"]
        if let username, !username.isEmpty { p["username"] = username }
        return try ArtistInfoParser.parseLastFMAlbum(try await rawCall("album.getInfo", p))
    }
}
