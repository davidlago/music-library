import Foundation

// MARK: In your library?

/// Finds the library album a catalog title corresponds to. Catalog records and library tags spell albums
/// differently ("Hamilton: original Broadway cast recording" by "Miranda, Lin-Manuel, 1980-" vs
/// "Hamilton: An American Musical" by "Lin‐Manuel Miranda"), so it matches on the MusicBrainz release group
/// once the title has been looked up, and otherwise on normalized titles with a compatible artist.
public struct CatalogOwnership: Sendable {
    struct Entry: Sendable {
        var album: AlbumSummary
        var artistTokens: Set<String>
    }

    private var byTitle: [String: [Entry]] = [:]
    private var byReleaseGroup: [String: AlbumSummary] = [:]

    public static let empty = CatalogOwnership(albums: [], releaseGroups: [:])

    /// `releaseGroups` maps MusicBrainz release group IDs to the library album tagged with them.
    public init(albums: [AlbumSummary], releaseGroups: [String: AlbumSummary]) {
        byReleaseGroup = releaseGroups
        for album in albums where !album.album.isEmpty {
            let entry = Entry(album: album, artistTokens: Self.tokens(album.artist))
            for form in Set(Self.albumForms(album.album)) { byTitle[form, default: []].append(entry) }
        }
    }

    public var isEmpty: Bool { byTitle.isEmpty && byReleaseGroup.isEmpty }

    public func album(for item: CatalogItem, details: CatalogAlbumDetails? = nil) -> AlbumSummary? {
        if let rg = details?.releaseGroupId, let album = byReleaseGroup[rg] { return album }
        var artists = [item.artist]
        if let a = details?.mbArtist { artists.append(a) }
        if let found = album(title: item.title, subtitle: item.subtitle, artists: artists) { return found }
        if let t = details?.mbTitle { return album(title: t, subtitle: nil, artists: artists) }
        return nil
    }

    public func album(for checkout: CatalogCheckout) -> AlbumSummary? {
        album(title: checkout.title, subtitle: checkout.subtitle, artists: [checkout.artist])
    }

    func album(title: String, subtitle: String?, artists: [String]) -> AlbumSummary? {
        let wanted = artists.map(Self.tokens).filter { !$0.isEmpty }
        let main = CatalogText.key(title)
        var forms: [(key: String, exact: Bool)] = []
        if let subtitle, !subtitle.isEmpty {
            forms.append((CatalogText.key("\(title) \(subtitle)"), true))
            // "Anthology: 4" is not "Anthology"; "Abbey Road: remastered" is.
            if !Self.isNumbering(subtitle) { forms.append((main, false)) }
        } else {
            forms.append((main, true))
        }
        for (key, exact) in forms where !key.isEmpty {
            for entry in byTitle[key] ?? [] {
                if wanted.isEmpty {
                    if exact { return entry.album }
                } else if wanted.contains(where: { Self.compatible($0, entry.artistTokens) }) {
                    return entry.album
                }
            }
        }
        return nil
    }

    /// An album title, with and without trailing "(Deluxe Edition)", "[Remastered]" or ": subtitle".
    static func albumForms(_ album: String) -> [String] {
        var forms = [CatalogText.key(album)]
        var s = album.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression), r.lowerBound > s.startIndex {
            s.removeSubrange(r)
            forms.append(CatalogText.key(s))
        }
        for separator in [": ", " - "] {
            if let r = s.range(of: separator), r.lowerBound > s.startIndex {
                forms.append(CatalogText.key(String(s[..<r.lowerBound])))
            }
        }
        return forms.filter { !$0.isEmpty }
    }

    static func isNumbering(_ subtitle: String) -> Bool {
        CatalogText.key(subtitle).range(of: #"^((vol|volume|part|pt|no|disc|book|chapter) )?(\d+|[ivx]+)$"#, options: .regularExpression) != nil
    }

    static func tokens(_ name: String) -> Set<String> {
        Set(CatalogText.key(name).split(separator: " ").map(String.init))
    }

    /// "Beatles" and "The Beatles", "Lin-Manuel Miranda" and "Lin‐Manuel Miranda", "Bob Marley" and
    /// "Bob Marley & The Wailers".
    static func compatible(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.isSubset(of: b) || b.isSubset(of: a)
    }
}

// MARK: Album details

