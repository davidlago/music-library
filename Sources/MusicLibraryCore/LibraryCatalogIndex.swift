import Foundation

// MARK: Downloaded catalog

/// A title in the downloaded catalog: the latest results-page data for it, which downloaded libraries own a
/// copy, and when it was first and last seen. Stored in the library database (`catalog_items`).
public struct CatalogRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String { item.id }
    public var item: CatalogItem
    /// Downloaded libraries that own a copy.
    public var libraries: [String]
    /// When the app first saw the title; nil for titles found by the first download (their date is unknown).
    public var firstSeen: Date?
    public var lastSeen: Date
    /// Position in the catalog's "recently added" order at the last download (0 is the newest).
    public var addedRank: Int

    public init(item: CatalogItem, libraries: [String], firstSeen: Date?, lastSeen: Date, addedRank: Int) {
        self.item = item; self.libraries = libraries; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.addedRank = addedRank
    }

    public struct MergeResult: Sendable {
        public var changed: [CatalogRecord]
        public var removed: [String]
    }

    /// Folds a complete download of one library (newest first) into the stored records: titles it no longer
    /// owns lose that library, and titles no downloaded library owns are removed. On the very first download
    /// `firstSeen` stays unknown; afterwards new titles are dated, so `added:30d` finds new arrivals.
    public static func merge(_ existing: [String: CatalogRecord], scanned: [CatalogItem], library: String,
                             firstDownload: Bool, now: Date = Date()) -> MergeResult {
        var records = existing
        let upserted = upsert(existing, page: scanned, library: library, startRank: 0, firstDownload: firstDownload, now: now)
        for r in upserted { records[r.id] = r }
        let pruned = prune(records, seen: Set(scanned.map(\.id)), library: library)
        var changed = Dictionary(uniqueKeysWithValues: upserted.map { ($0.id, $0) })
        for r in pruned.changed { changed[r.id] = r }
        return MergeResult(changed: Array(changed.values), removed: pruned.removed)
    }

    /// The records for one scanned page (its first title at `startRank` in the "recently added" order).
    public static func upsert(_ existing: [String: CatalogRecord], page: [CatalogItem], library: String, startRank: Int,
                              firstDownload: Bool, now: Date = Date()) -> [CatalogRecord] {
        var out: [String: CatalogRecord] = [:]
        for (offset, item) in page.enumerated() where out[item.id] == nil {
            let rank = startRank + offset
            if var record = existing[item.id] {
                record.item = item
                if !record.libraries.contains(library) { record.libraries.append(library) }
                record.lastSeen = now
                record.addedRank = record.libraries == [library] ? rank : min(record.addedRank, rank)
                out[item.id] = record
            } else {
                out[item.id] = CatalogRecord(item: item, libraries: [library], firstSeen: firstDownload ? nil : now,
                                             lastSeen: now, addedRank: rank)
            }
        }
        return Array(out.values)
    }

    /// After a complete scan of `library`: titles it didn't list lose that library, and those no downloaded
    /// library owns any more are removed.
    public static func prune(_ existing: [String: CatalogRecord], seen: Set<String>, library: String) -> MergeResult {
        var changed: [CatalogRecord] = []
        var removed: [String] = []
        for (id, record) in existing where !seen.contains(id) && record.libraries.contains(library) {
            var r = record
            r.libraries.removeAll { $0 == library }
            if r.libraries.isEmpty { removed.append(id) } else { changed.append(r) }
        }
        return MergeResult(changed: changed, removed: removed.sorted())
    }
}

// MARK: Searching it

/// Orders for the downloaded catalog.
public enum CatalogLocalSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case relevance, recentlyAdded, artist, title, newest, oldest, rating

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: "Best Match"
        case .recentlyAdded: "Recently Added"
        case .artist: "Artist"
        case .title: "Title"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .rating: "Rating"
        }
    }
}

/// A search of the downloaded catalog in the app's query language (`genre:jazz year:1955-1965 -is:owned`),
/// plus filters only the catalog has.
public struct CatalogSearchQuery: Equatable, Sendable {
    public enum Flag: String, CaseIterable, Sendable {
        /// Already in your music library.
        case owned
        /// On the shelf at the catalog site's library.
        case available
        /// Not on the shelf there (checked out, on order…).
        case out
        /// On your list.
        case onList = "onlist"
    }

