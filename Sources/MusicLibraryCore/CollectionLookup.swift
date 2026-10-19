import Foundation

// Adding to the collection: what the user types in Add to Collection (artist and album, or a barcode) becomes a
// MusicBrainz release search filtered by medium, and the edition picked (or a library album) becomes an item.

/// What the user types to find a copy they own: artist and album words, or a barcode from the case or sleeve.
public struct CollectionReleaseQuery: Hashable, Sendable {
    public var text: String
    public var medium: CollectionMedium

    public init(text: String, medium: CollectionMedium) {
        self.text = text; self.medium = medium
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The digits when the text reads as a UPC/EAN barcode (8 to 14 digits, spaces and dashes allowed).
    public var barcode: String? { CDSearchQuery(code: text).barcode }

    /// The Lucene query for MusicBrainz's release search. A barcode is looked up with and without a leading zero
    /// (whatever the medium: the code says which release it is). Otherwise each word must start the release title or
    /// the artist (`loose`: any word), as in `CDSearchQuery`, with the medium's formats.
    public func luceneQuery(loose: Bool = false) -> String {
        if let barcode { return CDSearchQuery(code: barcode).luceneQuery() }
        let words = Self.words(text)
        guard !words.isEmpty else { return "" }
        let clauses = words.map { w -> String in
            let term = MusicBrainzClient.luceneEscape(w) + (w.count > 1 ? "*" : "")
            return "(release:\(term) OR artist:\(term))"
        }
        var parts = [clauses.count == 1 ? clauses[0] : "(" + clauses.joined(separator: loose ? " OR " : " AND ") + ")"]
        if let format = formatClause { parts.append(format) }
        return parts.joined(separator: " AND ")
    }

    /// The text as a catalog number ("CL 1355"), with the medium's formats: tried when the words find nothing.
    public func catalogNumberQuery() -> String? {
        let code = text.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, barcode == nil, code.contains(where: \.isNumber) else { return nil }
        let phrase = "catno:\"" + MusicBrainzClient.luceneEscape(code) + "\""
        return formatClause.map { phrase + " AND " + $0 } ?? phrase
    }

    /// MusicBrainz's format names are matched whole ("Vinyl" doesn't find "12\" Vinyl"), so each is listed. No
    /// filter for a download: one you bought is usually of a release listed as a CD.
    var formatClause: String? {
        let names: [String]
        switch medium {
        case .cd: names = ["CD", "Enhanced CD", "HDCD", "SHM-CD", "Blu-spec CD", "Hybrid SACD", "SACD"]
        case .vinyl: names = ["Vinyl", "12\" Vinyl", "10\" Vinyl", "7\" Vinyl"]
        case .download, .other: return nil
        }
        return "format:(" + names.map { "\"" + MusicBrainzClient.luceneEscape($0) + "\"" }.joined(separator: " OR ") + ")"
    }

    /// Lowercased words without punctuation; "the", "and"… only when there's nothing else.
    static func words(_ text: String) -> [String] {
        let all = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || "\"“”„«»()[]:,/&+!?".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'’.")) }
            .filter { !$0.isEmpty }
        let significant = all.filter { !Self.ignored.contains($0) }
        return significant.isEmpty ? all : significant
    }

    static let ignored: Set<String> = ["the", "a", "an", "and", "of", "by", "-"]
}

/// One release a copy may be: a MusicBrainz release with its media, labels and codes.
public struct CollectionEdition: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    /// "1959-08-17", "2010-05", "".
    public var date: String
    public var country: String
    public var recordLabel: String
    public var catalogNumber: String
    public var barcode: String
    /// "CD", "2×CD", "2×12\" Vinyl", "CD + DVD-Video".
    public var formatDetail: String
    public var discCount: Int
    public var trackCount: Int
    public var releaseGroupId: String?
    public var releaseGroupTitle: String
    /// From the media's formats; nil when none is known.
    public var medium: CollectionMedium?
    /// "Official", "Bootleg"…
    public var status: String