/// What the app knows about a catalog title beyond the results page: its editions (with UPCs) from the catalog,
/// and the MusicBrainz release they correspond to with its track list, genres, rating and description.
/// Cached in the library database (`catalog_info`).
public struct CatalogAlbumDetails: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable { case barcode, search }

    public var workId: String
    public var editions: [CatalogEdition] = []
    public var releaseId: String?
    public var releaseGroupId: String?
    public var mbTitle: String?
    public var mbArtist: String?
    public var releaseDate: String?
    public var label: String?
    public var catalogNumber: String?
    public var barcode: String?
    public var media: String?
    public var match: Match?
    public var album: AlbumInfo?
    public var fetchedAt: Date
    /// The `CatalogEnricher.version` that looked the title up (nil before versions).
    public var version: Int?

    public init(workId: String, fetchedAt: Date = Date()) {
        self.workId = workId
        self.fetchedAt = fetchedAt
    }

    public var isMatched: Bool { releaseId != nil || releaseGroupId != nil }

    /// Not matched by an older enricher that the current one may do better on, so worth looking up again now.
    public var isOutdatedMiss: Bool {
        guard !isMatched, (version ?? 1) < CatalogEnricher.version else { return false }
        return editions.contains { $0.upc.map(CatalogText.isTruncatedUPC) ?? false }
    }

    /// The original release year, falling back to this release's.
    public var year: Int? { album?.firstReleaseYear ?? releaseDate.flatMap { Int($0.prefix(4)) } }

    public var tracklist: [TracklistEntry] { album?.tracklist ?? [] }
}

/// A release in a MusicBrainz release search or browse.
public struct MBReleaseSummary: Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String?
    public var barcode: String?
    public var releaseGroupId: String?
    public var formats: [String]
    public var trackCount: Int
    public var label: String?
    public var catalogNumber: String?
    public var score: Int?

    public var isCD: Bool { !formats.isEmpty && formats.allSatisfy { $0.contains("CD") } }

    /// Any of its media is a record ("Vinyl", "12\" Vinyl", "7\"").
    public var isVinyl: Bool { medium == .vinyl }

    /// What a copy of it is (`CollectionMedium(musicBrainzFormats:)`); nil when no format is known.
    public var medium: CollectionMedium? { CollectionMedium(musicBrainzFormats: formats) }

    /// "2×CD", "CD".
    public var mediaLabel: String? {
        guard let f = formats.first else { return nil }
        return formats.allSatisfy { $0 == f } && formats.count > 1 ? "\(formats.count)×\(f)" : formats.joined(separator: " + ")
    }
}

extension MusicBrainzParser {
    public static func parseReleaseList(_ data: Data) throws -> [MBReleaseSummary] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz release list is not a JSON object")
        }
        return (o["releases"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = MBID.validated(r["id"] as? String), let title = r["title"] as? String else { return nil }
            let media = r["media"] as? [[String: Any]] ?? []
            let label = (r["label-info"] as? [[String: Any]])?.first
            func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return MBReleaseSummary(
                id: id, title: title, artist: creditString(r["artist-credit"]), date: str(r["date"]),
                barcode: str(r["barcode"]), releaseGroupId: MBID.validated((r["release-group"] as? [String: Any])?["id"] as? String),
                formats: media.compactMap { $0["format"] as? String },
                trackCount: r["track-count"] as? Int ?? media.reduce(0) { $0 + ($1["track-count"] as? Int ?? 0) },
                label: str((label?["label"] as? [String: Any])?["name"]), catalogNumber: str(label?["catalog-number"]),
                score: (r["score"] as? Int) ?? Int(r["score"] as? String ?? ""))
        }
    }

    /// The release that best fits a catalog edition: a confident match on CD, from the edition's year if one
    /// is, otherwise the earliest.
    public static func bestRelease(_ releases: [MBReleaseSummary], year: Int?, minScore: Int = 90) -> MBReleaseSummary? {
        let confident = releases.filter { ($0.score ?? 100) >= minScore }
        let pool = confident.contains(where: \.isCD) ? confident.filter(\.isCD) : confident
        func releaseYear(_ r: MBReleaseSummary) -> Int? { r.date.flatMap { Int($0.prefix(4)) } }
        if let year, let sameYear = pool.filter({ releaseYear($0) == year }).min(by: { ($0.date ?? "") < ($1.date ?? "") }) {
            return sameYear
        }
        return pool.min { ($0.date ?? "9999") < ($1.date ?? "9999") }
    }
}

extension MusicBrainzClient {
    /// Releases with any of these barcodes.
    public func searchReleases(barcodes: [String]) async throws -> [MBReleaseSummary] {
        guard !barcodes.isEmpty else { return [] }
        var c = URLComponents(string: "\(Self.baseURL)/release")!
        c.queryItems = [.init(name: "query", value: "barcode:(\(barcodes.joined(separator: " OR ")))"),
                        .init(name: "fmt", value: "json"), .init(name: "limit", value: "10")]
        return try MusicBrainzParser.parseReleaseList(try await fetchData(c.url!))
    }

