import Foundation

// MARK: Query model

/// A parsed search query: groups joined by `OR`, terms inside a group joined by AND.
///
/// Syntax (all case- and accent-insensitive):
/// - `word`, `"exact phrase"`: matches any text field (title, artists, album, genre, composer, label, credits…)
/// - `field:value`, `field:"two words"`: text fields, e.g. `artist:radiohead`, `genre:jazz`, `label:blue note`
/// - numbers: `year:1997`, `year:1990-1999`, `year:>=2000`, `decade:90s`, `time:>5m`, `rate:96`, `bits:24`, `added:<30d`
/// - flags: `is:lossless`, `is:lossy`, `is:hires`, `is:compilation`, `is:live`, `is:matched`, `is:unmatched`
/// - presence: `missing:year`, `has:credits`, … (see `SearchQuery.PresenceField`)
/// - `-term` negates any term; `OR` (or `|`) separates alternatives.
public struct SearchQuery: Equatable, Sendable {
    public enum TextField: String, CaseIterable, Sendable {
        case title, artist, albumArtist = "albumartist", album, genre, mbGenre = "mbgenre", composer, label, person, country, format, work
    }

    public enum NumberField: String, CaseIterable, Sendable {
        case year, duration, track, disc, bitDepth = "bits", sampleRate = "rate", bitrate, addedDays, addedYear
    }

    public enum Flag: String, CaseIterable, Sendable {
        case lossless, lossy, hires, compilation, live, matched, unmatched
    }

    public enum PresenceField: String, CaseIterable, Sendable {
        case year, genre, composer, album, artist, label, mbid, credits, cover
    }

    public struct NumberRange: Equatable, Sendable {
        public var lower: Double?
        public var lowerInclusive = true
        public var upper: Double?
        public var upperInclusive = true

        public init(lower: Double? = nil, lowerInclusive: Bool = true, upper: Double? = nil, upperInclusive: Bool = true) {
            self.lower = lower; self.lowerInclusive = lowerInclusive; self.upper = upper; self.upperInclusive = upperInclusive
        }

        public func contains(_ x: Double) -> Bool {
            if let lower, lowerInclusive ? x < lower : x <= lower { return false }
            if let upper, upperInclusive ? x > upper : x >= upper { return false }
            return true
        }
    }

    public enum Predicate: Equatable, Sendable {
        /// Normalized words matched as one contiguous phrase against all text.
        case text(String)
        case field(TextField, String)
        case number(NumberField, NumberRange)
        case flag(Flag)
        case present(PresenceField)
    }

    public struct Term: Equatable, Sendable {
        public var predicate: Predicate
        public var negated: Bool
    }

    public var groups: [[Term]]
    /// Problems worth surfacing to the user (unknown filters, unparseable values).
    public var issues: [String]

    public var isEmpty: Bool { groups.allSatisfy(\.isEmpty) }

    /// Positive free-text phrases, used for ranking and to decide whether ranking applies.
    public var rankingPhrases: [String] {
        groups.flatMap { $0 }.compactMap { t in
            guard !t.negated else { return nil }
            switch t.predicate {
            case .text(let s): return s
            case .field(let f, let s) where [.title, .artist, .albumArtist, .album].contains(f): return s
            default: return nil
            }
        }
    }

    public static func parse(_ text: String, now: Date = Date()) -> SearchQuery {
        var groups: [[Term]] = [[]]
        var issues: [String] = []
        for token in SearchTokenizer.tokenize(text) {
            if token.isOr {
                if !(groups.last ?? []).isEmpty { groups.append([]) }
                continue
            }
            switch resolve(token, now: now) {
            case .term(let t): groups[groups.count - 1].append(t)
            case .skip: break
            case .issue(let msg): issues.append(msg)
            }
        }
        groups.removeAll(where: \.isEmpty)
        return SearchQuery(groups: groups, issues: issues)
    }

    private enum Resolution { case term(Term), skip, issue(String) }