    public init(id: String, title: String, artist: String, date: String = "", country: String = "", recordLabel: String = "",
                catalogNumber: String = "", barcode: String = "", formatDetail: String = "", discCount: Int = 0,
                trackCount: Int = 0, releaseGroupId: String? = nil, releaseGroupTitle: String = "",
                medium: CollectionMedium? = nil, status: String = "") {
        self.id = id; self.title = title; self.artist = artist; self.date = date; self.country = country
        self.recordLabel = recordLabel; self.catalogNumber = catalogNumber; self.barcode = barcode
        self.formatDetail = formatDetail; self.discCount = discCount; self.trackCount = trackCount
        self.releaseGroupId = releaseGroupId; self.releaseGroupTitle = releaseGroupTitle; self.medium = medium
        self.status = status
    }

    public var year: Int? { date.count >= 4 ? Int(date.prefix(4)) : nil }

    /// What results are grouped by: the release group, else the release itself.
    public var groupKey: String { releaseGroupId ?? id }
}

public enum CollectionEditionParser {
    /// The releases in a MusicBrainz release search, in its order (best match first). With a `medium`, only those
    /// with a medium of it; downloads take any release, since one you bought is usually of a CD release.
    public static func parseSearch(_ data: Data, medium: CollectionMedium? = nil) throws -> [CollectionEdition] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz search is not a JSON object")
        }
        let all = (root["releases"] as? [[String: Any]] ?? []).compactMap(edition)
        switch medium {
        case nil, .download?: return all
        case let wanted?: return all.filter { $0.medium == wanted }
        }
    }

    static func edition(_ r: [String: Any]) -> CollectionEdition? {
        guard let id = MBID.validated(r["id"] as? String) else { return nil }
        let media = r["media"] as? [[String: Any]] ?? []
        let formats = media.map { $0["format"] as? String ?? "" }
        let labels = r["label-info"] as? [[String: Any]] ?? []
        let group = r["release-group"] as? [String: Any]
        let tracks = (r["track-count"] as? Int) ?? media.reduce(0) { $0 + ($1["track-count"] as? Int ?? 0) }
        return CollectionEdition(
            id: id, title: r["title"] as? String ?? "", artist: MusicBrainzParser.creditString(r["artist-credit"]),
            date: r["date"] as? String ?? "", country: r["country"] as? String ?? "",
            recordLabel: MusicBrainzParser.joinedUnique(labels.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }),
            catalogNumber: MusicBrainzParser.joinedUnique(labels.compactMap { $0["catalog-number"] as? String }),
            barcode: r["barcode"] as? String ?? "", formatDetail: formats.isEmpty ? "" : CDEditionParser.formatSummary(formats),
            discCount: media.count, trackCount: tracks, releaseGroupId: MBID.validated(group?["id"] as? String),
            releaseGroupTitle: group?["title"] as? String ?? "", medium: CollectionMedium(musicBrainzFormats: formats),
            status: r["status"] as? String ?? "")
    }

    /// A barcode search's editions with those of `medium` first (a CD scanned while adding vinyl still shows).
    static func preferring(_ medium: CollectionMedium, _ editions: [CollectionEdition]) -> [CollectionEdition] {
        guard medium != .download else { return editions }
        return editions.filter { $0.medium == medium } + editions.filter { $0.medium != medium }
    }
}

extension MusicBrainzClient {
    /// Editions matching what the user typed, at most 100: a barcode lookup, else the words (all of them, then any),
    /// then the text as a catalog number.
    public func searchEditions(_ query: CollectionReleaseQuery) async throws -> [CollectionEdition] {
        func search(_ lucene: String, medium: CollectionMedium?) async throws -> [CollectionEdition] {
            guard !lucene.isEmpty, var c = URLComponents(string: "\(Self.baseURL)/release") else { return [] }
            c.queryItems = [.init(name: "query", value: lucene), .init(name: "fmt", value: "json"), .init(name: "limit", value: "100")]
            guard let url = c.url else { return [] }
            return try CollectionEditionParser.parseSearch(try await fetchData(url), medium: medium)
        }
        if query.barcode != nil {
            return CollectionEditionParser.preferring(query.medium, try await search(query.luceneQuery(), medium: nil))
        }
        var found = try await search(query.luceneQuery(), medium: query.medium)
        if found.isEmpty { found = try await search(query.luceneQuery(loose: true), medium: query.medium) }
        if found.isEmpty, let catno = query.catalogNumberQuery() { found = try await search(catno, medium: query.medium) }
        return found
    }
}

