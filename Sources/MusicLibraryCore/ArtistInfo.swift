import Foundation

/// What we know about an artist from the internet: MusicBrainz facts and links, a Wikipedia (or Last.fm,
/// or Wikidata) bio, and a photo from Wikimedia Commons.
public struct ArtistInfo: Codable, Hashable, Sendable {
    public var name: String
    public var mbid: String?
    /// Person, Group, Orchestra, Choir…
    public var type: String?
    /// ISO country code.
    public var country: String?
    public var begin: String?
    public var end: String?
    public var ended: Bool = false
    public var disambiguation: String?
    public var genres: [String] = []
    public var bio: String?
    public var bioSource: String?
    public var bioURL: URL?
    public var links: [ArtistLink] = []
    /// Where the photo comes from (downloaded and cached locally by the app).
    public var imageURL: URL?
    /// The Wikimedia Commons page of the photo, for attribution.
    public var imageCreditURL: URL?
    public var lastfmListeners: Int?
    public var lastfmPlaycount: Int?
    public var lastfmUserPlaycount: Int?
    public var fetchedAt: Date = Date()
    /// Nothing was found online; kept so we don't ask again on every launch.
    public var notFound: Bool = false

    public init(name: String) { self.name = name }

    /// "Group · United States · 2018–present"
    public func summary(locale: Locale = .current) -> String {
        var parts: [String] = []
        if let type, !type.isEmpty { parts.append(type) }
        if let country, !country.isEmpty {
            parts.append(country == "XW" ? "Worldwide" : (locale.localizedString(forRegionCode: country) ?? country))
        }
        let b = begin.map { String($0.prefix(4)) }, e = end.map { String($0.prefix(4)) }
        switch (b, e, ended) {
        case let (b?, e?, _): parts.append(b == e ? b : "\(b)–\(e)")
        case let (b?, nil, true): parts.append(type == "Person" ? "Born \(b)" : "From \(b)")
        case let (b?, nil, false): parts.append(type == "Person" ? "Born \(b)" : "\(b)–present")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

extension URL {
    /// An http(s) URL with a host. Links from MusicBrainz (community edited), Wikipedia, Last.fm and the
    /// `artist_info`/`album_info` caches (a library can come from elsewhere) are only shown and opened when
    /// this holds: other schemes (`file:`, custom app schemes) could launch local apps or trigger other apps.
    public var isWebLink: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false
    }

    /// The URL if it is a web link (see `isWebLink`), else nil.
    public var webLink: URL? { isWebLink ? self : nil }

    /// Parses a web link from untrusted data; nil for anything that isn't http(s) with a host.
    public init?(webLink string: String) {
        guard let url = URL(string: string), url.isWebLink else { return nil }
        self = url
    }
}

public struct ArtistLink: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case official, wikipedia, review, lastfm, bandcamp, spotify, appleMusic, tidal, deezer, youtube, soundcloud,
             instagram, twitter, facebook, tiktok, bluesky, discogs, allmusic, rateyourmusic, genius, setlistfm,
             songkick, bandsintown, imdb, wikidata, musicbrainz
    }

    public var id: String { url.absoluteString }
    public var kind: Kind
    public var url: URL
    /// Overrides the kind's title, e.g. the publication of a review.
    public var label: String?

    public init(kind: Kind, url: URL) { self.kind = kind; self.url = url }

    public var title: String {
        if let label { return label }
        return switch kind {
        case .official: "Official site"
        case .wikipedia: "Wikipedia"
        case .review: "Review"
        case .rateyourmusic: "Rate Your Music"
        case .genius: "Genius"
        case .lastfm: "Last.fm"
        case .bandcamp: "Bandcamp"
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .tidal: "TIDAL"
        case .deezer: "Deezer"
        case .youtube: "YouTube"
        case .soundcloud: "SoundCloud"
        case .instagram: "Instagram"
        case .twitter: "X / Twitter"
        case .facebook: "Facebook"
        case .tiktok: "TikTok"
        case .bluesky: "Bluesky"
        case .discogs: "Discogs"
        case .allmusic: "AllMusic"
        case .setlistfm: "setlist.fm"
        case .songkick: "Songkick"
        case .bandsintown: "Bandsintown"
        case .imdb: "IMDb"
        case .wikidata: "Wikidata"
        case .musicbrainz: "MusicBrainz"
        }
    }

