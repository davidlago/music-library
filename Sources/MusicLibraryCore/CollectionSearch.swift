import Foundation

// MARK: Query

/// A search of the collection: the app's query language (`SearchQuery`, matched against each item and its linked
/// tracks) plus keys only the collection has (`own:vinyl`, `ripped:no`, `sticker:cd100-199`, `bought:2024`,
/// `paid:>20`, `copies:>1`, `barcode:`, `catno:`, and the `#12`/`cd#12`/`vinyl#12` shorthand), which apply across
/// the whole query (ANDed, outside any OR).
///
/// None of these keys are in `SearchFilterKey.all`, and nothing is added to `is:`, `missing:` or `has:`: an older
/// reader of a saved query sees an unknown key as text, which matches nothing, whereas an unknown `is:` value would
/// be dropped as an issue and an empty query matches every track.
public struct CollectionSearchQuery: Equatable, Sendable {
    /// `own:`.
    public enum Ownership: Hashable, Sendable {
        case medium(CollectionMedium)
        /// CDs, records and other physical media.
        case physical
        /// Any copy.
        case any
        /// Library albums with no copy: matches no item; for tracks, the albums you don't own.
        case none
    }

    /// `ripped:`, read from `DigitalState`.
    public enum Digitized: String, CaseIterable, Sendable {
        /// Has music from this copy (digitized, or partly).
        case yes
        /// `needsDigitizing`: never digitized, or its digital copy is gone.
        case no
        case partial
        case missing
        /// The music is in the library from another copy.
        case other
    }

    /// `bought:`.
    public enum Bought: Equatable, Sendable {
        /// No purchase day.
        case none
        /// Bought in these calendar years (`bought:2024`, `bought:2020-2022`, `bought:>=2020`).
        case year(SearchQuery.NumberRange)
        /// Bought this many days ago (`bought:<90d`, `bought:>1y`), as `added:` reads it.
        case age(SearchQuery.NumberRange)
    }

