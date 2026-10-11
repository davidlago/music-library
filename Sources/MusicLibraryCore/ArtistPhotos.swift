import Foundation

/// A photo the user can pick for an artist: a Deezer artist picture, an image from the artist's Wikipedia article,
/// or a Wikimedia Commons search result.
public struct ArtistPhotoCandidate: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case deezer = "Deezer"
        case wikipedia = "Wikipedia"
        case commons = "Wikimedia Commons"
    }

    /// "deezer:<id>" or "wm:<File:…>", so the same Commons file found twice is shown once.
    public var id: String
    public var source: Source
    public var title: String
    public var detail: String
    public var thumbnailURL: URL
    /// The large version when it is known up front (Deezer); Wikimedia files are resolved by `ArtistPhotoFinder.image(for:)`.
    public var imageURL: URL?
    /// The Wikimedia file ("File:…") and the API that knows it.
    public var wikiFile: String?
    public var wikiAPI: URL?
    /// Where the photo comes from, for attribution.
    public var pageURL: URL?

    /// The attribution shown with the photo: Commons files say so, whichever wiki listed them.
    public var credit: String {
        pageURL?.host?.hasPrefix("commons.") == true ? Source.commons.rawValue : source.rawValue
    }
}

/// The photo the user chose for an artist, saved in `artist_photos` apart from the downloaded `artist_info`, so
/// updating the info never replaces it. `file` is relative to `<root>/Artist Images`.
public struct ArtistPhotoChoice: Hashable, Sendable {
    public var file: String
    /// "Deezer", "Wikimedia Commons"…; nil for the user's own images.
    public var credit: String?
    public var creditURL: URL?

    public init(file: String, credit: String? = nil, creditURL: URL? = nil) {
        self.file = file
        self.credit = credit
        self.creditURL = creditURL
    }

    /// A plain file name inside the image folder (rows may come from a library made elsewhere).
    public static func isSafeFileName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && !s.contains("\\") && !s.contains(":")
    }
}

// MARK: Parsing

public enum ArtistPhotoParser {
    public struct DeezerArtist: Equatable, Sendable {
        public var id: Int
        public var name: String
        public var link: URL?
        public var pictureMedium: URL
        public var pictureXL: URL
        public var albums: Int?
        public var fans: Int?
    }

    public struct WikimediaImage: Equatable, Sendable {
        /// "File:Domi and JD Beck at History (cropped).jpg"
        public var title: String
        public var thumbnailURL: URL
        public var width: Int
        public var height: Int
        public var pageURL: URL?
    }

    /// Only images from these hosts are downloaded (the URLs come from API responses).
    static let photoHosts = ["dzcdn.net", "deezer.com", "wikimedia.org", "wikipedia.org"]