    /// Classifies a MusicBrainz URL relation; nil for links not worth showing (library catalogs, VIAF…).
    static func classify(relationType: String, url: URL) -> Kind? {
        guard url.isWebLink else { return nil }
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        func on(_ domains: String...) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        switch relationType.lowercased() {
        case "official homepage": return .official
        case "wikipedia": return .wikipedia
        case "wikidata": return .wikidata
        case "last.fm": return .lastfm
        case "discogs": return .discogs
        case "allmusic": return .allmusic
        case "bandcamp": return .bandcamp
        case "soundcloud": return .soundcloud
        case "youtube", "youtube music": return .youtube
        case "setlistfm": return .setlistfm
        case "songkick": return .songkick
        case "bandsintown": return .bandsintown
        case "imdb": return .imdb
        case "lyrics": return on("genius.com") ? .genius : nil
        default: break
        }
        if on("last.fm") { return .lastfm }
        if on("rateyourmusic.com") { return .rateyourmusic }
        if on("open.spotify.com", "spotify.com") { return .spotify }
        if on("music.apple.com", "itunes.apple.com") { return .appleMusic }
        if on("tidal.com") { return .tidal }
        if on("deezer.com") { return .deezer }
        if on("youtube.com", "youtu.be") { return .youtube }
        if on("bandcamp.com") { return .bandcamp }
        if on("soundcloud.com") { return .soundcloud }
        if on("instagram.com") { return .instagram }
        if on("twitter.com", "x.com") { return .twitter }
        if on("facebook.com") { return .facebook }
        if on("tiktok.com") { return .tiktok }
        if on("bsky.app") { return .bluesky }
        return nil
    }
}

// MARK: Parsing

/// The parts of a MusicBrainz artist we use.
public struct MBArtist: Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String?
    public var country: String?
    public var begin: String?
    public var end: String?
    public var ended: Bool
    public var disambiguation: String?
    public var genres: [String]
    public var score: Int?
    /// (relation type, url)
    public var urls: [(String, URL)]

    public static func == (a: MBArtist, b: MBArtist) -> Bool {
        a.id == b.id && a.name == b.name && a.urls.map(\.1) == b.urls.map(\.1)
    }
}

public enum ArtistInfoParser {
    static func artist(_ o: [String: Any]) -> MBArtist? {
        guard let id = o["id"] as? String, let name = o["name"] as? String else { return nil }
        let life = o["life-span"] as? [String: Any] ?? [:]
        let genres = topGenres(o["genres"], limit: 8)
        let urls: [(String, URL)] = (o["relations"] as? [[String: Any]] ?? []).compactMap { r in
            guard let type = r["type"] as? String, let res = (r["url"] as? [String: Any])?["resource"] as? String,
                  let url = URL(webLink: res), r["ended"] as? Bool != true else { return nil }
            return (type, url)
        }
        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return MBArtist(id: id, name: name, type: str(o["type"]), country: str(o["country"]),
                        begin: str(life["begin"]), end: str(life["end"]), ended: life["ended"] as? Bool ?? false,
                        disambiguation: str(o["disambiguation"]), genres: genres,
                        score: (o["score"] as? Int) ?? Int(o["score"] as? String ?? ""), urls: urls)
    }

    public static func parseArtist(_ data: Data) throws -> MBArtist {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let a = artist(o) else {
            throw NetworkError.badResponse("MusicBrainz artist is not an artist object")
        }
        return a
    }

