import Foundation

// The Shop's first search goes to Discogs, whose database lists far more CD and vinyl editions than MusicBrainz
// (especially records, and new, local and rare releases); MusicBrainz is asked only when Discogs finds nothing or
// can't be reached. Discogs releases come back as the Shop's `CDEdition`s (`discogs-<n>` ids, never MusicBrainz IDs)
// grouped by master into `CDAlbum`s, so the rest of the Shop picks them the same way, and the target carries its
// Discogs release and master straight to the store searches and the price guide.

/// Where the Shop found the albums it lists.
public enum CDSearchSource: String, Hashable, Sendable {
    case discogs, musicBrainz

    public var name: String { self == .discogs ? "Discogs" : "MusicBrainz" }
}

extension CDEdition {
    /// A Discogs release from a database search.
    public init(discogs e: CollectionEdition) {
        self.init(id: e.id, title: e.title, artist: e.artist, date: e.date, country: e.country, label: e.recordLabel,
                  catalogNumber: e.catalogNumber, barcode: e.barcode, format: e.formatDetail, trackCount: e.trackCount,
                  disambiguation: e.formatNotes, releaseGroupTitle: e.releaseGroupTitle)
        discogsReleaseID = e.discogsReleaseID
        discogsMasterID = e.discogsMasterID
        thumbnail = e.thumbnail
    }

    /// One of a master's versions (no barcode: Discogs' version list doesn't give it).
    public init(discogs v: DiscogsMarketParser.Version, masterID: Int, artist: String, format: ShopFormat) {
        let c = v.candidate
        self.init(id: CollectionEdition.discogsID(c.releaseID), title: c.title, artist: artist, date: c.year.map(String.init) ?? "",
                  country: c.country, label: v.label, catalogNumber: c.catalogNumbers.joined(separator: ", "),
                  format: c.notes.isEmpty ? format.name : c.notes, releaseGroupTitle: c.title)
        discogsReleaseID = c.releaseID
        discogsMasterID = masterID
        thumbnail = v.thumbnail
    }
}

public enum CDDiscogsSearch {
    /// Releases of the format grouped into albums by master (a release with no master is an album of its own), in the
    /// order the albums first appear (Discogs' best match first); each album's editions oldest first.
    public static func albums(_ editions: [CollectionEdition], format: ShopFormat) -> [CDAlbum] {
        var out: [CDAlbum] = []
        var index: [String: Int] = [:]
        var seen = Set<String>()
        for e in editions where e.isDiscogs && e.medium == format.medium && seen.insert(e.id).inserted {
            let edition = CDEdition(discogs: e)
            let key = e.discogsMasterID.map { "discogs-master-\($0)" } ?? e.id
            if let i = index[key] {
                out[i].editions.append(edition)
                if out[i].thumbnail == nil { out[i].thumbnail = edition.thumbnail }
            } else {
                index[key] = out.count
                var album = CDAlbum(id: key, title: e.releaseGroupTitle.isEmpty ? e.title : e.releaseGroupTitle, artist: e.artist,
                                    releaseType: "", editions: [edition])
                album.discogsMasterID = e.discogsMasterID
                album.thumbnail = edition.thumbnail
                out.append(album)
            }
        }
        for i in out.indices { out[i].editions = CDEditionParser.oldestFirst(out[i].editions) }
        return out
    }