    public struct Filter: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case flag(Flag)
            case library(String)
            case rating(SearchQuery.NumberRange)
        }

        public var kind: Kind
        public var negated: Bool

        public init(kind: Kind, negated: Bool) { self.kind = kind; self.negated = negated }
    }

    /// The parts the app's query language covers.
    public var base: SearchQuery
    /// Catalog-only filters, all of which must hold.
    public var filters: [Filter]

    public var isEmpty: Bool { base.isEmpty && filters.isEmpty }
    public var issues: [String] { base.issues }

    static let flagAliases: [String: Flag] = [
        "owned": .owned, "mine": .owned, "inlibrary": .owned, "have": .owned,
        "available": .available, "onshelf": .available, "in": .available,
        "out": .out, "checkedout": .out, "unavailable": .out,
        "onlist": .onList, "listed": .onList, "list": .onList,
    ]

    /// Catalog-only keys and the help shown for them.
    public static let keys: [(name: String, example: String, help: String)] = [
        ("is", "is:owned", "owned (in your library), available (on the shelf), out, onlist"),
        ("library", "library:acton", "Owned by this library"),
        ("rating", "rating:>=4", "MusicBrainz community rating, 0–5"),
    ]

    public static func parse(_ text: String, now: Date = Date()) -> CatalogSearchQuery {
        var filters: [Filter] = []
        var rest = ""
        for token in SearchTokenizer.tokenize(text) {
            let key = token.key?.lowercased()
            let value = token.value.trimmingCharacters(in: .whitespaces)
            if key == "is", let flag = flagAliases[value.lowercased().replacingOccurrences(of: "-", with: "")] {
                filters.append(Filter(kind: .flag(flag), negated: token.negated))
            } else if key == "library" || key == "at", !value.isEmpty {
                filters.append(Filter(kind: .library(value), negated: token.negated))
            } else if key == "rating" || key == "stars", let range = ratingRange(value) {
                filters.append(Filter(kind: .rating(range), negated: token.negated))
            } else {
                rest += String(text[token.range]) + " "
            }
        }
        return CatalogSearchQuery(base: SearchQuery.parse(rest, now: now), filters: filters)
    }

    static func ratingRange(_ raw: String) -> SearchQuery.NumberRange? {
        var s = raw
        var op = ""
        for prefix in [">=", "<=", ">", "<", "="] where s.hasPrefix(prefix) {
            op = prefix
            s.removeFirst(prefix.count)
            break
        }
        if s.contains("-"), op.isEmpty {
            let parts = s.split(separator: "-").compactMap { Double($0) }
            return parts.count == 2 ? .init(lower: parts[0], upper: parts[1]) : nil
        }
        guard let v = Double(s) else { return nil }
        switch op {
        case ">": return .init(lower: v, lowerInclusive: false)
        case ">=": return .init(lower: v)
        case "<": return .init(upper: v, upperInclusive: false)
        case "<=": return .init(upper: v)
        default: return .init(lower: v, upper: v + 0.99)
        }
    }
}

/// What a search can't know from the records alone: which titles you own or have listed.
public struct CatalogSearchContext: Sendable {
    public var owned: Set<String>
    public var onList: Set<String>
    public var siteLibrary: String?

    public init(owned: Set<String> = [], onList: Set<String> = [], siteLibrary: String? = nil) {
        self.owned = owned; self.onList = onList; self.siteLibrary = siteLibrary
    }
}

public struct CatalogSearchResult: Sendable {
    public var records: [CatalogRecord]
    /// The most common genres and decades among the results, for narrowing them down.
    public var genres: [(name: String, count: Int)]
    public var decades: [(decade: Int, count: Int)]

    public static let empty = CatalogSearchResult(records: [], genres: [], decades: [])
}

/// The downloaded catalog, searchable like the music library. Text comes from the catalog record and, once a
/// title has been looked up, from MusicBrainz: release title and artist, track titles and artists, genres,
/// label and media.
public struct CatalogIndex: Sendable {
    struct Entry: Sendable {
        var record: CatalogRecord
        var details: CatalogAlbumDetails?
        var all: IndexedText
        var album: IndexedText
        var title: IndexedText
        var artist: IndexedText
        var albumArtist: IndexedText
        var genre: IndexedText
        var label: IndexedText
        var person: IndexedText
        var format: IndexedText
        var genres: [String]
        var year: Int?
        var length: Double?
        var trackCount: Int
        var discCount: Int
        var rating: Double?
        var sortTitle: String
        var sortArtist: String
    }

    let entries: [Entry]