    public static func parseArtistSearch(_ data: Data) throws -> [MBArtist] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz artist search is not a JSON object")
        }
        return (o["artists"] as? [[String: Any]] ?? []).compactMap(artist)
    }

    public struct WikidataEntity: Equatable, Sendable {
        public var description: String?
        public var enwikiTitle: String?
        public var imageFile: String?
    }

    public static func parseWikidata(_ data: Data) throws -> WikidataEntity {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = (o["entities"] as? [String: Any])?.values.first as? [String: Any] else {
            throw NetworkError.badResponse("Wikidata entity missing")
        }
        let desc = ((e["descriptions"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String
        let title = ((e["sitelinks"] as? [String: Any])?["enwiki"] as? [String: Any])?["title"] as? String
        let image = (((e["claims"] as? [String: Any])?["P18"] as? [[String: Any]])?.first?["mainsnak"] as? [String: Any])
            .flatMap { ($0["datavalue"] as? [String: Any])?["value"] as? String }
        return WikidataEntity(description: desc, enwikiTitle: title, imageFile: image)
    }

    public struct WikipediaSummary: Equatable, Sendable {
        public var extract: String
        public var pageURL: URL?
        public var imageFile: String?
    }

    public static func parseWikipediaSummary(_ data: Data) throws -> WikipediaSummary? {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Wikipedia summary is not a JSON object")
        }
        // Disambiguation pages aren't about the artist.
        guard (o["type"] as? String) != "disambiguation", let extract = o["extract"] as? String, !extract.isEmpty else { return nil }
        let page = ((o["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        let original = (o["originalimage"] as? [String: Any])?["source"] as? String
        return WikipediaSummary(extract: extract, pageURL: page.flatMap(URL.init(webLink:)),
                                imageFile: original.flatMap(commonsFileName(fromUploadURL:)))
    }

    /// "…/commons/4/4a/Domi_and_JD_Beck_at_History_%28cropped%29.jpg?…" → "Domi and JD Beck at History (cropped).jpg"
    static func commonsFileName(fromUploadURL s: String) -> String? {
        guard let url = URL(string: s), url.host?.hasSuffix("wikimedia.org") == true else { return nil }
        let last = url.lastPathComponent
        guard !last.isEmpty, last.contains(".") else { return nil }
        return (last.removingPercentEncoding ?? last).replacingOccurrences(of: "_", with: " ")
    }

    /// A resized rendition of a Commons file (Commons redirects to the thumbnail).
    public static func commonsImageURL(file: String, width: Int = 800) -> URL? {
        let name = file.replacingOccurrences(of: " ", with: "_")
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/Special:FilePath/")!
        c.path += name
        c.queryItems = [URLQueryItem(name: "width", value: String(width))]
        return c.url
    }

    public static func commonsPageURL(file: String) -> URL? {
        var c = URLComponents(string: "https://commons.wikimedia.org/wiki/")!
        c.path += "File:" + file.replacingOccurrences(of: " ", with: "_")
        return c.url
    }

    /// The Wikipedia article title from a MusicBrainz `wikipedia` relation (English only).
    static func wikipediaTitle(from url: URL) -> String? {
        guard url.host?.hasPrefix("en.") == true, url.path.hasPrefix("/wiki/") else { return nil }
        let raw = String(url.path.dropFirst("/wiki/".count))
        return raw.isEmpty ? nil : raw.replacingOccurrences(of: "_", with: " ")
    }

    public struct LastFMArtist: Equatable, Sendable {
        public var bio: String?
        public var url: URL?
        public var listeners: Int?
        public var playcount: Int?
        public var userPlaycount: Int?
    }

    public static func parseLastFMArtist(_ data: Data) throws -> LastFMArtist? {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Last.fm artist info is not a JSON object")
        }
        guard let a = o["artist"] as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? Int(v as? String ?? "") }
        let stats = a["stats"] as? [String: Any] ?? [:]
        let summary = ((a["bio"] as? [String: Any])?["summary"] as? String).map(cleanLastFMBio)
        return LastFMArtist(bio: summary.flatMap { $0.isEmpty ? nil : $0 }, url: (a["url"] as? String).flatMap(URL.init(webLink:)),
                            listeners: int(stats["listeners"]), playcount: int(stats["playcount"]),
                            userPlaycount: int(stats["userplaycount"]))
    }

    /// Last.fm bios end with an HTML "Read more on Last.fm" link and may contain other tags.
    static func cleanLastFMBio(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<a href=\"https://www.last.fm") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Resolution and assembly

public enum ArtistResolver {
    /// Picks the MusicBrainz artist for a library artist name. A single MBID from the tags wins; otherwise
    /// (no MBID, or a credit like "Rachael & Vilray" that lists several people) only a confident search hit
    /// whose name matches is accepted.
    public static func choose(name: String, taggedIds: [String], searchResults: [MBArtist]) -> String? {
        let ids = Array(NSOrderedSet(array: taggedIds.filter { !$0.isEmpty })) as? [String] ?? []
        if ids.count == 1 { return ids[0] }
        let wanted = normalized(name)
        let hits = searchResults.filter { normalized($0.name) == wanted && ($0.score ?? 100) >= 90 }
        // Prefer a hit that the tags also mention, then MusicBrainz's own ranking.
        return (hits.first { ids.contains($0.id) } ?? hits.first)?.id
    }

    static func normalized(_ s: String) -> String {
        TextNormalizer.normalize(s.replacingOccurrences(of: "&", with: " and "))
            .split(separator: " ").filter { $0 != "the" }.joined(separator: " ")
    }
}

extension ArtistInfo {
    public static func assemble(name: String, mb: MBArtist?, wikidata: ArtistInfoParser.WikidataEntity?,
                                wikipedia: ArtistInfoParser.WikipediaSummary?, lastfm: ArtistInfoParser.LastFMArtist?,
                                now: Date = Date()) -> ArtistInfo {
        var info = ArtistInfo(name: mb?.name ?? name)
        info.fetchedAt = now
        if let mb {
            info.mbid = mb.id
            info.type = mb.type
            info.country = mb.country
            info.begin = mb.begin
            info.end = mb.end
            info.ended = mb.ended
            info.disambiguation = mb.disambiguation
            info.genres = Array(mb.genres.prefix(8))
            var seen = Set<ArtistLink.Kind>()
            for (type, url) in mb.urls {
                guard let kind = ArtistLink.classify(relationType: type, url: url), seen.insert(kind).inserted else { continue }
                info.links.append(ArtistLink(kind: kind, url: url))
            }
            if let mbURL = URL(string: "https://musicbrainz.org/artist/\(mb.id)") {
                info.links.append(ArtistLink(kind: .musicbrainz, url: mbURL))
            }
        }
        if let wikipedia {
            info.bio = wikipedia.extract
            info.bioSource = "Wikipedia"
            info.bioURL = wikipedia.pageURL
            if let page = wikipedia.pageURL, !info.links.contains(where: { $0.kind == .wikipedia }) {
                info.links.insert(ArtistLink(kind: .wikipedia, url: page), at: info.links.first?.kind == .official ? 1 : 0)
            }
        } else if let bio = lastfm?.bio {
            info.bio = bio
            info.bioSource = "Last.fm"
            info.bioURL = lastfm?.url
        } else if let d = wikidata?.description {
            info.bio = d.prefix(1).uppercased() + d.dropFirst() + "."
            info.bioSource = "Wikidata"
        }
        if let lastfm {
            info.lastfmListeners = lastfm.listeners
            info.lastfmPlaycount = lastfm.playcount
            info.lastfmUserPlaycount = lastfm.userPlaycount
            if let url = lastfm.url, !info.links.contains(where: { $0.kind == .lastfm }) {
                info.links.append(ArtistLink(kind: .lastfm, url: url))
            }
        }
        if let file = wikipedia?.imageFile ?? wikidata?.imageFile {
            info.imageURL = ArtistInfoParser.commonsImageURL(file: file)
            info.imageCreditURL = ArtistInfoParser.commonsPageURL(file: file)
        }
        info.links.sort { ArtistLink.Kind.allCases.firstIndex(of: $0.kind)! < ArtistLink.Kind.allCases.firstIndex(of: $1.kind)! }
        info.notFound = mb == nil && wikipedia == nil && lastfm?.bio == nil
        return info
    }
}

// MARK: Fetching

/// Gathers artist and album info from MusicBrainz, Wikidata, Wikipedia and (optionally) Last.fm.
public struct InfoFetcher: Sendable {
    public typealias Get = @Sendable (URL) async throws -> Data?

    let musicBrainz: MusicBrainzClient
    let lastfm: LastFMClient?
    let lastfmUser: String?
    let get: Get

    public init(musicBrainz: MusicBrainzClient, lastfm: LastFMClient? = nil, lastfmUser: String? = nil, get: Get? = nil) {
        self.musicBrainz = musicBrainz
        self.lastfm = lastfm
        self.lastfmUser = lastfmUser
        self.get = get ?? { url in
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return nil }
            guard code == 200 else { throw NetworkError.http(code, url.absoluteString) }
            return data
        }
    }

    /// `taggedIds` are the MusicBrainz artist IDs from the artist's tracks.
    public func fetch(name: String, taggedIds: [String]) async throws -> ArtistInfo {
        var ids = taggedIds
        if Set(ids).count != 1 {
            let results = try await musicBrainz.searchArtists(name: name)
            ids = ArtistResolver.choose(name: name, taggedIds: taggedIds, searchResults: results).map { [$0] } ?? []
        }
        var mb: MBArtist?
        if let id = ids.first { mb = try await musicBrainz.lookupArtist(id: id) }

        let (wikidata, wikipedia) = await wikiInfo(urls: mb?.urls ?? [])
        var lastfmArtist: ArtistInfoParser.LastFMArtist?
        if let lastfm, await lastfm.isConfigured {
            lastfmArtist = try? await lastfm.artistInfo(name: name, username: lastfmUser)
        }
        return ArtistInfo.assemble(name: name, mb: mb, wikidata: wikidata, wikipedia: wikipedia, lastfm: lastfmArtist)
    }

    /// Wikidata (via a `wikidata` relation) and the English Wikipedia summary (via a `wikipedia` relation or
    /// Wikidata's sitelink). Failures just leave them out.
    func wikiInfo(urls: [(String, URL)]) async -> (ArtistInfoParser.WikidataEntity?, ArtistInfoParser.WikipediaSummary?) {
        var wikidata: ArtistInfoParser.WikidataEntity?
        if let q = urls.first(where: { $0.0 == "wikidata" })?.1.lastPathComponent, q.hasPrefix("Q"),
           let url = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(q).json"),
           let data = try? await get(url) {
            wikidata = try? ArtistInfoParser.parseWikidata(data)
        }
        var wikipedia: ArtistInfoParser.WikipediaSummary?
        let title = urls.first(where: { $0.0 == "wikipedia" }).flatMap { ArtistInfoParser.wikipediaTitle(from: $0.1) }
            ?? wikidata?.enwikiTitle
        if let title, let url = Self.summaryURL(title: title), let data = try? await get(url) {
            wikipedia = try? ArtistInfoParser.parseWikipediaSummary(data)
        }
        return (wikidata, wikipedia)
    }

    static func summaryURL(title: String) -> URL? {
        let t = title.replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = t.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    /// Downloads a photo; nil when there is none.
    public func image(_ url: URL) async throws -> Data? { try await get(url) }
}

extension MusicBrainzClient {
    public func lookupArtist(id: String) async throws -> MBArtist {
        let url = try Self.lookupURL("artist", id: id, query: "inc=url-rels+genres&fmt=json")
        return try ArtistInfoParser.parseArtist(try await fetchData(url))
    }

    public func searchArtists(name: String) async throws -> [MBArtist] {
        var c = URLComponents(string: "\(Self.baseURL)/artist")!
        c.queryItems = [.init(name: "query", value: "artist:\"\(Self.luceneEscape(name))\""),
                        .init(name: "fmt", value: "json"), .init(name: "limit", value: "8")]
        return try ArtistInfoParser.parseArtistSearch(try await fetchData(c.url!))
    }
}

extension LastFMClient {
    /// Looked up by name: Last.fm's own MBIDs often differ from MusicBrainz's current ones.
    public func artistInfo(name: String, username: String?) async throws -> ArtistInfoParser.LastFMArtist? {
        var p = ["artist": name, "autocorrect": "1"]
        if let username, !username.isEmpty { p["username"] = username }
        return try ArtistInfoParser.parseLastFMArtist(try await rawCall("artist.getInfo", p))
    }
}