    /// An artist's albums from a master search (editions not yet loaded): those credited to the artist typed (all of
    /// them when none is), albums first, then compilations, EPs and singles, oldest first within each.
    public static func albums(masters hits: [DiscogsMarketParser.Hit], artist: String) -> [CDAlbum] {
        var seen = Set<Int>()
        let masters = hits.filter { $0.releaseID == nil && $0.masterID.map { seen.insert($0).inserted } == true }
        let wanted = Set(CDOfferMatcher.words(artist))
        let theirs = masters.filter { !wanted.isEmpty && wanted.isSubset(of: Set(CDOfferMatcher.words($0.artist))) }
        let albums = (theirs.isEmpty ? masters : theirs).map { hit -> CDAlbum in
            var album = CDAlbum(id: "discogs-master-\(hit.masterID ?? 0)", title: hit.title, artist: hit.artist, releaseType: kind(hit.formats),
                                firstReleaseDate: hit.year.map(String.init) ?? "", editions: [], editionsLoaded: false)
            album.discogsMasterID = hit.masterID
            album.thumbnail = hit.thumbnail
            return album
        }
        func rank(_ a: CDAlbum) -> Int { ["Album", "", "Compilation", "EP", "Single"].firstIndex(of: a.releaseType) ?? 1 }
        return albums.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            let ya = a.element.year ?? Int.max, yb = b.element.year ?? Int.max
            return ya != yb ? ya < yb : a.offset < b.offset
        }.map(\.element)
    }

    /// "Compilation", "EP", "Single" or "Album" from a search result's format descriptions ("Vinyl", "LP", "Album");
    /// "" when they don't say.
    static func kind(_ formats: [String]) -> String {
        let f = Set(formats.map { $0.lowercased() })
        if f.contains("compilation") { return "Compilation" }
        if f.contains("ep") || f.contains("mini-album") { return "EP" }
        if f.contains("single") || f.contains("maxi-single") { return "Single" }
        if f.contains("album") || f.contains("lp") { return "Album" }
        return ""
    }

    /// The same UPC written the other way: 12 digits with a leading 0 added, or 13 starting with 0 without it.
    static func otherBarcode(_ digits: String) -> String? {
        if digits.count == 12 { return "0" + digits }
        if digits.count == 13, digits.hasPrefix("0") { return String(digits.dropFirst()) }
        return nil
    }
}

extension DiscogsCollectionClient {
    /// The Shop's search, as albums with their editions in the format: a barcode finds its releases (written either
    /// way), a catalog number (with the album and artist when typed) or the album and artist are field searches,
    /// then everything typed as free text when those find nothing; the artist alone lists their albums (masters,
    /// editions looked up when one is opened with `shopEditions`).
    public func shopAlbums(_ query: CDSearchQuery) async throws -> [CDAlbum] {
        func clip(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        let format = query.format, medium = query.format.medium
        let album = clip(query.album), artist = clip(query.artist), code = clip(query.code)
        if let barcode = query.barcode {
            var found = try await searchBarcode(barcode, medium: medium)
            if found.isEmpty, let other = CDDiscogsSearch.otherBarcode(barcode) { found = try await searchBarcode(other, medium: medium) }
            return CDDiscogsSearch.albums(found, format: format)
        }
        if album.isEmpty, code.isEmpty {
            guard !artist.isEmpty else { return [] }
            var params = ["type": "master", "artist": artist, "per_page": "100"]
            if let name = Self.format(medium) { params["format"] = name }
            let masters = CDDiscogsSearch.albums(masters: try DiscogsMarketParser.hits(try await send("GET", path: "/database/search", query: params)),
                                                 artist: artist)
            if !masters.isEmpty { return masters }
            // Releases that aren't versions of a master.
            return CDDiscogsSearch.albums(try await search(["artist": artist, "per_page": "100"], medium: medium), format: format)
        }
        var fields = ["per_page": "100"]
        if !album.isEmpty { fields["release_title"] = album }
        if !artist.isEmpty { fields["artist"] = artist }
        if !code.isEmpty { fields["catno"] = code }
        var found = try await search(fields, medium: medium)
        if found.isEmpty {
            // Fields match word for word; free text finds titles written another way.
            let words = [artist, album, code].filter { !$0.isEmpty }.joined(separator: " ")
            found = try await search(["q": words, "per_page": "100"], medium: medium)
        }
        return CDDiscogsSearch.albums(found, format: format)
    }

    /// A master's versions in the format, oldest first (at most `maxVersionPages` pages).
    public func shopEditions(masterID: Int, format: ShopFormat, artist: String) async throws -> [CDEdition] {
        let versions = try await marketVersions(masterID: masterID, medium: format.medium, pages: Self.maxVersionPages)
        return CDEditionParser.oldestFirst(versions.map { CDEdition(discogs: $0, masterID: masterID, artist: artist, format: format) })
    }
}