    public static func isPhotoURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return photoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func deezerArtist(_ o: [String: Any]) -> DeezerArtist? {
        guard let id = o["id"] as? Int, let name = o["name"] as? String,
              let medium = (o["picture_medium"] as? String).flatMap(deezerPicture),
              let xl = (o["picture_xl"] as? String).flatMap(deezerPicture) else { return nil }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? Int(v as? String ?? "") }
        return DeezerArtist(id: id, name: name, link: (o["link"] as? String).flatMap(URL.init(webLink:)),
                            pictureMedium: medium, pictureXL: xl, albums: int(o["nb_album"]), fans: int(o["nb_fan"]))
    }

    /// Artists without a picture get a placeholder with an empty image hash (".../images/artist//250x250-….jpg").
    static func deezerPicture(_ s: String) -> URL? {
        guard !s.contains("/artist//"), let url = URL(string: s), isPhotoURL(url) else { return nil }
        return url
    }

    /// `https://api.deezer.com/search/artist?q=…`: artists that have a picture, in Deezer's order.
    public static func parseDeezerSearch(_ data: Data) throws -> [DeezerArtist] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Deezer search is not a JSON object")
        }
        if let error = o["error"] as? [String: Any] {
            throw NetworkError.badResponse("Deezer: \(error["message"] as? String ?? "error")")
        }
        return (o["data"] as? [[String: Any]] ?? []).compactMap(deezerArtist)
    }

    /// `https://api.deezer.com/artist/<id>`; nil for an unknown artist (Deezer answers 200 with an error object) or one
    /// without a picture.
    public static func parseDeezerArtist(_ data: Data) throws -> DeezerArtist? {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("Deezer artist is not a JSON object")
        }
        return deezerArtist(o)
    }

    /// A MediaWiki `prop=imageinfo` answer (article images or a file search): photos only (no SVG logos, icons or
    /// sound files), at least 200 px both ways, in the search's ranking when there is one.
    public static func parseWikimediaImages(_ data: Data) throws -> [WikimediaImage] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MediaWiki answer is not a JSON object")
        }
        let pages = ((o["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []
        let ranked = pages.enumerated().sorted { a, b in
            let ia = a.element["index"] as? Int ?? Int.max, ib = b.element["index"] as? Int ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }
        return ranked.compactMap { _, page in
            guard let title = page["title"] as? String,
                  let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, ["image/jpeg", "image/png", "image/webp"].contains(mime),
                  let width = info["width"] as? Int, let height = info["height"] as? Int, min(width, height) >= 200,
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)), isPhotoURL(thumb) else { return nil }
            return WikimediaImage(title: title, thumbnailURL: thumb, width: width, height: height,
                                  pageURL: (info["descriptionurl"] as? String).flatMap(URL.init(webLink:)))
        }
    }

    // MARK: URLs

    static let wikipediaAPI = URL(string: "https://en.wikipedia.org/w/api.php")!
    static let commonsAPI = URL(string: "https://commons.wikimedia.org/w/api.php")!

    public static func deezerSearchURL(name: String) -> URL? {
        var c = URLComponents(string: "https://api.deezer.com/search/artist")!
        c.queryItems = [.init(name: "q", value: name), .init(name: "limit", value: "12")]
        return c.url
    }

    public static func deezerArtistURL(id: Int) -> URL? { URL(string: "https://api.deezer.com/artist/\(id)") }

    /// The Deezer artist ID of a deezer.com link ("https://www.deezer.com/artist/165408677", maybe with a language).
    public static func deezerArtistId(from url: URL) -> Int? {
        guard url.isWebLink, let host = url.host?.lowercased(), host == "deezer.com" || host.hasSuffix(".deezer.com") else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "artist"), i + 1 < parts.count, let id = Int(parts[i + 1]), id > 0 else { return nil }
        return id
    }

    static func imageInfoQuery(width: Int) -> [URLQueryItem] {
        [.init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
         .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|size|mime"),
         .init(name: "iiurlwidth", value: String(width))]
    }

    /// The images in an English Wikipedia article.
    public static func wikipediaImagesURL(title: String) -> URL? {
        var c = URLComponents(url: wikipediaAPI, resolvingAgainstBaseURL: false)!
        c.queryItems = imageInfoQuery(width: 300) + [.init(name: "titles", value: title), .init(name: "generator", value: "images"),
                                                     .init(name: "gimlimit", value: "50")]
        return c.url
    }

    /// Photos (bitmaps) on Wikimedia Commons matching a search.
    public static func commonsSearchURL(query: String) -> URL? {
        var c = URLComponents(url: commonsAPI, resolvingAgainstBaseURL: false)!
        c.queryItems = imageInfoQuery(width: 300) + [.init(name: "generator", value: "search"), .init(name: "gsrnamespace", value: "6"),
                                                     .init(name: "gsrsearch", value: "\(query) filetype:bitmap"),
                                                     .init(name: "gsrlimit", value: "24")]
        return c.url
    }

    /// One file's rendition at most `width` px wide (the original when it is smaller).
    public static func wikimediaFileURL(api: URL, file: String, width: Int) -> URL? {
        guard api == wikipediaAPI || api == commonsAPI else { return nil }
        var c = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        c.queryItems = imageInfoQuery(width: width) + [.init(name: "titles", value: file)]
        return c.url
    }

    /// "File:Domi and JD Beck at History (cropped).jpg" → "Domi and JD Beck at History (cropped)"
    static func displayName(_ file: String) -> String {
        let name = file.hasPrefix("File:") ? String(file.dropFirst(5)) : file
        return (name as NSString).deletingPathExtension
    }

    /// Wikimedia file titles compared loosely: "File:A_b.jpg" and "File:A b.jpg" are the same file.
    static func sameFile(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ").lowercased() }
        return norm(a) == norm(b)
    }
}

// MARK: Candidates

extension ArtistPhotoCandidate {
    public init(deezer a: ArtistPhotoParser.DeezerArtist, linked: Bool = false) {
        var detail = [linked ? "Deezer (linked on MusicBrainz)" : "Deezer"]
        if let fans = a.fans, fans > 0 { detail.append("\(fans.formatted()) fan\(fans == 1 ? "" : "s")") }
        if let albums = a.albums, albums > 0 { detail.append("\(albums.formatted()) album\(albums == 1 ? "" : "s")") }
        self.init(id: "deezer:\(a.id)", source: .deezer, title: a.name, detail: detail.joined(separator: " · "),
                  thumbnailURL: a.pictureMedium, imageURL: a.pictureXL, pageURL: a.link)
    }

