import Foundation

/// Normalized UTF-8 text padded with a space at both ends, so word and word-prefix tests are plain substring tests.
struct IndexedText: Sendable {
    let bytes: [UInt8]

    init(_ parts: [String]) {
        let n = TextNormalizer.normalize(parts.joined(separator: " "))
        bytes = Array((" " + n + " ").utf8)
    }

    var isBlank: Bool { bytes.count <= 2 }

    func contains(_ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > bytes.count { return false }
        return bytes.withUnsafeBytes { h in needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil } }
    }

    func equals(_ padded: [UInt8]) -> Bool { bytes == padded }
}

/// A compiled phrase: normalized words as bytes, plus space-padded variants for word-level matching.
struct Needle: Sendable {
    let sub: [UInt8]
    let prefix: [UInt8]
    let word: [UInt8]

    init(_ normalized: String) {
        sub = Array(normalized.utf8)
        prefix = Array((" " + normalized).utf8)
        word = Array((" " + normalized + " ").utf8)
    }
}

public struct SearchCompletion: Hashable, Sendable {
    public var label: String
    public var detail: String
    /// The full search text to use when this completion is picked.
    public var replacement: String
}

public struct SearchResults: Sendable {
    public var tracks: [Track] = []
    /// Albums and artists that the free text hit directly (or that contain results, for filter-only queries).
    public var albums: [AlbumSummary] = []
    public var artists: [ArtistSummary] = []
    public var issues: [String] = []
    /// When the original text found nothing, the spelling-corrected text these results are for.
    public var correctedText: String?
    public var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    public init(tracks: [Track] = []) { self.tracks = tracks }
}

/// An immutable in-memory index over the whole library. Build it off the main thread; searching is cheap.
public struct SearchIndex: Sendable {
    struct Entry: Sendable {
        var title, artist, albumArtist, album, genre, mbGenre, composer, label, person, country, format, work, all: IndexedText
        var hasCover: Bool
    }

    struct Value: Sendable {
        var display: String
        var norm: String
        var count: Int
    }

    enum ValueKind: Hashable, Sendable { case text(SearchQuery.TextField), year, decade }

    public let tracks: [Track]
    let entries: [Entry]
    let albumSummaries: [String: AlbumSummary]
    let artistSummaries: [String: ArtistSummary]
    let vocabulary: [String: Int]
    let values: [ValueKind: [Value]]

    public static let empty = SearchIndex(tracks: [])