    private static func resolve(_ token: SearchTokenizer.Token, now: Date) -> Resolution {
        let neg = token.negated
        guard let key = token.key else {
            let n = TextNormalizer.normalize(token.value)
            return n.isEmpty ? .skip : .term(Term(predicate: .text(n), negated: neg))
        }
        guard let filter = SearchFilterKey.lookup(key) else {
            // Not a filter (e.g. a title containing "re:"): search the whole token as text.
            let n = TextNormalizer.normalize(key + " " + token.value)
            return n.isEmpty ? .skip : .term(Term(predicate: .text(n), negated: neg))
        }
        let raw = token.value.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return .skip }  // still typing
        switch filter.kind {
        case .text(let field):
            let n = TextNormalizer.normalize(raw)
            return n.isEmpty ? .skip : .term(Term(predicate: .field(field, n), negated: neg))
        case .number(let field):
            guard let range = NumberParser.range(raw, field: field, now: now) else {
                return .issue("Can't read “\(raw)” as a value for \(key):")
            }
            if field == .addedDays, let year = NumberParser.yearAdded(raw) {
                return .term(Term(predicate: .number(.addedYear, year), negated: neg))
            }
            return .term(Term(predicate: .number(field, range), negated: neg))
        case .decade:
            guard let start = NumberParser.decadeStart(raw, now: now) else {
                return .issue("Can't read “\(raw)” as a decade (try 1990s or 90s)")
            }
            return .term(Term(predicate: .number(.year, NumberRange(lower: Double(start), upper: Double(start + 9))), negated: neg))
        case .flag:
            guard let flag = Flag(rawValue: raw.lowercased()) ?? flagAliases[raw.lowercased()] else {
                return .issue("Unknown is: value “\(raw)”")
            }
            return .term(Term(predicate: .flag(flag), negated: neg))
        case .presence(let present):
            guard let field = PresenceField(rawValue: raw.lowercased()) ?? presenceAliases[raw.lowercased()] else {
                return .issue("Unknown \(present ? "has" : "missing"): value “\(raw)”")
            }
            return .term(Term(predicate: .present(field), negated: present ? neg : !neg))
        }
    }

    static let flagAliases: [String: Flag] = ["hi-res": .hires, "hd": .hires, "compilations": .compilation, "va": .compilation]
    static let presenceAliases: [String: PresenceField] = ["musicbrainz": .mbid, "mb": .mbid, "art": .cover, "artwork": .cover, "credit": .credits]
}

// MARK: Filter keys

public struct SearchFilterKey: Sendable {
    public enum Kind: Sendable, Equatable {
        case text(SearchQuery.TextField)
        case number(SearchQuery.NumberField)
        case decade
        case flag
        case presence(Bool)
    }

    public var name: String
    public var aliases: [String]
    public var kind: Kind
    public var help: String
    public var example: String

    /// Canonical filters in display order; aliases are accepted when parsing.
    public static let all: [SearchFilterKey] = [
        .init(name: "artist", aliases: ["by"], kind: .text(.artist), help: "Track or album artist", example: "artist:\"miles davis\""),
        .init(name: "album", aliases: ["release"], kind: .text(.album), help: "Album title", example: "album:blue"),
        .init(name: "title", aliases: ["song", "track-title"], kind: .text(.title), help: "Song title", example: "title:love"),
        .init(name: "genre", aliases: ["style"], kind: .text(.genre), help: "Genre tag", example: "genre:jazz"),
        .init(name: "mbgenre", aliases: ["tag"], kind: .text(.mbGenre), help: "MusicBrainz community genres (broad and noisy)", example: "mbgenre:\"hard bop\""),
        .init(name: "composer", aliases: ["writer"], kind: .text(.composer), help: "Composer, writer or lyricist", example: "composer:ellington"),
        .init(name: "credit", aliases: ["person", "who", "producer", "performer"], kind: .text(.person), help: "Anyone credited (players, producers, engineers…)", example: "credit:\"rudy van gelder\""),
        .init(name: "label", aliases: [], kind: .text(.label), help: "Record label", example: "label:\"blue note\""),
        .init(name: "albumartist", aliases: ["aa"], kind: .text(.albumArtist), help: "Album artist only", example: "albumartist:\"various artists\""),
        .init(name: "country", aliases: [], kind: .text(.country), help: "Release country code", example: "country:gb"),
        .init(name: "work", aliases: [], kind: .text(.work), help: "Musical work", example: "work:\"so what\""),
        .init(name: "format", aliases: ["codec", "ext"], kind: .text(.format), help: "File format or codec", example: "format:flac"),
        .init(name: "year", aliases: ["y"], kind: .number(.year), help: "Release year, range or comparison", example: "year:1990-1999"),
        .init(name: "decade", aliases: [], kind: .decade, help: "Release decade", example: "decade:60s"),
        .init(name: "time", aliases: ["length", "duration"], kind: .number(.duration), help: "Track length (m, s, or m:ss)", example: "time:>10m"),
        .init(name: "added", aliases: [], kind: .number(.addedDays), help: "Added within (d/w/m/y), or the year added", example: "added:30d"),
        .init(name: "rate", aliases: ["samplerate", "khz"], kind: .number(.sampleRate), help: "Sample rate in kHz", example: "rate:>=96"),
        .init(name: "bits", aliases: ["bitdepth"], kind: .number(.bitDepth), help: "Bit depth", example: "bits:24"),
        .init(name: "bitrate", aliases: ["kbps"], kind: .number(.bitrate), help: "Bitrate in kbps", example: "bitrate:<256"),
        .init(name: "track", aliases: [], kind: .number(.track), help: "Track number", example: "track:1"),
        .init(name: "disc", aliases: [], kind: .number(.disc), help: "Disc number", example: "disc:2"),
        .init(name: "is", aliases: [], kind: .flag, help: "lossless, lossy, hires, compilation, live, matched, unmatched", example: "is:hires"),
        .init(name: "missing", aliases: ["no"], kind: .presence(false), help: "year, genre, composer, album, artist, label, mbid, credits, cover", example: "missing:genre"),
        .init(name: "has", aliases: [], kind: .presence(true), help: "Opposite of missing:", example: "has:credits"),
    ]

