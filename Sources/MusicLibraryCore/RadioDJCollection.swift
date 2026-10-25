import Foundation

/// The DJ's look into the listener's own collection: the `search_collection` tool, run on the device against the same
/// indexes as the search box (`LibrarySearch`), with play counts and likes. Only the matching rows, as short lines of
/// text, go to Claude.
public struct RadioDJLibrary: Sendable {
    public enum Kind: String, CaseIterable, Sendable { case songs, albums, artists, copies }
    public enum Sort: String, CaseIterable, Sendable { case plays, recent, added, year, title }

    public static let toolName = "search_collection"
    static let defaultLimit = 25
    static let maxLimit = 100

    public var index: SearchIndex
    public var collectionIndex: CollectionIndex
    public var collection: MusicCollection
    public var playTotals: [Int64: PlayTotal]
    public var likedDates: [Int64: Date]
    /// Every listen, for the listening stats (`collection_stats`).
    public var plays: [Play]
    public var albumInfos: [String: AlbumInfo]
    public var currencyCode: String

    public init(index: SearchIndex, collectionIndex: CollectionIndex, collection: MusicCollection,
                playTotals: [Int64: PlayTotal], likedDates: [Int64: Date], plays: [Play] = [],
                albumInfos: [String: AlbumInfo] = [:], currencyCode: String = Locale.current.currency?.identifier ?? "USD") {
        self.index = index; self.collectionIndex = collectionIndex; self.collection = collection
        self.playTotals = playTotals; self.likedDates = likedDates
        self.plays = plays; self.albumInfos = albumInfos; self.currencyCode = currencyCode
    }

    /// The tool as the API takes it. Its input streams as it's written, so `run` checks it.
    public static var tool: JSONValue {
        let filters = SearchFilterKey.all.map { "\($0.name): \($0.help) (\($0.example))" }.joined(separator: "; ")
        let description = """
        Search the listener's own music collection on their device: the songs in their digital library (with their \
        play counts, running times, when they last played them and which they've liked) and the CDs, records and \
        downloads they own \
        (including ones never ripped). Results include total running time. Use it whenever a question is about what they have, own or listen to, instead \
        of guessing. The query uses the app's search language: bare words match any field; "exact phrases"; -term \
        negates; OR separates alternatives; an empty query means everything. Filters: \(filters). Collection \
        filters: own:cd|vinyl|download|physical|none, ripped:yes|no|partial, sticker:cd100-199 or #12 (a shelf \
        label), bought:2024, paid:>20, copies:>1, barcode:, catno:. kind picks what comes back: songs, albums \
        (songs grouped by album), artists (grouped by artist) or copies (the physical and download copies they own). \
        sort: plays (most played first, the default), recent (last played), added (newest in the library), year, or \
        title.
        """
        let properties: [String: JSONValue] = [
            "query": .object(["type": .string("string"), "description": .string("Search text in the app's search language, e.g. artist:\"diana krall\" or genre:jazz -is:live.")]),
            "kind": .object(["type": .string("string"), "enum": .array(Kind.allCases.map { .string($0.rawValue) })]),
            "sort": .object(["type": .string("string"), "enum": .array(Sort.allCases.map { .string($0.rawValue) })]),
            "limit": .object(["type": .string("integer"), "description": .string("At most this many rows (1–\(maxLimit), default \(defaultLimit)).")]),
        ]
        return .object([
            "name": .string(toolName),
            "description": .string(description),
            "input_schema": .object(["type": .string("object"), "properties": .object(properties),
                                     "required": .array([.string("query")]), "additionalProperties": .bool(false)]),
            "eager_input_streaming": .bool(true),
        ])
    }

    /// Runs one tool call. Returns the text for the tool result and whether it's an error (a bad input).
    public func run(_ input: JSONValue, now: Date = Date()) -> (text: String, isError: Bool) {
        guard let object = input.object, let query = object["query"]?.string else {
            return ("Invalid input: query must be a string.", true)
        }
        guard let kind = object["kind"].map({ $0.string.flatMap(Kind.init(rawValue:)) }) ?? .songs else {
            return ("Invalid input: kind must be one of \(Kind.allCases.map(\.rawValue).joined(separator: ", ")).", true)
        }
        guard let sort = object["sort"].map({ $0.string.flatMap(Sort.init(rawValue:)) }) ?? .plays else {
            return ("Invalid input: sort must be one of \(Sort.allCases.map(\.rawValue).joined(separator: ", ")).", true)
        }
        let limit = min(Self.maxLimit, max(1, object["limit"]?.int ?? Self.defaultLimit))
        return (search(query, kind: kind, sort: sort, limit: limit, now: now), false)
    }