    public static let empty = CatalogIndex(records: [], details: [:])

    public var count: Int { entries.count }

    public init(records: [CatalogRecord], details: [String: CatalogAlbumDetails]) {
        entries = records.map { Self.entry($0, details[$0.id]) }
    }

    /// Built step by step with explicit types: as one expression it's too much for the type checker.
    static func entry(_ r: CatalogRecord, _ d: CatalogAlbumDetails?) -> Entry {
        let info: AlbumInfo? = d?.album
        let item: CatalogItem = r.item
        let tracks: [TracklistEntry] = info?.tracklist ?? []
        let trackTitles: [String] = tracks.map(\.title)
        let albumTitles: [String] = [item.title, item.subtitle ?? "", d?.mbTitle ?? ""]
        let albumArtists: [String] = [item.artist, item.author ?? "", d?.mbArtist ?? ""]
        let trackArtists: [String] = Array(Set(tracks.map(\.artist)))
        let allArtists: [String] = albumArtists + trackArtists
        let genres: [String] = info?.genres ?? []
        let length: Double = tracks.compactMap(\.duration).reduce(0, +)
        var all: [String] = albumTitles
        all += allArtists
        all += trackTitles
        all += genres
        all += [d?.label ?? "", item.series ?? "", item.callNumber ?? "", info?.typeLabel ?? ""]
        let sortArtist: String = item.artist.isEmpty ? (d?.mbArtist ?? "") : item.artist
        return Entry(
            record: r, details: d, all: IndexedText(all), album: IndexedText(albumTitles), title: IndexedText(trackTitles),
            artist: IndexedText(allArtists), albumArtist: IndexedText(albumArtists), genre: IndexedText(genres),
            label: IndexedText([d?.label ?? ""]), person: IndexedText(allArtists),
            format: IndexedText([d?.media ?? "", "cd"]), genres: genres, year: d?.year ?? item.year,
            length: length > 0 ? length : nil, trackCount: tracks.count, discCount: Set(tracks.map(\.disc)).count,
            rating: info?.rating, sortTitle: CatalogText.key(item.displayTitle), sortArtist: CatalogText.key(sortArtist))
    }

    /// The records matching `query` that are owned by any of `libraries` (all when nil), in `sort` order.
    public func search(_ query: CatalogSearchQuery, libraries: Set<String>? = nil, context: CatalogSearchContext = .init(),
                       sort: CatalogLocalSort = .relevance, now: Date = Date()) -> CatalogSearchResult {
        let groups = query.base.groups.map { $0.map(SearchIndex.CompiledTerm.init) }
        var matched: [(Entry, Int)] = []
        for e in entries {
            if let libraries, !e.record.libraries.contains(where: libraries.contains) { continue }
            guard query.filters.allSatisfy({ matches($0, e, context) }) else { continue }
            if !groups.isEmpty, !groups.contains(where: { $0.allSatisfy { term in matches(term, e, now: now) } }) { continue }
            matched.append((e, relevance(e, query.base.rankingPhrases)))
        }
        let sorted = order(matched, sort, hasText: !query.base.rankingPhrases.isEmpty)
        var genreCounts: [String: (String, Int)] = [:]
        var decadeCounts: [Int: Int] = [:]
        for e in sorted {
            for g in Set(e.genres.map { $0.lowercased() }) {
                genreCounts[g, default: (e.genres.first { $0.lowercased() == g } ?? g, 0)].1 += 1
            }
            if let y = e.year { decadeCounts[y / 10 * 10, default: 0] += 1 }
        }
        let genres = genreCounts.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map { (name: $0.0, count: $0.1) }
        let decades = decadeCounts.sorted { $0.key > $1.key }.map { (decade: $0.key, count: $0.value) }
        return CatalogSearchResult(records: sorted.map(\.record), genres: genres, decades: decades)
    }

    // MARK: Matching

    func matches(_ filter: CatalogSearchQuery.Filter, _ e: Entry, _ context: CatalogSearchContext) -> Bool {
        let id = e.record.id
        let result: Bool
        switch filter.kind {
        case .flag(.owned): result = context.owned.contains(id)
        case .flag(.onList): result = context.onList.contains(id)
        case .flag(.available): result = e.record.item.availability == .here
        case .flag(.out): result = e.record.item.availability != .here
        case .library(let name):
            let wanted = CatalogText.key(name)
            result = e.record.libraries.contains { CatalogText.key($0) == wanted || CatalogText.key($0).hasPrefix(wanted + " ") }
        case .rating(let range): result = e.rating.map(range.contains) ?? false
        }
        return result != filter.negated
    }