    private static let byName: [String: SearchFilterKey] = {
        var d: [String: SearchFilterKey] = [:]
        for k in all { for n in [k.name] + k.aliases { d[n] = k } }
        return d
    }()

    public static func lookup(_ key: String) -> SearchFilterKey? { byName[key.lowercased()] }

    /// A `key:value` token, quoting the value when needed, e.g. `genre:"Modal Jazz"`.
    public static func token(_ key: String, _ value: String) -> String { key + ":" + SearchIndex.quoteIfNeeded(value) }
}

// MARK: Tokenizer

enum SearchTokenizer {
    struct Token: Equatable {
        /// Character range of the whole token (including any leading `-`) in the source text.
        var range: Range<String.Index>
        var negated: Bool
        var key: String?
        var value: String
        var quoted: Bool
        var isOr: Bool { !negated && key == nil && !quoted && (value == "OR" || value == "|") }
    }

    static let quotes: Set<Character> = ["\"", "“", "”"]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace { i = text.index(after: i); continue }
            let start = i
            var negated = false
            if text[i] == "-", text.index(after: i) < text.endIndex, !text[text.index(after: i)].isWhitespace {
                negated = true
                i = text.index(after: i)
            }
            var head = ""
            var key: String?
            var value = ""
            var quoted = false
            while i < text.endIndex, !text[i].isWhitespace {
                let c = text[i]
                if quotes.contains(c) {
                    quoted = true
                    i = text.index(after: i)
                    var inner = ""
                    while i < text.endIndex, !quotes.contains(text[i]) { inner.append(text[i]); i = text.index(after: i) }
                    if i < text.endIndex { i = text.index(after: i) }
                    if key != nil { value += inner } else { head += inner }
                    continue
                }
                if c == ":", key == nil, !quoted, !head.isEmpty {
                    key = head
                    head = ""
                } else if key != nil {
                    value.append(c)
                } else {
                    head.append(c)
                }
                i = text.index(after: i)
            }
            if key == nil { value = head }
            tokens.append(Token(range: start..<i, negated: negated, key: key, value: value, quoted: quoted))
        }
        return tokens
    }
}

// MARK: Number parsing

enum NumberParser {
    enum Op { case eq, lt, le, gt, ge }

    static func range(_ raw: String, field: SearchQuery.NumberField, now: Date) -> SearchQuery.NumberRange? {
        var s = raw.lowercased()
        var op = Op.eq
        for (prefix, o) in [(">=", Op.ge), ("<=", .le), (">", .gt), ("<", .lt), ("=", .eq)] where s.hasPrefix(prefix) {
            op = o
            s.removeFirst(prefix.count)
            break
        }
        if op == .eq, let sep = rangeSeparator(s) {
            let parts = s.components(separatedBy: sep)
            guard parts.count == 2 else { return nil }
            let lo = parts[0].isEmpty ? nil : value(parts[0], field: field)
            let hi = parts[1].isEmpty ? nil : value(parts[1], field: field)
            if (!parts[0].isEmpty && lo == nil) || (!parts[1].isEmpty && hi == nil) || (lo == nil && hi == nil) { return nil }
            var r = SearchQuery.NumberRange(lower: lo?.value, upper: hi.map { $0.value + $0.width })
            r.upperInclusive = hi == nil || hi!.width == 0
            if field == .addedDays { r = SearchQuery.NumberRange(lower: lo?.value, upper: hi?.value) }
            return r
        }
        guard let v = value(s, field: field) else { return nil }
        if field == .addedDays {
            // `added:30d` means "within the last 30 days"; comparisons are on age, so `>` means older.
            switch op {
            case .eq, .lt, .le: return .init(lower: 0, upper: v.value)
            case .gt, .ge: return .init(lower: v.value)
            }
        }
        // Comparisons on durations are exact (`time:>5m` includes 5:30); elsewhere the unit counts as a whole.
        let w = field == .duration ? 0 : v.width
        switch op {
        case .eq: return v.width == 0 ? .init(lower: v.value, upper: v.value) : .init(lower: v.value, upper: v.value + v.width, upperInclusive: false)
        case .lt: return .init(upper: v.value, upperInclusive: false)
        case .le: return .init(upper: w == 0 ? v.value : v.value + w, upperInclusive: w == 0)
        case .gt: return .init(lower: w == 0 ? v.value : v.value + w, lowerInclusive: w != 0)
        case .ge: return .init(lower: v.value)
        }
    }