    /// The releases of a release group (with media and labels).
    public func browseReleases(releaseGroupId: String) async throws -> [MBReleaseSummary] {
        guard let mbid = MBID.validated(releaseGroupId) else { throw NetworkError.badResponse("not a MusicBrainz release group ID") }
        var c = URLComponents(string: "\(Self.baseURL)/release")!
        c.percentEncodedQuery = "release-group=\(mbid)&inc=media+labels+artist-credits&limit=50&fmt=json"
        return try MusicBrainzParser.parseReleaseList(try await fetchData(c.url!))
    }
}

/// Looks a catalog title up: its editions (and UPCs) from the catalog, then the MusicBrainz release by barcode,
/// falling back to a release group search on title and artist, then the album info for that release.
public struct CatalogEnricher: Sendable {
    /// Bumped when matching improves. 2: truncated UPCs are completed with their check digit.
    public static let version = 2

    /// GETs a path on the catalog site.
    public typealias CatalogGet = @Sendable (String) async throws -> Data

    let catalog: CatalogGet
    let musicBrainz: MusicBrainzClient
    let info: InfoFetcher

    public init(catalog: @escaping CatalogGet, musicBrainz: MusicBrainzClient, info: InfoFetcher) {
        self.catalog = catalog
        self.musicBrainz = musicBrainz
        self.info = info
    }

    #if os(macOS)
    public func details(for item: CatalogItem, now: Date = Date()) async throws -> CatalogAlbumDetails {
        var details = CatalogAlbumDetails(workId: item.id, fetchedAt: now)
        details.version = Self.version
        if let variation = item.variationId {
            details.editions = try CatalogParser.parseEditions(try await catalog(CatalogPaths.editions(workId: item.id, variationId: variation)))
        }
        // The edition shown in the results first, then the others.
        let editions = details.editions.filter { $0.recordId == item.recordId } + details.editions.filter { $0.recordId != item.recordId }
        var tried = Set<String>()
        for edition in editions where tried.count < 3 {
            guard let upc = edition.upc, tried.insert(upc).inserted else { continue }
            let releases = try await musicBrainz.searchReleases(barcodes: CatalogText.barcodeVariants(upc))
            if let release = MusicBrainzParser.bestRelease(releases, year: edition.year ?? item.year) {
                apply(release, to: &details, match: .barcode)
                break
            }
        }
        if !details.isMatched {
            try await searchByTitle(item, into: &details)
        }
        guard details.isMatched else { return details }
        details.album = try await info.fetchAlbum(title: details.mbTitle ?? item.displayTitle, artist: details.mbArtist ?? item.artist,
                                                  releaseGroupId: details.releaseGroupId, releaseId: details.releaseId)
        return details
    }
    #endif

    func apply(_ release: MBReleaseSummary, to details: inout CatalogAlbumDetails, match: CatalogAlbumDetails.Match) {
        details.releaseId = release.id
        details.releaseGroupId = release.releaseGroupId ?? details.releaseGroupId
        details.mbTitle = release.title
        details.mbArtist = release.artist.isEmpty ? details.mbArtist : release.artist
        details.releaseDate = release.date
        details.label = release.label
        details.catalogNumber = release.catalogNumber
        details.barcode = release.barcode
        details.media = release.mediaLabel
        details.match = match
    }

    /// A release group with the catalog title (with or without its subtitle) by a compatible artist, and its
    /// earliest CD release for the track list.
    func searchByTitle(_ item: CatalogItem, into details: inout CatalogAlbumDetails) async throws {
        let titles = [item.subtitle.map { "\(item.title): \($0)" }, item.title].compactMap { $0 }
        let wantedTitles = Set(titles.map(CatalogText.key))
        let artist = CatalogOwnership.tokens(item.artist)
        for title in titles {
            let groups = try await musicBrainz.searchReleaseGroups(title: title, artist: item.artist)
            let match = groups.first { rg in
                (rg.score ?? 100) >= 85 && wantedTitles.contains(CatalogText.key(rg.title))
                    && (artist.isEmpty ? CatalogText.key(rg.artist) == "various artists" : CatalogOwnership.compatible(artist, CatalogOwnership.tokens(rg.artist)))
            }
            guard let rg = match else { continue }
            details.releaseGroupId = rg.id
            details.mbTitle = rg.title
            details.mbArtist = rg.artist
            details.match = .search
            let releases = try await musicBrainz.browseReleases(releaseGroupId: rg.id)
            if let release = MusicBrainzParser.bestRelease(releases, year: item.year, minScore: 0) {
                apply(release, to: &details, match: .search)
                details.releaseGroupId = rg.id
            }
            return
        }
    }
}