    public init(wikimedia i: ArtistPhotoParser.WikimediaImage, source: Source, api: URL) {
        let label = source == .wikipedia ? "Wikipedia article" : source.rawValue
        self.init(id: "wm:\(i.title.replacingOccurrences(of: "_", with: " "))", source: source,
                  title: ArtistPhotoParser.displayName(i.title), detail: "\(label) · \(i.width) × \(i.height)",
                  thumbnailURL: i.thumbnailURL, wikiFile: i.title, wikiAPI: api, pageURL: i.pageURL)
    }
}

// MARK: Fetching

/// Finds photos for an artist on Deezer (artist pictures; no account or key) and Wikimedia (the artist's Wikipedia
/// article and a Commons search), and downloads them.
public struct ArtistPhotoFinder: Sendable {
    let get: InfoFetcher.Get

    public init(get: InfoFetcher.Get? = nil) { self.get = get ?? InfoFetcher.download }

    /// The photos the artist's info points to: their Deezer artist (from a MusicBrainz link) and the images in their
    /// Wikipedia article, the article's lead photo first. Failures just leave them out.
    public func linked(_ info: ArtistInfo) async -> [ArtistPhotoCandidate] {
        async let deezer = linkedDeezer(info)
        async let wikipedia = articleImages(info)
        return await deezer + wikipedia
    }

    /// Deezer artists and Commons photos matching a name. Throws only when both searches fail.
    public func search(_ name: String) async throws -> [ArtistPhotoCandidate] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        async let deezer = searchDeezer(query)
        async let commons = searchCommons(query)
        switch (await deezer, await commons) {
        case let (.failure(error), .failure): throw error
        case let (d, c): return ((try? d.get()) ?? []) + ((try? c.get()) ?? [])
        }
    }

    private func linkedDeezer(_ info: ArtistInfo) async -> [ArtistPhotoCandidate] {
        guard let id = info.links.lazy.compactMap({ ArtistPhotoParser.deezerArtistId(from: $0.url) }).first,
              let url = ArtistPhotoParser.deezerArtistURL(id: id), let data = try? await get(url),
              let artist = try? ArtistPhotoParser.parseDeezerArtist(data) else { return [] }
        return [ArtistPhotoCandidate(deezer: artist, linked: true)]
    }

    private func articleImages(_ info: ArtistInfo) async -> [ArtistPhotoCandidate] {
        guard let title = info.links.lazy.filter({ $0.kind == .wikipedia })
                .compactMap({ ArtistInfoParser.wikipediaTitle(from: $0.url) }).first,
              let url = ArtistPhotoParser.wikipediaImagesURL(title: title), let data = try? await get(url),
              var images = try? ArtistPhotoParser.parseWikimediaImages(data) else { return [] }
        if let lead = info.imageCreditURL?.lastPathComponent,
           let i = images.firstIndex(where: { ArtistPhotoParser.sameFile($0.title, lead) }) {
            images.insert(images.remove(at: i), at: 0)
        }
        return images.map { ArtistPhotoCandidate(wikimedia: $0, source: .wikipedia, api: ArtistPhotoParser.wikipediaAPI) }
    }

    private func searchDeezer(_ query: String) async -> Result<[ArtistPhotoCandidate], Error> {
        do {
            guard let url = ArtistPhotoParser.deezerSearchURL(name: query), let data = try await get(url) else { return .success([]) }
            return .success(try ArtistPhotoParser.parseDeezerSearch(data).map { ArtistPhotoCandidate(deezer: $0) })
        } catch { return .failure(error) }
    }

    private func searchCommons(_ query: String) async -> Result<[ArtistPhotoCandidate], Error> {
        do {
            guard let url = ArtistPhotoParser.commonsSearchURL(query: query), let data = try await get(url) else { return .success([]) }
            return .success(try ArtistPhotoParser.parseWikimediaImages(data).map {
                ArtistPhotoCandidate(wikimedia: $0, source: .commons, api: ArtistPhotoParser.commonsAPI)
            })
        } catch { return .failure(error) }
    }

    /// The candidate's thumbnail.
    public func thumbnail(_ c: ArtistPhotoCandidate) async throws -> Data? {
        guard ArtistPhotoParser.isPhotoURL(c.thumbnailURL) else { return nil }
        return try await get(c.thumbnailURL)
    }

    /// The candidate's photo, large enough to save (at most `width` px wide for Wikimedia files).
    public func image(for c: ArtistPhotoCandidate, width: Int = 1200) async throws -> Data? {
        var url = c.imageURL
        if url == nil, let file = c.wikiFile, let api = c.wikiAPI,
           let info = ArtistPhotoParser.wikimediaFileURL(api: api, file: file, width: width), let data = try await get(info) {
            url = try ArtistPhotoParser.parseWikimediaImages(data).first?.thumbnailURL
        }
        guard let url, ArtistPhotoParser.isPhotoURL(url) else { return nil }
        return try await get(url)
    }
}