    /// `tracks` should be in the library's natural order; unranked results keep it.
    public init(tracks: [Track], hasCover: (Track) -> Bool = { _ in false }) {
        self.tracks = tracks
        var entries: [Entry] = []
        entries.reserveCapacity(tracks.count)
        var vocab: [String: Int] = [:]
        var counters: [ValueKind: [String: (display: String, count: Int)]] = [:]
        var albums: [String: AlbumSummary] = [:]
        var artistAlbums: [String: Set<String>] = [:]
        var artists: [String: ArtistSummary] = [:]

        func bump(_ kind: ValueKind, _ display: String) {
            let d = display.trimmingCharacters(in: .whitespaces)
            let n = TextNormalizer.normalize(d)
            guard !n.isEmpty else { return }
            counters[kind, default: [:]][n, default: (d, 0)].count += 1
        }

        for t in tracks {
            let m = t.metadata, x = m.extended
            let people = Self.people(of: m)
            let genres = Self.genres(of: m)
            let composers = [m.composer, x.writer, x.lyricist].filter { !$0.isEmpty }
            let formatParts = [t.format, t.audioFormat?.codecLabel ?? "", t.audioFormat?.codec ?? ""]
            let e = Entry(
                title: IndexedText([m.title]),
                artist: IndexedText([m.artist, m.albumArtist]),
                albumArtist: IndexedText([t.effectiveAlbumArtist]),
                album: IndexedText([m.album]),
                genre: IndexedText(genres),
                mbGenre: IndexedText(m.extended.mbGenres),
                composer: IndexedText(composers),
                label: IndexedText([x.label]),
                person: IndexedText(people + composers),
                country: IndexedText([x.releaseCountry]),
                format: IndexedText(formatParts),
                work: IndexedText([x.workTitle]),
                all: IndexedText([m.title, m.artist, m.albumArtist, m.album] + genres + composers + [x.label, x.workTitle] + people),
                hasCover: hasCover(t))
            entries.append(e)

            for w in Set(String(decoding: e.all.bytes, as: UTF8.self).split(separator: " ")) where w.count >= 3 {
                vocab[String(w), default: 0] += 1
            }
            bump(.text(.artist), m.artist)
            if !m.albumArtist.isEmpty && m.albumArtist != m.artist { bump(.text(.artist), m.albumArtist) }
            bump(.text(.albumArtist), t.effectiveAlbumArtist)
            bump(.text(.album), m.album)
            bump(.text(.title), m.title)
            genres.forEach { bump(.text(.genre), $0) }
            m.extended.mbGenres.forEach { bump(.text(.mbGenre), $0) }
            composers.forEach { bump(.text(.composer), $0) }
            people.forEach { bump(.text(.person), $0) }
            bump(.text(.label), x.label)
            bump(.text(.country), x.releaseCountry)
            bump(.text(.format), t.audioFormat?.codecLabel ?? t.format.uppercased())
            bump(.text(.work), x.workTitle)
            if let y = m.year, y > 0 {
                bump(.year, String(y))
                bump(.decade, "\(y / 10 * 10)s")
            }

            let aa = t.effectiveAlbumArtist
            let albumKey = Self.albumKey(album: m.album, artist: aa)
            if var a = albums[albumKey] {
                a.trackCount += 1
                if let y = m.year { a.year = max(a.year ?? y, y) }
                if t.path < a.firstTrackPath { a.firstTrackPath = t.path }
                albums[albumKey] = a
            } else {
                albums[albumKey] = AlbumSummary(album: m.album, artist: aa, year: m.year, trackCount: 1, firstTrackPath: t.path)
            }
            let artistKey = aa.lowercased()
            artistAlbums[artistKey, default: []].insert(m.album.lowercased())
            if var a = artists[artistKey] {
                a.trackCount += 1
                artists[artistKey] = a
            } else {
                artists[artistKey] = ArtistSummary(name: aa, albumCount: 0, trackCount: 1)
            }
        }
        for (k, set) in artistAlbums { artists[k]?.albumCount = set.count }

        self.entries = entries
        self.vocabulary = vocab
        self.albumSummaries = albums
        self.artistSummaries = artists
        self.values = counters.mapValues { dict in
            dict.map { Value(display: $0.value.display, norm: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.norm < $1.norm }
        }
    }

    public static func albumKey(album: String, artist: String) -> String { "\(artist.lowercased())\u{1}\(album.lowercased())" }

    /// Everyone credited on a track (credits, performers and the role fields), without duplicates.
    static func people(of m: TrackMetadata) -> [String] {
        let x = m.extended
        var seen = Set<String>()
        var out: [String] = []
        let roles = [x.conductor, x.producer, x.engineer, x.mixer, x.remixer, x.arranger, x.lyricist, x.writer]
        for name in x.credits.map(\.name) + x.performers + roles {
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty, seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return out
    }

    /// Genre tag values split on the usual multi-value separators. MusicBrainz genres are deliberately left
    /// out: they're community tags for the whole artist or release group and often list a dozen unrelated
    /// genres, so they only match the explicit `mbgenre:` filter.
    public static func genres(of m: TrackMetadata) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for g in splitGenres(m.genre) {
            let t = g.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    public static func splitGenres(_ s: String) -> [String] {
        s.split(whereSeparator: { ";,/|".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Searching

    public func search(_ text: String, now: Date = Date(), autocorrect: Bool = true) -> SearchResults {
        let query = SearchQuery.parse(text, now: now)
        var results = run(query, now: now)
        results.issues = query.issues
        if results.tracks.isEmpty, autocorrect, let corrected = correction(for: text), corrected != text {
            var alt = run(SearchQuery.parse(corrected, now: now), now: now)
            if !alt.tracks.isEmpty {
                alt.correctedText = corrected
                alt.issues = query.issues
                results = alt
            }
        }
        return results
    }

    /// Tracks matching `query`, ranked by relevance when it has free text, otherwise in library order.
    public func tracks(matching query: SearchQuery, now: Date = Date()) -> [Track] {
        run(query, now: now).tracks
    }

    func run(_ query: SearchQuery, now: Date) -> SearchResults {
        if query.isEmpty { return SearchResults(tracks: tracks) }
        let compiled = query.groups.map { $0.map { CompiledTerm($0) } }
        let phrases = query.rankingPhrases.map(Needle.init)
        let whole = phrases.isEmpty ? nil : Needle(query.rankingPhrases.joined(separator: " "))

        var hits: [(index: Int, score: Int, artistHit: Bool, albumHit: Bool)] = []
        for (i, e) in entries.enumerated() {
            let t = tracks[i]
            guard compiled.contains(where: { group in group.allSatisfy { $0.matches(e, t, now: now) } }) else { continue }
            if phrases.isEmpty {
                hits.append((i, 0, true, true))
                continue
            }
            var score = 0
            var artistHit = false, albumHit = false
            for p in phrases {
                score += Self.score(e.title, p, 10, 7, 3)
                let a = Self.score(e.artist, p, 8, 6, 2)
                score += a
                let al = Self.score(e.album, p, 6, 4, 2)
                score += al
                if a > 0, e.albumArtist.contains(p.sub) { artistHit = true }
                if al > 0 || (a > 0 && e.albumArtist.contains(p.sub)) { albumHit = true }
                if e.all.contains(p.sub) { score += 1 }
            }
            if let whole {
                if e.title.equals(whole.word) { score += 20 }
                if e.albumArtist.equals(whole.word) { score += 15 }
                if e.album.equals(whole.word) { score += 12 }
            }
            hits.append((i, score, artistHit, albumHit))
        }
        if !phrases.isEmpty {
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        }

        var out = SearchResults()
        out.tracks = hits.map { tracks[$0.index] }
        var seenAlbums = Set<String>(), seenArtists = Set<String>()
        for h in hits {
            let t = tracks[h.index]
            if h.albumHit {
                let k = Self.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
                if seenAlbums.insert(k).inserted, let a = albumSummaries[k] { out.albums.append(a) }
            }
            if h.artistHit {
                let k = t.effectiveAlbumArtist.lowercased()
                if seenArtists.insert(k).inserted, let a = artistSummaries[k] { out.artists.append(a) }
            }
        }
        return out
    }

    static func score(_ text: IndexedText, _ n: Needle, _ word: Int, _ prefix: Int, _ sub: Int) -> Int {
        if text.contains(n.word) { return word }
        if text.contains(n.prefix) { return prefix }
        if text.contains(n.sub) { return sub }
        return 0
    }

    struct CompiledTerm {
        let term: SearchQuery.Term
        let needle: Needle?

        init(_ term: SearchQuery.Term) {
            self.term = term
            switch term.predicate {
            case .text(let s), .field(_, let s): needle = Needle(s)
            default: needle = nil
            }
        }

        func matches(_ e: Entry, _ t: Track, now: Date) -> Bool {
            evaluate(e, t, now: now) != term.negated
        }

        private func evaluate(_ e: Entry, _ t: Track, now: Date) -> Bool {
            switch term.predicate {
            case .text: return e.all.contains(needle!.sub)
            case .field(let f, _): return SearchIndex.text(e, f).contains(needle!.sub)
            case .number(let f, let r):
                guard let v = SearchIndex.number(t, f, now: now) else { return false }
                return r.contains(v)
            case .flag(let flag): return SearchIndex.flag(t, flag)
            case .present(let p): return SearchIndex.present(e, t, p)
            }
        }
    }

    static func text(_ e: Entry, _ f: SearchQuery.TextField) -> IndexedText {
        switch f {
        case .title: e.title
        case .artist: e.artist
        case .albumArtist: e.albumArtist
        case .album: e.album
        case .genre: e.genre
        case .mbGenre: e.mbGenre
        case .composer: e.composer
        case .label: e.label
        case .person: e.person
        case .country: e.country
        case .format: e.format
        case .work: e.work
        }
    }

    static func number(_ t: Track, _ f: SearchQuery.NumberField, now: Date) -> Double? {
        switch f {
        case .year: t.year.map(Double.init)
        case .duration: t.duration
        case .track: t.trackNo.map(Double.init)
        case .disc: t.metadata.discNo.map(Double.init)
        case .bitDepth: t.audioFormat?.bitDepth.map(Double.init)
        case .sampleRate: t.audioFormat?.sampleRate.map(Double.init)
        case .bitrate: t.audioFormat?.bitrate.map(Double.init)
        case .addedDays: max(0, now.timeIntervalSince(t.addedAt) / 86_400)
        case .addedYear: Double(Calendar.current.component(.year, from: t.addedAt))
        }
    }

    static func flag(_ t: Track, _ f: SearchQuery.Flag) -> Bool {
        switch f {
        case .lossless: return t.isLossless == true
        case .lossy: return t.isLossless == false
        case .hires: return t.isHiRes
        case .compilation:
            return TextNormalizer.normalize(t.albumArtist) == "various artists"
                || t.metadata.extended.releaseSecondaryTypes.contains { $0.caseInsensitiveCompare("compilation") == .orderedSame }
        case .live:
            return t.metadata.extended.releaseSecondaryTypes.contains { $0.caseInsensitiveCompare("live") == .orderedSame }
        case .matched: return !(t.metadata.mbRecordingId ?? "").isEmpty
        case .unmatched: return (t.metadata.mbRecordingId ?? "").isEmpty
        }
    }

    static func present(_ e: Entry, _ t: Track, _ p: SearchQuery.PresenceField) -> Bool {
        switch p {
        case .year: return (t.year ?? 0) > 0
        case .genre: return !e.genre.isBlank
        case .composer: return !e.composer.isBlank
        case .album: return !e.album.isBlank
        case .artist: return !TextNormalizer.normalize(t.artist).isEmpty
        case .label: return !e.label.isBlank
        case .mbid: return !(t.metadata.mbRecordingId ?? "").isEmpty
        case .credits: return !t.metadata.extended.credits.isEmpty || !t.metadata.extended.performers.isEmpty
        case .cover: return e.hasCover
        }
    }

    // MARK: Spelling correction

    /// Replaces words that appear nowhere in the library with the closest library word, or nil if nothing changes.
    public func correction(for text: String) -> String? {
        var out = text
        var changed = false
        for token in SearchTokenizer.tokenize(text).reversed() where !token.isOr && !token.negated {
            if let key = token.key {
                guard let filter = SearchFilterKey.lookup(key), case .text = filter.kind else { continue }
            }
            let words = TextNormalizer.normalize(token.value).split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            var fixed = words
            for (i, w) in words.enumerated() {
                if let c = closestWord(w) { fixed[i] = c }
            }
            guard fixed != words else { continue }
            changed = true
            let value = fixed.joined(separator: " ")
            let quoted = token.quoted || fixed.count > 1 ? "\"\(value)\"" : value
            let replacement = (token.key.map { $0 + ":" } ?? "") + quoted
            out.replaceSubrange(token.range, with: replacement)
        }
        return changed ? out : nil
    }

    func closestWord(_ w: String) -> String? {
        guard w.count >= 3 else { return nil }
        let wb = Array(w.utf8)
        // Already present somewhere (as a word or part of one): leave it alone.
        if vocabulary[w] != nil || vocabulary.keys.contains(where: { $0.utf8.count >= wb.count && $0.contains(w) }) { return nil }
        let maxDistance = wb.count <= 4 ? 1 : (wb.count <= 7 ? 2 : 3)
        var best: (word: String, distance: Int, count: Int)?
        for (candidate, count) in vocabulary {
            let cb = Array(candidate.utf8)
            guard abs(cb.count - wb.count) <= maxDistance else { continue }
            let d = Self.editDistance(wb, cb, limit: maxDistance)
            guard d <= maxDistance else { continue }
            if best == nil || d < best!.distance || (d == best!.distance && (count > best!.count || (count == best!.count && candidate < best!.word))) {
                best = (candidate, d, count)
            }
        }
        return best?.word
    }

    /// Optimal-string-alignment distance (Levenshtein plus adjacent transpositions), early-exiting past `limit`.
    static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    // MARK: Completions

    static let addedPresets: [(String, String)] = [("7d", "Last 7 days"), ("30d", "Last 30 days"), ("90d", "Last 3 months"), ("1y", "Last year")]

    /// Suggestions for the token being typed at the end of `text`.
    public func completions(for text: String, limit: Int = 8) -> [SearchCompletion] {
        guard let last = text.last, !last.isWhitespace,
              let token = SearchTokenizer.tokenize(text).last, !token.isOr else { return [] }
        let prefix = String(text[..<token.range.lowerBound]) + (token.negated ? "-" : "")

        if let key = token.key {
            guard let filter = SearchFilterKey.lookup(key) else { return [] }
            let typed = TextNormalizer.normalize(token.value)
            let head = prefix + key + ":"
            var options: [(display: String, detail: String, norm: String)] = []
            switch filter.kind {
            case .text(let f):
                options = (values[.text(f)] ?? []).map { ($0.display, Self.songs($0.count), $0.norm) }
            case .number(.year):
                options = (values[.year] ?? []).map { ($0.display, Self.songs($0.count), $0.norm) }
            case .decade:
                options = (values[.decade] ?? []).sorted { $0.norm < $1.norm }.map { ($0.display, Self.songs($0.count), $0.norm) }
            case .number(.addedDays):
                options = Self.addedPresets.map { ($0.0, $0.1, $0.0) }
            case .number:
                options = []
            case .flag:
                options = SearchQuery.Flag.allCases.map { ($0.rawValue, Self.flagHelp[$0] ?? "", $0.rawValue) }
            case .presence(let has):
                options = SearchQuery.PresenceField.allCases.map { ($0.rawValue, has ? "Has \($0.rawValue)" : "Missing \($0.rawValue)", $0.rawValue) }
            }
            let ranked = Self.rank(options, typed: typed) { $0.norm }
            return ranked.prefix(limit).map {
                SearchCompletion(label: "\(key):\($0.display)", detail: $0.detail, replacement: head + Self.quoteIfNeeded($0.display) + " ")
            }
        }

        let rawTyped = token.value.lowercased()
        var out: [SearchCompletion] = []
        if !token.quoted, !rawTyped.isEmpty {
            for f in SearchFilterKey.all where f.name.hasPrefix(rawTyped) && f.name != rawTyped {
                out.append(SearchCompletion(label: f.name + ":", detail: f.help, replacement: prefix + f.name + ":"))
            }
        }
        out = Array(out.prefix(3))
        let typed = TextNormalizer.normalize(token.value)
        guard typed.count >= 2 else { return out }
        var picks: [(c: SearchCompletion, count: Int, prefixHit: Bool)] = []
        for (kind, name, label) in [(SearchQuery.TextField.artist, "artist", "Artist"), (.album, "album", "Album"), (.genre, "genre", "Genre"), (.person, "credit", "Credit")] {
            for v in values[.text(kind)] ?? [] {
                guard (" " + v.norm).contains(" " + typed) else { continue }
                let c = SearchCompletion(label: v.display, detail: "\(label) · \(Self.songs(v.count))",
                                         replacement: prefix + name + ":" + Self.quoteIfNeeded(v.display) + " ")
                picks.append((c, v.count, v.norm.hasPrefix(typed)))
                if picks.count > 200 { break }
            }
        }
        picks.sort { $0.prefixHit != $1.prefixHit ? $0.prefixHit : $0.count > $1.count }
        out += picks.prefix(max(0, limit - out.count)).map(\.c)
        return out
    }

    static let flagHelp: [SearchQuery.Flag: String] = [
        .lossless: "FLAC, ALAC, WAV, AIFF", .lossy: "MP3, AAC, …", .hires: "Lossless above 16-bit / 48 kHz",
        .compilation: "Various-artists releases", .live: "Live releases", .matched: "Matched to MusicBrainz",
        .unmatched: "Not matched to MusicBrainz",
    ]

    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

    static func quoteIfNeeded(_ s: String) -> String {
        let clean = s.filter { !SearchTokenizer.quotes.contains($0) }
        return clean.contains(where: { $0.isWhitespace || $0 == ":" }) || clean.hasPrefix("-") ? "\"\(clean)\"" : clean
    }

    static func rank<T>(_ items: [T], typed: String, norm: (T) -> String) -> [T] {
        guard !typed.isEmpty else { return items }
        let starts = items.filter { norm($0).hasPrefix(typed) }
        let words = items.filter { let n = norm($0); return !n.hasPrefix(typed) && (" " + n).contains(" " + typed) }
        let rest = items.filter { let n = norm($0); return !(" " + n).contains(" " + typed) && n.contains(typed) }
        return starts + words + rest
    }

    // MARK: Lookups for UI

    /// The most common values for a field, e.g. top genres for filter menus.
    public func topValues(_ field: SearchQuery.TextField, limit: Int = 20) -> [(name: String, count: Int)] {
        (values[.text(field)] ?? []).prefix(limit).map { ($0.display, $0.count) }
    }

    public var decades: [(name: String, count: Int)] {
        (values[.decade] ?? []).sorted { $0.norm < $1.norm }.map { ($0.display, $0.count) }
    }
}

extension Track {
    /// nil when the format is unknown.
    public var isLossless: Bool? {
        if let codec = audioFormat?.codec.lowercased() { return !AudioFormat.lossyCodecs.contains(codec) }
        switch format.lowercased() {
        case "flac", "wav", "aif", "aiff": return true
        case "mp3", "aac": return false
        default: return nil
        }
    }

    public var isHiRes: Bool {
        guard isLossless == true, let f = audioFormat else { return false }
        return (f.bitDepth ?? 0) > 16 || (f.sampleRate ?? 0) > 48_000
    }
}