    public func search(_ query: String, kind: Kind, sort: Sort, limit: Int, now: Date = Date()) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = ""
        if kind == .copies {
            var items = copies(text, now: now)
            if items.isEmpty, let corrected = index.correction(for: text), corrected != text, !copies(corrected, now: now).isEmpty {
                note = "Nothing matched “\(text)”; showing “\(corrected)”.\n"
                text = corrected
                items = copies(corrected, now: now)
            }
            return note + copyLines(items, query: text, sort: sort, limit: limit)
        }
        var tracks = LibrarySearch.tracks(matching: text, index: index, collectionIndex: collectionIndex, collection: collection, now: now)
        if tracks.isEmpty, let corrected = index.correction(for: text), corrected != text {
            let retried = LibrarySearch.tracks(matching: corrected, index: index, collectionIndex: collectionIndex, collection: collection, now: now)
            if !retried.isEmpty {
                note = "Nothing matched “\(text)”; showing “\(corrected)”.\n"
                text = corrected
                tracks = retried
            }
        }
        switch kind {
        case .songs: return note + songLines(tracks, query: text, sort: sort, limit: limit)
        case .albums: return note + groupLines(tracks, query: text, sort: sort, limit: limit, byAlbum: true)
        case .artists: return note + groupLines(tracks, query: text, sort: sort, limit: limit, byAlbum: false)
        case .copies: return ""
        }
    }

    // MARK: Rows

    private func plays(_ t: Track) -> Int { playTotals[t.id]?.plays ?? 0 }
    private func lastPlayed(_ t: Track) -> Date? { playTotals[t.id]?.lastPlayed }

    /// "4:05".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "11 plays, last 2026-09-21"; a listen too short to count as a play still has a date.
    static func playText(_ plays: Int, last: Date?) -> String {
        let count = "\(plays) play\(plays == 1 ? "" : "s")"
        guard let last else { return count }
        let day = PurchaseDay(last).string
        return plays > 0 ? "\(count), last \(day)" : "0 full plays (last listened to partly on \(day))"
    }

    /// `duration`: the running time of everything that matched (not only the rows shown).
    private func header(_ count: Int, _ noun: String, query: String, sort: Sort, limit: Int, duration: Double? = nil) -> String {
        let scope = query.isEmpty ? "in the whole collection" : "\(count == 1 ? "matches" : "match") “\(query)”"
        let total = duration.map { ", \(Self.time($0)) of music in all" } ?? ""
        let shown = count > limit ? " (showing \(limit), " : " ("
        return "\(count) \(noun)\(count == 1 ? "" : "s") \(scope)\(total)\(shown)sorted by \(sort.rawValue)):"
    }

    private func songLines(_ tracks: [Track], query: String, sort: Sort, limit: Int) -> String {
        guard !tracks.isEmpty else { return "No songs in the collection match “\(query)”." }
        let sorted = tracks.sorted { a, b in
            switch sort {
            case .plays: return (plays(a), lastPlayed(a) ?? .distantPast) > (plays(b), lastPlayed(b) ?? .distantPast)
            case .recent: return (lastPlayed(a) ?? .distantPast) > (lastPlayed(b) ?? .distantPast)
            case .added: return a.addedAt > b.addedAt
            case .year: return (a.year ?? Int.max, a.album, a.trackNo ?? 0) < (b.year ?? Int.max, b.album, b.trackNo ?? 0)
            case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        let rows = sorted.prefix(limit).map { t -> String in
            var line = "“\(t.title)” — \(t.artist) · *\(t.album)*"
            if let year = t.year { line += " (\(year))" }
            if t.duration > 0 { line += " · \(Self.clock(t.duration))" }
            line += " · " + Self.playText(plays(t), last: lastPlayed(t))
            if likedDates[t.id] != nil { line += " · liked" }
            return line
        }
        return ([header(tracks.count, "song", query: query, sort: sort, limit: limit, duration: tracks.reduce(0) { $0 + $1.duration })] + rows)
            .joined(separator: "\n")
    }

    private struct Group {
        var name: String
        var artist: String
        var year: Int?
        var songs = 0
        var plays = 0
        var liked = 0
        var lastPlayed: Date?
        var duration = 0.0
        var added = Date.distantPast
        var albums = Set<String>()
        var key: String
    }

    private func groupLines(_ tracks: [Track], query: String, sort: Sort, limit: Int, byAlbum: Bool) -> String {
        let noun = byAlbum ? "album" : "artist"
        guard !tracks.isEmpty else { return "No \(noun)s in the collection match “\(query)”." }
        var groups: [String: Group] = [:]
        for t in tracks {
            let albumKey = LibrarySearch.key(t)
            let key = byAlbum ? albumKey : t.effectiveAlbumArtist.lowercased()
            var g = groups[key] ?? Group(name: byAlbum ? t.album : t.effectiveAlbumArtist, artist: t.effectiveAlbumArtist, year: t.year, key: albumKey)
            g.songs += 1
            g.duration += t.duration
            g.plays += plays(t)
            if likedDates[t.id] != nil { g.liked += 1 }
            if let last = lastPlayed(t), last > (g.lastPlayed ?? .distantPast) { g.lastPlayed = last }
            g.added = max(g.added, t.addedAt)
            g.albums.insert(albumKey)
            if let y = t.year { g.year = min(g.year ?? y, y) }
            groups[key] = g
        }
        let sorted = groups.values.sorted { a, b in
            switch sort {
            case .plays: return (a.plays, a.songs) > (b.plays, b.songs)
            case .recent: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
            case .added: return a.added > b.added
            case .year: return (a.year ?? Int.max) < (b.year ?? Int.max)
            case .title: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let rows = sorted.prefix(limit).map { g -> String in
            var line: String
            if byAlbum {
                line = "*\(g.name)* — \(g.artist)"
                if let year = g.year { line += " (\(year))" }
            } else {
                line = "\(g.name) · \(g.albums.count) album\(g.albums.count == 1 ? "" : "s")"
            }
            line += " · \(g.songs) song\(g.songs == 1 ? "" : "s"), \(Self.time(g.duration)) · " + Self.playText(g.plays, last: g.lastPlayed)
            if g.liked > 0 { line += " · \(g.liked) liked" }
            if byAlbum {
                let owned = collection.copies(albumKey: g.key).compactMap { $0.sticker?.text ?? ($0.medium == .download ? "download" : nil) }
                if !owned.isEmpty { line += " · owned: \(owned.joined(separator: ", "))" }
            }
            return line
        }
        return ([header(groups.count, noun, query: query, sort: sort, limit: limit, duration: tracks.reduce(0) { $0 + $1.duration })] + rows)
            .joined(separator: "\n")
    }

    /// The copies a query picks: by collection filters or a label; otherwise those of the matching albums, plus
    /// trackless copies whose album or artist matches.
    private func copies(_ text: String, now: Date) -> [CollectionItem] {
        if text.isEmpty { return collection.items }
        let results = LibrarySearch.run(text, index: index, collectionIndex: collectionIndex, collection: collection, now: now, autocorrect: false)
        var seen = Set<String>()
        var items: [CollectionItem] = []
        let byAlbum = results.library.tracks.flatMap { collection.copies(albumKey: LibrarySearch.key($0)) }
        for item in results.labelHits + results.items + byAlbum where seen.insert(item.id).inserted { items.append(item) }
        return items
    }

    private func copyLines(_ items: [CollectionItem], query: String, sort: Sort, limit: Int) -> String {
        guard !items.isEmpty else { return "No copies in the collection match “\(query)”." }
        func plays(_ item: CollectionItem) -> Int { collection.libraryTracks(item).reduce(0) { $0 + self.plays($1) } }
        func last(_ item: CollectionItem) -> Date { collection.libraryTracks(item).compactMap(lastPlayed).max() ?? .distantPast }
        let sorted = items.sorted { a, b in
            switch sort {
            case .plays: return plays(a) > plays(b)
            case .recent: return last(a) > last(b)
            case .added: return a.createdAt > b.createdAt
            case .year: return (a.year ?? Int.max) < (b.year ?? Int.max)
            case .title: return a.album.localizedStandardCompare(b.album) == .orderedAscending
            }
        }
        let rows = sorted.prefix(limit).map { item -> String in
            let medium = switch item.medium {
            case .cd: "CD"
            case .vinyl: "Vinyl"
            case .download: "Download"
            case .other(let raw): raw
            }
            var line = "\(item.sticker?.text ?? medium): *\(item.album)* — \(item.artist)"
            if let year = item.year { line += " (\(year))" }
            let state: String = switch collection.digitalState(item) {
            case .none, .missing: "not digitized"
            case .partial(let have, let of): "partly digitized (\(have) of \(of) tracks)"
            case .digitized, .otherCopy: "in the digital library"
            }
            line += " · \(state)"
            let runtime = collection.libraryTracks(item).reduce(0) { $0 + $1.duration }
            if runtime > 0 { line += " · \(Self.time(runtime))" }
            let p = plays(item)
            if p > 0 { line += " · \(p) plays" }
            if let label = item.recordLabel, !label.isEmpty { line += " · \(label)" }
            if let day = item.purchasedOn { line += " · bought \(day.string)" }
            return line
        }
        return ([header(items.count, "copy", query: query, sort: sort, limit: limit)
                    .replacingOccurrences(of: "copys", with: "copies")] + rows).joined(separator: "\n")
    }
}