    func matches(_ term: SearchIndex.CompiledTerm, _ e: Entry, now: Date) -> Bool {
        let result: Bool
        switch term.term.predicate {
        case .text: result = e.all.contains(term.needle!.sub)
        case .field(let field, _): result = text(e, field)?.contains(term.needle!.sub) ?? false
        case .number(let field, let range): result = number(e, field, now: now).map(range.contains) ?? false
        case .flag(let flag): result = self.flag(e, flag)
        case .present(let field): result = present(e, field)
        }
        return result != term.term.negated
    }

    func text(_ e: Entry, _ f: SearchQuery.TextField) -> IndexedText? {
        switch f {
        case .title: e.title
        case .artist: e.artist
        case .albumArtist: e.albumArtist
        case .album: e.album
        case .genre, .mbGenre: e.genre
        case .label: e.label
        case .person, .composer: e.person
        case .format: e.format
        case .country, .work: nil
        }
    }

    func number(_ e: Entry, _ f: SearchQuery.NumberField, now: Date) -> Double? {
        switch f {
        case .year: e.year.map(Double.init)
        case .duration: e.length
        case .track: e.trackCount > 0 ? Double(e.trackCount) : nil
        case .disc: e.discCount > 0 ? Double(e.discCount) : nil
        case .addedDays: e.record.firstSeen.map { max(0, now.timeIntervalSince($0) / 86_400) }
        case .addedYear: e.record.firstSeen.map { Double(Calendar.current.component(.year, from: $0)) }
        case .bitDepth, .sampleRate, .bitrate: nil
        }
    }

    func flag(_ e: Entry, _ f: SearchQuery.Flag) -> Bool {
        let types = e.details?.album?.secondaryTypes ?? []
        switch f {
        case .compilation:
            return e.record.item.author == nil || CatalogText.key(e.details?.mbArtist ?? "") == "various artists"
                || types.contains { $0.caseInsensitiveCompare("compilation") == .orderedSame }
        case .live: return types.contains { $0.caseInsensitiveCompare("live") == .orderedSame }
        case .matched: return e.details?.isMatched == true
        case .unmatched: return e.details?.isMatched != true
        case .lossless: return true
        case .lossy, .hires: return false
        }
    }

    func present(_ e: Entry, _ p: SearchQuery.PresenceField) -> Bool {
        switch p {
        case .year: return e.year != nil
        case .genre: return !e.genres.isEmpty
        case .label: return e.details?.label != nil
        case .album: return true
        case .artist: return !e.albumArtist.isBlank
        case .mbid, .cover: return e.details?.isMatched == true
        case .credits: return e.trackCount > 0
        case .composer: return false
        }
    }

    // MARK: Ordering

    func relevance(_ e: Entry, _ phrases: [String]) -> Int {
        phrases.reduce(0) { total, phrase in
            let n = Needle(phrase)
            return total + SearchIndex.score(e.album, n, 120, 80, 30) + SearchIndex.score(e.albumArtist, n, 100, 70, 25)
                + SearchIndex.score(e.title, n, 30, 20, 8) + SearchIndex.score(e.genre, n, 20, 12, 4)
        }
    }

    func order(_ matched: [(Entry, Int)], _ sort: CatalogLocalSort, hasText: Bool) -> [Entry] {
        func byKey<T: Comparable>(_ key: (Entry) -> T?, descending: Bool) -> [Entry] {
            matched.map(\.0).sorted { a, b in
                switch (key(a), key(b)) {
                case let (x?, y?) where x != y: return descending ? x > y : x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.record.addedRank < b.record.addedRank
                }
            }
        }
        switch sort {
        case .relevance where hasText:
            return matched.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.record.addedRank < $1.0.record.addedRank }.map(\.0)
        case .relevance, .recentlyAdded: return byKey({ $0.record.addedRank }, descending: false)
        case .artist: return byKey({ $0.sortArtist.isEmpty ? nil : $0.sortArtist + "\u{1}" + $0.sortTitle }, descending: false)
        case .title: return byKey({ $0.sortTitle }, descending: false)
        case .newest: return byKey({ $0.year }, descending: true)
        case .oldest: return byKey({ $0.year }, descending: false)
        case .rating: return byKey({ $0.rating }, descending: true)
        }
    }
}