    private static func rangeSeparator(_ s: String) -> String? {
        if s.contains("..") { return ".." }
        // A dash between two values; not a leading minus and not inside an m:ss time.
        return s.dropFirst().contains("-") ? "-" : nil
    }

    /// The parsed value and the width of the unit it was written in (so `year:1997` covers the whole year
    /// and `time:5m` covers 5:00–5:59). Width 0 means exact.
    static func value(_ s: String, field: SearchQuery.NumberField) -> (value: Double, width: Double)? {
        let s = s.trimmingCharacters(in: .whitespaces)
        switch field {
        case .year, .track, .disc, .bitDepth, .addedYear:
            return Int(s).map { (Double($0), 1) }
        case .sampleRate:
            let t = s.hasSuffix("khz") ? String(s.dropLast(3)) : (s.hasSuffix("k") ? String(s.dropLast()) : s)
            guard let v = Double(t), v > 0 else { return nil }
            if v >= 1000 { return (v, 1) }
            return t.contains(".") ? (v * 1000, 100) : (v * 1000, 1000)
        case .bitrate:
            let t = s.hasSuffix("kbps") ? String(s.dropLast(4)) : (s.hasSuffix("k") ? String(s.dropLast()) : s)
            guard let v = Double(t), v > 0 else { return nil }
            return v >= 10_000 ? (v, 1) : (v * 1000, 1000)
        case .duration:
            return duration(s)
        case .addedDays:
            return age(s)
        }
    }

    static func duration(_ s: String) -> (Double, Double)? {
        if s.contains(":") {
            let p = s.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard p.allSatisfy({ $0 != nil }) else { return nil }
            let n = p.compactMap { $0 }
            if n.count == 2 { return (n[0] * 60 + n[1], 1) }
            if n.count == 3 { return (n[0] * 3600 + n[1] * 60 + n[2], 1) }
            return nil
        }
        let units: [(String, Double)] = [("min", 60), ("h", 3600), ("m", 60), ("s", 1)]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            guard let v = Double(s.dropLast(suffix.count)) else { return nil }
            return (v * mult, s.contains(".") ? 0 : mult)
        }
        guard let v = Double(s) else { return nil }
        return (v * 60, s.contains(".") ? 0 : 60)  // bare numbers are minutes
    }

    /// Age in days for `7d`, `2w`, `3m`, `1y`, `today`.
    static func age(_ s: String) -> (Double, Double)? {
        if s == "today" { return (1, 0) }
        let units: [(String, Double)] = [("d", 1), ("w", 7), ("m", 30.44), ("y", 365.25)]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            guard let v = Double(s.dropLast(suffix.count)), v >= 0 else { return nil }
            return (v * mult, 0)
        }
        if let v = Double(s), v < 1000 { return (v, 0) }  // bare number: days
        if yearAdded(s) != nil { return (0, 0) }
        return nil
    }

    static func yearAdded(_ s: String) -> SearchQuery.NumberRange? {
        guard s.count == 4, let y = Int(s), y >= 1900 else { return nil }
        return .init(lower: Double(y), upper: Double(y))
    }

    static func decadeStart(_ raw: String, now: Date) -> Int? {
        var s = raw.lowercased()
        if s.hasSuffix("s") { s.removeLast() }
        if s.hasPrefix("'") { s.removeFirst() }
        guard let v = Int(s), v >= 0 else { return nil }
        if s.count == 2 {
            let currentTwoDigit = (Calendar(identifier: .gregorian).component(.year, from: now) % 100) / 10 * 10
            return v <= currentTwoDigit ? 2000 + v / 10 * 10 : 1900 + v / 10 * 10
        }
        guard s.count == 4 else { return nil }
        return v / 10 * 10
    }
}
