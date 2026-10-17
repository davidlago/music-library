import Foundation

/// The orders of the Albums grid, shared by the Mac and iPhone apps (saved as `albumSort`).
public enum AlbumSort: String, CaseIterable, Identifiable, Sendable {
    case added, title, artist, year, mostPlayed, recent

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .added: "Date Added"
        case .title: "Title"
        case .artist: "Artist"
        case .year: "Release Year"
        case .mostPlayed: "Most Played"
        case .recent: "Recently Played"
        }
    }

    /// `albums` in this order. They arrive in the library's order (by artist); other orders are stable on top of that.
    /// `added` (the newest song's date) and `plays` are by `SearchIndex.albumKey`.
    public func sorted(_ albums: [AlbumSummary], added: [String: Date], plays: [String: PlayTotal]) -> [AlbumSummary] {
        func key(_ a: AlbumSummary) -> String { SearchIndex.albumKey(album: a.album, artist: a.artist) }
        func total(_ a: AlbumSummary) -> PlayTotal { plays[key(a)] ?? PlayTotal() }
        func by<T: Comparable>(_ value: (AlbumSummary) -> T, descending: Bool) -> [AlbumSummary] {
            albums.enumerated().sorted { x, y in
                let a = value(x.element), b = value(y.element)
                return a != b ? (descending ? a > b : a < b) : x.offset < y.offset
            }.map(\.element)
        }
        switch self {
        case .artist: return albums
        case .added: return by({ added[key($0)] ?? .distantPast }, descending: true)
        case .title: return by({ $0.album.isEmpty ? "\u{FFFF}" : $0.album.lowercased() }, descending: false)
        case .year: return by({ $0.year ?? Int.min }, descending: true)
        case .mostPlayed: return by({ total($0).plays * 1_000_000 + Int(total($0).listened) }, descending: true)
        case .recent: return by({ total($0).lastPlayed ?? .distantPast }, descending: true)
        }
    }

    /// When each album's newest song was added, by `SearchIndex.albumKey`.
    public static func addedDates(_ tracks: [Track]) -> [String: Date] {
        var added: [String: Date] = [:]
        for t in tracks {
            let key = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            added[key] = max(added[key] ?? t.addedAt, t.addedAt)
        }
        return added
    }
}

/// The orders of a song list on the iPhone, the Mac's song table columns plus when songs were added (saved as
/// `songSort` and `songSortAscending`).
public enum SongSort: String, CaseIterable, Identifiable, Sendable {
    case title, artist, album, composer, year, duration, format, added

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .composer: "Composer"
        case .year: "Year"
        case .duration: "Time"
        case .format: "Format"
        case .added: "Date Added"
        }
    }

    /// The direction picked along with the order: newest first for when songs were added, else ascending.
    public var defaultAscending: Bool { self != .added }

    /// What ascending and descending mean for this order.
    public var directionLabels: (ascending: String, descending: String) {
        switch self {
        case .title, .artist, .album, .composer, .format: ("A to Z", "Z to A")
        case .year, .added: ("Oldest First", "Newest First")
        case .duration: ("Shortest First", "Longest First")
        }
    }

    /// `tracks` in this order. Songs without a value (no composer, no year…) go last either way, and ties keep the order
    /// they came in (the library's: album artist, album, disc, track).
    public func sorted(_ tracks: [Track], ascending: Bool) -> [Track] {
        tracks.enumerated().sorted { x, y in
            before(x.element, y.element, ascending: ascending) ?? (x.offset < y.offset)
        }.map(\.element)
    }

    /// Whether `a` goes before `b`, or nil when they tie.
    private func before(_ a: Track, _ b: Track, ascending: Bool) -> Bool? {
        switch self {
        case .title: Self.before(a.title, b.title, ascending)
        case .artist: Self.before(a.artist, b.artist, ascending)
        case .album: Self.before(a.album, b.album, ascending)
        case .composer: Self.before(a.composer, b.composer, ascending)
        case .year: Self.before(a.year.flatMap { $0 > 0 ? $0 : nil }, b.year.flatMap { $0 > 0 ? $0 : nil }, ascending)
        case .duration: Self.before(a.duration, b.duration, ascending)
        case .format: Self.before(a.audioFormat?.codec ?? a.format, b.audioFormat?.codec ?? b.format, ascending)
        case .added: Self.before(a.addedAt, b.addedAt, ascending)
        }
    }

    private static func before(_ a: String, _ b: String, _ ascending: Bool) -> Bool? {
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): return nil
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            // Like Finder's order (`localizedStandardCompare`), but names differing only in case tie.
            let order = a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], locale: .current)
            return order == .orderedSame ? nil : (order == .orderedAscending) == ascending
        }
    }

    private static func before<T: Comparable>(_ a: T?, _ b: T?, _ ascending: Bool) -> Bool? {
        switch (a, b) {
        case (nil, nil): nil
        case (nil, _): false
        case (_, nil): true
        case let (a?, b?): a == b ? nil : (a < b) == ascending
        }
    }
}