/// New items, before the user fills in the rest.
public enum CollectionDraft {
    /// An item for the edition picked, bought today, keyed as its rip would be (`SearchIndex.albumKey` of the
    /// release's title and artist).
    public static func item(from edition: CollectionEdition, medium: CollectionMedium, sticker: Int?, now: Date = Date()) -> CollectionItem {
        var item = CollectionItem(medium: medium, album: clip(edition.title, 1000), artist: clip(edition.artist, 1000), now: now)
        item.stickerNumber = sticker
        item.year = edition.year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        item.releaseID = MBID.validated(edition.id)
        item.releaseGroupID = MBID.validated(edition.releaseGroupId)
        item.barcode = barcode(edition.barcode)
        item.catalogNumber = field(edition.catalogNumber)
        item.recordLabel = field(edition.recordLabel)
        item.country = field(edition.country)
        item.formatDetail = field(edition.formatDetail)
        item.discCount = (1...99).contains(edition.discCount) ? edition.discCount : nil
        item.trackCount = (1...999).contains(edition.trackCount) ? edition.trackCount : nil
        item.purchasedOn = PurchaseDay(now)
        return item
    }

    /// An item for a library album you own a copy of, linked to it. The release group, year and record label come
    /// from the tracks' tags; the release, barcode, catalog number and media only when the tags' media are of the
    /// same medium (a record's barcode isn't the CD's the tracks were ripped from). The cover stays the album's.
    public static func item(album: AlbumSummary, tracks: [Track], medium: CollectionMedium, sticker: Int?, now: Date = Date()) -> CollectionItem {
        let key = SearchIndex.albumKey(album: album.album, artist: album.artist)
        var item = CollectionItem(medium: medium, album: clip(album.album, 1000), artist: clip(album.artist, 1000), albumKey: key, now: now)
        item.stickerNumber = sticker
        func common(_ values: [String]) -> String? {
            CollectionLinker.mostCommon(values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        let x = tracks.map(\.metadata.extended)
        item.year = CollectionLinker.mostCommon(tracks.compactMap(\.year).filter { (1000...9999).contains($0) }) ?? album.year
        item.releaseGroupID = CollectionLinker.mostCommon(x.compactMap { MBID.validated($0.mbReleaseGroupId) })
        item.recordLabel = common(x.map(\.label)).flatMap(field)
        let tagged = common(x.map(\.mediaFormat))
        if tagged.map({ CollectionMedium(musicBrainzFormats: [$0]) == medium }) ?? true {
            item.releaseID = CollectionLinker.mostCommon(tracks.compactMap { MBID.validated($0.metadata.mbReleaseId) })
            item.barcode = common(x.map(\.barcode)).flatMap(barcode)
            item.catalogNumber = common(x.map(\.catalogNumber)).flatMap(field)
            item.country = common(x.map(\.releaseCountry)).flatMap(field)
            item.formatDetail = tagged.flatMap(field)
            let discs = tracks.compactMap { $0.metadata.discTotal ?? $0.metadata.discNo }.max()
            item.discCount = discs.flatMap { (1...99).contains($0) ? $0 : nil }
            let perDisc = Dictionary(grouping: tracks) { $0.metadata.discNo ?? 1 }
                .mapValues { list in max(list.count, list.compactMap(\.metadata.trackTotal).filter { (1...999).contains($0) }.max() ?? 0) }
            let total = perDisc.values.reduce(0, +)
            item.trackCount = (1...999).contains(total) ? total : nil
        }
        if !tracks.isEmpty {
            item.digitalSource = switch medium {
            case .cd: .rip
            case .download: .download
            default: .same
            }
        }
        return item
    }

    static func clip(_ s: String, _ limit: Int) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }

    /// Trimmed, at most 200 characters, nil when empty (as `collection_items` reads them back).
    static func field(_ s: String) -> String? {
        let t = clip(s, 200)
        return t.isEmpty ? nil : t
    }

    /// Digits only, 6 to 20 of them.
    static func barcode(_ s: String) -> String? {
        let digits = s.filter { ("0"..."9").contains($0) }
        return (6...20).contains(digits.count) ? digits : nil
    }
}