    public struct Filter: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case own(Ownership)
            case ripped(Digitized)
            /// A label in `series` (either when nil) whose number is in `range` (any when nil).
            case sticker(series: StickerSeries?, range: SearchQuery.NumberRange?)
            /// A physical item with no label number (`sticker:none`).
            case unlabeled
            case bought(Bought)
            /// A price in `range`; nil: no price (`paid:none`).
            case paid(SearchQuery.NumberRange?)
            /// How many copies the item's album has, this one included.
            case copies(SearchQuery.NumberRange)
            /// The barcode's digits without leading zeros (`MusicCollection.barcodeKey`).
            case barcode(String)
            /// Part of the catalog number, lowercased letters and digits only ("cl1355").
            case catalogNumber(String)
        }

        public var kind: Kind
        public var negated: Bool

        public init(kind: Kind, negated: Bool) { self.kind = kind; self.negated = negated }
    }

    /// The parts the app's query language covers.
    public var base: SearchQuery
    /// Collection-only filters, all of which must hold.
    public var filters: [Filter]
    /// The base query's issues, then values the collection keys couldn't read.
    public var issues: [String]
    /// The text of `base`: the query without its collection terms.
    var baseText: String

    public var hasCollectionFilters: Bool { !filters.isEmpty }
    public var isEmpty: Bool { base.isEmpty && filters.isEmpty }

    enum Key: Sendable { case own, ripped, sticker, bought, paid, copies, barcode, catno }

    static let keyNames: [String: Key] = [
        "own": .own, "medium": .own, "media": .own,
        "ripped": .ripped, "digitized": .ripped,
        "sticker": .sticker, "labelno": .sticker, "shelf": .sticker,
        "bought": .bought, "purchased": .bought,
        "paid": .paid, "price": .paid,
        "copies": .copies,
        "barcode": .barcode,
        "catno": .catno,
    ]

    /// The collection keys with an example and the help shown for each (search help, completions).
    public static let keys: [(key: String, example: String, help: String)] = [
        ("own", "own:vinyl", "Your copy: cd, vinyl, download, physical, any; none = library albums you don't own"),
        ("ripped", "ripped:no", "yes (digitized from this copy), no, partial, missing, other (from another copy)"),
        ("sticker", "sticker:cd100-199", "Label number in either series or one: 12, 10-20, >=100, cd, vinyl, vinyl12, none"),
        ("#", "vinyl#12", "Exactly this label: #12 (CD or vinyl), cd#12, vinyl#12"),
        ("bought", "bought:2024", "When you bought it: a year, a range of years, within (90d, 1y), none"),
        ("paid", "paid:>20", "What you paid: 0, 10-15, >20, none"),
        ("copies", "copies:>1", "Copies you have of the same album"),
        ("barcode", "barcode:886976389413", "Barcode (UPC/EAN) of your copy"),
        ("catno", "catno:\"cl 1355\"", "Catalog number of your copy"),
    ]

    public static func parse(_ text: String, now: Date = Date()) -> CollectionSearchQuery {
        var filters: [Filter] = []
        var issues: [String] = []
        var rest = ""
        for token in SearchTokenizer.tokenize(text) {
            if let key = token.key, let kind = keyNames[key.lowercased()] {
                let value = token.value.trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }  // still typing
                if let parsed = Self.filter(kind, value, now: now) {
                    filters.append(Filter(kind: parsed, negated: token.negated))
                } else {
                    issues.append("Can't read “\(value)” as a value for \(key):")
                }
                continue
            }
            if token.key == nil, !token.quoted, let label = shorthand(token.value) {
                filters.append(Filter(kind: .sticker(series: label.series, range: exactly(label.number)), negated: token.negated))
                continue
            }
            rest += String(text[token.range]) + " "
        }
        let base = SearchQuery.parse(rest, now: now)
        return CollectionSearchQuery(base: base, filters: filters, issues: base.issues + issues, baseText: rest)
    }

    /// "#12" → (nil, 12), "cd#12" → (.cd, 12), "vinyl#12", "lp#12", "v#12", "record#12" → (.vinyl, 12). Only with
    /// a "#": a bare number stays text.
    static func shorthand(_ value: String) -> (series: StickerSeries?, number: Int)? {
        guard value.contains("#"), !value.contains(where: \.isWhitespace) else { return nil }
        return Sticker.parse(value)
    }

    static func exactly(_ n: Int) -> SearchQuery.NumberRange { .init(lower: Double(n), upper: Double(n)) }

    /// When the whole query is a label (`#12`, `cd 12`, `vinyl 12`, `v12`, or a bare number of 1–7 digits): its
    /// series (nil for either) and number. The query's text results stay as they are; these are shown alongside.
    public static func labelForm(_ text: String) -> (series: StickerSeries?, number: Int)? { Sticker.parse(text) }

    /// The text to save for a query (a smart playlist): the `#12`-style shorthand, which only search boxes take,
    /// becomes `sticker:12` / `sticker:cd12` / `sticker:vinyl12`. Everything else is kept as typed.
    public static func canonical(_ text: String) -> String {
        var out = text
        for token in SearchTokenizer.tokenize(text).reversed() where token.key == nil && !token.quoted {
            guard let label = shorthand(token.value) else { continue }
            out.replaceSubrange(token.range, with: (token.negated ? "-" : "") + "sticker:" + (label.series?.rawValue ?? "") + String(label.number))
        }
        return out
    }

    // MARK: Values

    static func filter(_ key: Key, _ raw: String, now: Date) -> Filter.Kind? {
        let value = raw.lowercased()
        switch key {
        case .own: return ownership(value).map(Filter.Kind.own)
        case .ripped: return digitized[value].map(Filter.Kind.ripped)
        case .sticker: return sticker(value, now: now)
        case .bought: return bought(value, now: now).map(Filter.Kind.bought)
        case .paid:
            if ["none", "no", "unknown"].contains(value) { return .paid(nil) }
            if value == "free" { return .paid(exactly(0)) }
            return priceRange(value).map { .paid($0) }
        case .copies: return NumberParser.range(value, field: .track, now: now).map(Filter.Kind.copies)
        case .barcode: return MusicCollection.barcodeKey(value).map(Filter.Kind.barcode)
        case .catno:
            let code = compact(value)
            return code.isEmpty ? nil : .catalogNumber(code)
        }
    }

    static func ownership(_ value: String) -> Ownership? {
        switch value {
        case "cd", "cds": .medium(.cd)
        case "vinyl", "lp", "lps", "record", "records": .medium(.vinyl)
        case "download", "downloads", "dl", "digital": .medium(.download)
        case "physical": .physical
        case "any", "yes": .any
        case "none", "no": Ownership.none
        default: CollectionMedium(rawValue: value).map(Ownership.medium)
        }
    }

    static let digitized: [String: Digitized] = [
        "yes": .yes, "y": .yes, "true": .yes, "ripped": .yes, "digitized": .yes,
        "no": .no, "n": .no, "false": .no, "not": .no,
        "partial": .partial, "partly": .partial,
        "missing": .missing, "lost": .missing,
        "other": .other, "elsewhere": .other, "same": .other,
    ]

    static func sticker(_ value: String, now: Date) -> Filter.Kind? {
        if ["none", "no"].contains(value) { return .unlabeled }
        if ["any", "yes"].contains(value) { return .sticker(series: nil, range: nil) }
        var s = Substring(value)
        var series: StickerSeries?
        // Longest first, so "vinyl" isn't read as "v" + "inyl".
        for (prefix, value) in [("vinyl", StickerSeries.vinyl), ("record", .vinyl), ("lp", .vinyl), ("cd", .cd), ("v", .vinyl)]
        where s.hasPrefix(prefix) {
            series = value
            s = s.dropFirst(prefix.count)
            break
        }
        if s.hasPrefix("#") { s = s.dropFirst() }
        if s.isEmpty { return series.map { .sticker(series: $0, range: nil) } }
        guard let range = NumberParser.range(String(s), field: .track, now: now) else { return nil }
        return .sticker(series: series, range: range)
    }

    static func bought(_ value: String, now: Date) -> Bought? {
        if ["none", "no", "unknown"].contains(value) { return Bought.none }
        // Years: "2024", "2020-2022", "2020..2022", ">=2020".
        let core = value.drop { "<>=".contains($0) }
        let years = core.replacingOccurrences(of: "..", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        if !years.isEmpty, years.allSatisfy({ $0.isEmpty || ($0.count == 4 && $0.allSatisfy(\.isNumber)) }),
           years.contains(where: { !$0.isEmpty }) {
            return NumberParser.range(value, field: .year, now: now).map(Bought.year)
        }
        return NumberParser.range(value, field: .addedDays, now: now).map(Bought.age)
    }

    /// "20", ">20", "<=9.99", "10-15" (both ends included); a currency sign is ignored.
    static func priceRange(_ raw: String) -> SearchQuery.NumberRange? {
        var s = raw.filter { !"$€£¥ ".contains($0) }
        var op = ""
        for prefix in [">=", "<=", ">", "<", "="] where s.hasPrefix(prefix) {
            op = prefix
            s.removeFirst(prefix.count)
            break
        }
        if op.isEmpty, let sep = s.range(of: "..") ?? s.dropFirst().range(of: "-") {
            guard let lo = Double(s[..<sep.lowerBound]), let hi = Double(s[sep.upperBound...]), lo >= 0, hi >= lo else { return nil }
            return .init(lower: lo, upper: hi)
        }
        guard let v = Double(s), v >= 0, v.isFinite else { return nil }
        switch op {
        case ">": return .init(lower: v, lowerInclusive: false)
        case ">=": return .init(lower: v)
        case "<": return .init(upper: v, upperInclusive: false)
        case "<=": return .init(upper: v)
        default: return .init(lower: v, upper: v)
        }
    }

    /// Lowercased letters and digits: "CL 1355" and "cl-1355" are the same catalog number.
    static func compact(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: Index

/// The collection, searchable like the music library: one entry per item. Text matches the item's own fields, its
/// album info (genres, tracklist) and its linked tracks; `label:` the item's record label, else the tracks' tag;
/// `year:`/`decade:` the item's year, else the tracks'; and terms only tracks have (`format:`, `bits:`, `time:`,
/// `added:`, `is:`, `missing:`…) hold when any linked track satisfies them. Immutable; build it off the main thread.
public struct CollectionIndex: Sendable {
    struct Entry: Sendable {
        var item: CollectionItem
        var state: DigitalState
        var copies: Int
        var title, artist, albumArtist, album, genre, label, country, all: IndexedText
        /// `label:` goes by the item's record label only when it has one.
        var hasRecordLabel: Bool
        var year: Int?
        /// The linked tracks, as indices into `tracks`.
        var tracks: [Int]
        var barcode: String?
        var catalogNumber: String
    }

    let entries: [Entry]
    /// The linked tracks, indexed like the library's.
    let tracks: SearchIndex
    let albumKeys: Set<String>

    public static let empty = CollectionIndex(collection: .empty, tracks: [], albumInfos: [:])

    public var count: Int { entries.count }

    /// `index`, the library's index of the same `tracks`, is reused when given (and knows which albums have
    /// covers); otherwise the linked tracks are indexed here.
    public init(collection: MusicCollection, tracks: [Track], albumInfos: [String: AlbumInfo], index: SearchIndex? = nil) {
        let keys = Set(collection.items.map(\.albumKey))
        var byKey: [String: [Int]] = [:]
        if let index {
            for (i, t) in index.tracks.enumerated() {
                let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
                if keys.contains(key) { byKey[key, default: []].append(i) }
            }
            self.tracks = index
        } else {
            var linked: [Track] = []
            for t in tracks {
                let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
                guard keys.contains(key) else { continue }
                byKey[key, default: []].append(linked.count)
                linked.append(t)
            }
            self.tracks = SearchIndex(tracks: linked)
        }
        albumKeys = keys
        entries = collection.items.map { item in
            Self.entry(item, collection: collection, info: albumInfos[item.albumKey], tracks: byKey[item.albumKey] ?? [])
        }
    }

    /// Built step by step with explicit types: as one expression it's too much for the type checker.
    static func entry(_ item: CollectionItem, collection: MusicCollection, info: AlbumInfo?, tracks: [Int]) -> Entry {
        let tracklist: [TracklistEntry] = info?.tracklist ?? []
        let songTitles: [String] = tracklist.map(\.title)
        let songArtists: [String] = Array(Set(tracklist.map(\.artist)))
        let genres: [String] = info?.genres ?? []
        let fields: [String] = [item.recordLabel, item.catalogNumber, item.barcode, item.country, item.formatDetail, item.notes]
            .map { $0 ?? "" }
        var all: [String] = [item.album, item.artist, item.medium.name]
        all += fields
        all += genres
        all += songTitles
        all += songArtists
        return Entry(
            item: item, state: collection.digitalState(item), copies: collection.copies(albumKey: item.albumKey).count,
            title: IndexedText(songTitles), artist: IndexedText([item.artist] + songArtists), albumArtist: IndexedText([item.artist]),
            album: IndexedText([item.album]), genre: IndexedText(genres), label: IndexedText([item.recordLabel ?? ""]),
            country: IndexedText([item.country ?? ""]), all: IndexedText(all),
            hasRecordLabel: !(item.recordLabel ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            year: item.year, tracks: tracks, barcode: item.barcode.flatMap(MusicCollection.barcodeKey),
            catalogNumber: CollectionSearchQuery.compact(item.catalogNumber ?? ""))
    }

    public func search(_ text: String, now: Date = Date()) -> [CollectionItem] {
        search(CollectionSearchQuery.parse(text, now: now), now: now)
    }

    /// The items matching every collection filter and the base query, best text match first, else in the
    /// collection's order (`CollectionSort.sticker`).
    public func search(_ query: CollectionSearchQuery, now: Date = Date()) -> [CollectionItem] {
        let groups = query.base.groups.map { $0.map(SearchIndex.CompiledTerm.init) }
        let phrases = query.base.rankingPhrases.map(Needle.init)
        var hits: [(item: CollectionItem, score: Int, offset: Int)] = []
        for (offset, e) in entries.enumerated() {
            guard query.filters.allSatisfy({ matches($0, e, now: now) }) else { continue }
            if !groups.isEmpty, !groups.contains(where: { $0.allSatisfy { matches($0, e, now: now) } }) { continue }
            let score = phrases.reduce(0) { total, n in
                total + SearchIndex.score(e.album, n, 120, 80, 30) + SearchIndex.score(e.albumArtist, n, 100, 70, 25)
                    + SearchIndex.score(e.title, n, 30, 20, 8)
            }
            hits.append((e.item, score, offset))
        }
        if !phrases.isEmpty { hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset } }
        return hits.map(\.item)
    }

    /// The album keys of the items matching every filter.
    func albumKeys(matching filters: [CollectionSearchQuery.Filter], now: Date) -> Set<String> {
        Set(entries.filter { e in filters.allSatisfy { matches($0, e, now: now) } }.map(\.item.albumKey))
    }

    /// Whether an album key has a copy in the collection.
    func owns(albumKey: String) -> Bool { albumKeys.contains(albumKey) }

    // MARK: Matching

    func matches(_ filter: CollectionSearchQuery.Filter, _ e: Entry, now: Date) -> Bool {
        let item = e.item
        let result: Bool
        switch filter.kind {
        case .own(let own):
            switch own {
            case .medium(let m): result = item.medium == m
            case .physical: result = item.medium.isPhysical
            case .any: result = true
            case .none: result = false
            }
        case .ripped(let wanted):
            switch (wanted, e.state) {
            case (.yes, .digitized), (.yes, .partial), (.partial, .partial), (.missing, .missing), (.other, .otherCopy):
                result = true
            case (.no, _): result = e.state.needsDigitizing
            default: result = false
            }
        case .sticker(let series, let range):
            if let s = item.sticker {
                result = (series == nil || s.series == series) && (range?.contains(Double(s.number)) ?? true)
            } else {
                result = false
            }
        case .unlabeled: result = item.medium.series != nil && item.stickerNumber == nil
        case .bought(let bought):
            switch bought {
            case .none: result = item.purchasedOn == nil
            case .year(let range): result = item.purchasedOn.map { range.contains(Double($0.year)) } ?? false
            case .age(let range):
                result = item.purchasedOn.map { range.contains(max(0, now.timeIntervalSince($0.date()) / 86_400)) } ?? false
            }
        case .paid(let range):
            if let range { result = item.price.map { range.contains($0.doubleValue) } ?? false } else { result = item.price == nil }
        case .copies(let range): result = range.contains(Double(e.copies))
        case .barcode(let code): result = e.barcode == code
        case .catalogNumber(let code): result = e.catalogNumber.contains(code)
        }
        return result != filter.negated
    }

    func matches(_ term: SearchIndex.CompiledTerm, _ e: Entry, now: Date) -> Bool {
        switch term.term.predicate {
        case .text:
            let needle = term.needle!.sub
            let hit = e.all.contains(needle) || e.tracks.contains { tracks.entries[$0].all.contains(needle) }
            return hit != term.term.negated
        case .field(let field, _):
            let needle = term.needle!.sub
            let own = text(e, field)
            let hit: Bool
            if field == .label, e.hasRecordLabel {
                hit = own?.contains(needle) ?? false
            } else {
                hit = (own?.contains(needle) ?? false)
                    || e.tracks.contains { SearchIndex.text(tracks.entries[$0], field).contains(needle) }
            }
            return hit != term.term.negated
        case .number(.year, let range) where e.item.year != nil:
            return range.contains(Double(e.item.year!)) != term.term.negated
        case .number, .flag, .present:
            return e.tracks.contains { term.matches(tracks.entries[$0], tracks.tracks[$0], now: now) }
        }
    }

    func text(_ e: Entry, _ f: SearchQuery.TextField) -> IndexedText? {
        switch f {
        case .title: e.title
        case .artist: e.artist
        case .albumArtist: e.albumArtist
        case .album: e.album
        case .genre, .mbGenre: e.genre
        case .label: e.label
        case .country: e.country
        case .composer, .person, .format, .work: nil
        }
    }

    // MARK: Completions

    /// Suggestions for the collection key or value being typed at the end of `text`, to show with the library's
    /// (`SearchIndex.completions`).
    public func completions(for text: String, limit: Int = 8) -> [SearchCompletion] {
        guard let last = text.last, !last.isWhitespace,
              let token = SearchTokenizer.tokenize(text).last, !token.isOr else { return [] }
        let prefix = String(text[..<token.range.lowerBound]) + (token.negated ? "-" : "")

        if let key = token.key {
            guard let kind = CollectionSearchQuery.keyNames[key.lowercased()] else { return [] }
            let typed = token.value.lowercased()
            let options: [(value: String, detail: String)]
            switch kind {
            case .own:
                options = [("cd", count(.own(.medium(.cd)))), ("vinyl", count(.own(.medium(.vinyl)))),
                           ("download", count(.own(.medium(.download)))), ("physical", count(.own(.physical))),
                           ("any", count(.own(.any))), ("none", "Library albums you don't own")]
            case .ripped:
                options = [("yes", count(.ripped(.yes))), ("no", count(.ripped(.no))), ("partial", count(.ripped(.partial))),
                           ("missing", count(.ripped(.missing))), ("other", count(.ripped(.other)))]
            case .sticker:
                options = [("cd", count(.sticker(series: .cd, range: nil))), ("vinyl", count(.sticker(series: .vinyl, range: nil))),
                           ("none", count(.unlabeled))]
            case .bought:
                options = SearchIndex.addedPresets.map { ($0.0, $0.1) } + [("none", "No purchase date")]
            case .paid:
                options = [("0", "Free"), (">20", "More than 20"), ("none", "No price")]
            case .copies:
                options = [(">1", count(.copies(.init(lower: 2))))]
            case .barcode, .catno:
                options = []
            }
            return options.filter { typed.isEmpty || $0.value.hasPrefix(typed) }.prefix(limit).map {
                SearchCompletion(label: "\(key):\($0.value)", detail: $0.detail, replacement: prefix + key + ":" + $0.value + " ")
            }
        }

        let typed = token.value.lowercased()
        guard !token.quoted, !typed.isEmpty else { return [] }
        return CollectionSearchQuery.keys.filter { $0.key != "#" && $0.key.hasPrefix(typed) && $0.key != typed }.prefix(min(3, limit)).map {
            SearchCompletion(label: $0.key + ":", detail: $0.help, replacement: prefix + $0.key + ":")
        }
    }

    func count(_ kind: CollectionSearchQuery.Filter.Kind) -> String {
        let n = entries.reduce(0) { $0 + (matches(.init(kind: kind, negated: false), $1, now: Date()) ? 1 : 0) }
        return n == 1 ? "1 item" : "\(n) items"
    }
}

// MARK: Searching the library and the collection

/// The one search entry point for the Mac and the phone: the library's results, the collection's items, and the
/// exact label hits when the query is a label.
public enum LibrarySearch {
    public struct Results: Sendable {
        /// Songs, albums and artists. With no collection filters, exactly `SearchIndex.search`; with them, the base
        /// query's results limited to the albums of the items matching the filters (`own:none`: the albums with no
        /// copy).
        public var library: SearchResults
        /// The items matching the query (none for an empty one), trackless ones included.
        public var items: [CollectionItem]
        /// When the whole query is a label: the items with exactly that label, in both series for a bare number.
        public var labelHits: [CollectionItem]

        public init(library: SearchResults = SearchResults(), items: [CollectionItem] = [], labelHits: [CollectionItem] = []) {
            self.library = library; self.items = items; self.labelHits = labelHits
        }
    }

    public static func run(_ text: String, index: SearchIndex, collectionIndex: CollectionIndex, collection: MusicCollection,
                           now: Date = Date(), autocorrect: Bool = true) -> Results {
        let query = CollectionSearchQuery.parse(text, now: now)
        var library: SearchResults
        if query.hasCollectionFilters {
            let keys = albumKeys(query, index: index, collectionIndex: collectionIndex, now: now)
            library = restricted(index.search(query.baseText, now: now, autocorrect: false), to: keys, index: index, base: query.base)
            // Spelling correction leaves the collection terms alone (they aren't text filters).
            if library.tracks.isEmpty, autocorrect, let corrected = index.correction(for: text), corrected != text {
                let alt = CollectionSearchQuery.parse(corrected, now: now)
                var results = restricted(index.search(alt.baseText, now: now, autocorrect: false), to: keys, index: index, base: alt.base)
                if !results.tracks.isEmpty {
                    results.correctedText = corrected
                    library = results
                }
            }
        } else {
            library = index.search(text, now: now, autocorrect: autocorrect)
        }
        library.issues = query.issues

        var labelHits: [CollectionItem] = []
        if let label = CollectionSearchQuery.labelForm(text) {
            if let series = label.series {
                labelHits = Sticker(series: series, number: label.number).map(collection.items(at:)) ?? []
            } else {
                labelHits = collection.items(number: label.number)
            }
        }
        return Results(library: library, items: query.isEmpty ? [] : collectionIndex.search(query, now: now), labelHits: labelHits)
    }

    /// A smart playlist's tracks. Without collection keys, exactly `SearchIndex.tracks(matching:)`.
    public static func tracks(matching text: String, index: SearchIndex, collectionIndex: CollectionIndex,
                              collection: MusicCollection, now: Date = Date()) -> [Track] {
        let query = CollectionSearchQuery.parse(text, now: now)
        guard query.hasCollectionFilters else { return index.tracks(matching: SearchQuery.parse(text, now: now), now: now) }
        let keys = albumKeys(query, index: index, collectionIndex: collectionIndex, now: now)
        return index.tracks(matching: query.base, now: now).filter { keys.contains(key($0)) }
    }

    static func key(_ t: Track) -> String { SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist) }

    /// The library albums the collection filters leave: those of the matching items, with `own:none` (and
    /// `-own:none`) deciding on whether an album has any copy.
    static func albumKeys(_ query: CollectionSearchQuery, index: SearchIndex, collectionIndex: CollectionIndex, now: Date) -> Set<String> {
        var ownership: [CollectionSearchQuery.Filter] = [], others: [CollectionSearchQuery.Filter] = []
        for f in query.filters {
            if case .own(.none) = f.kind { ownership.append(f) } else { others.append(f) }
        }
        var keys = others.isEmpty ? Set(index.albumSummaries.keys) : collectionIndex.albumKeys(matching: others, now: now)
        for f in ownership { keys = keys.filter { collectionIndex.owns(albumKey: $0) == f.negated } }
        return keys
    }

    /// `results` limited to tracks on `keys`; for a query of collection filters alone, the albums and artists are
    /// those of the tracks left.
    static func restricted(_ results: SearchResults, to keys: Set<String>, index: SearchIndex, base: SearchQuery) -> SearchResults {
        var out = results
        out.tracks = results.tracks.filter { keys.contains(key($0)) }
        if base.isEmpty {
            var seenAlbums = Set<String>(), seenArtists = Set<String>()
            out.albums = []; out.artists = []
            for t in out.tracks {
                let k = key(t)
                if seenAlbums.insert(k).inserted, let a = index.albumSummaries[k] { out.albums.append(a) }
                let artist = t.effectiveAlbumArtist.lowercased()
                if seenArtists.insert(artist).inserted, let a = index.artistSummaries[artist] { out.artists.append(a) }
            }
        } else {
            out.albums = results.albums.filter { keys.contains(SearchIndex.albumKey(album: $0.album, artist: $0.artist)) }
            let artists = Set(out.tracks.map { $0.effectiveAlbumArtist.lowercased() })
            out.artists = results.artists.filter { artists.contains($0.name.lowercased()) }
        }
        return out
    }
}
