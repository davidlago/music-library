import Foundation

/// What a link in the DJ's words opens: a page in the listener's collection, or a song to play.
public enum RadioDJReference: Hashable, Sendable {
    case artist(String)
    /// A library album (`SearchIndex.albumKey`).
    case album(key: String)
    /// A copy with no tracks in the library (its own page).
    case item(id: String)
    /// A song's album page (a song that can't play here: on the phone, one not on it).
    case song(trackID: Int64)
    /// Plays the song, in its album.
    case play(trackID: Int64)
    /// A song not in the collection: an Apple Music preview, found when it's tapped.
    case preview(title: String, artist: String?)

    public static let scheme = "musiclibrary-dj"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .artist(let name): c.host = "artist"; c.queryItems = [URLQueryItem(name: "v", value: name)]
        case .album(let key): c.host = "album"; c.queryItems = [URLQueryItem(name: "v", value: key)]
        case .item(let id): c.host = "item"; c.queryItems = [URLQueryItem(name: "v", value: id)]
        case .song(let id): c.host = "song"; c.queryItems = [URLQueryItem(name: "v", value: String(id))]
        case .play(let id): c.host = "play"; c.queryItems = [URLQueryItem(name: "v", value: String(id))]
        case .preview(let title, let artist):
            c.host = "preview"
            c.queryItems = [URLQueryItem(name: "v", value: title)] + (artist.map { [URLQueryItem(name: "a", value: $0)] } ?? [])
        }
        return c.url!
    }

    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == Self.scheme,
              let value = c.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        switch c.host {
        case "artist": self = .artist(value)
        case "album": self = .album(key: value)
        case "item": self = .item(id: value)
        case "song": guard let id = Int64(value) else { return nil }; self = .song(trackID: id)
        case "play": guard let id = Int64(value) else { return nil }; self = .play(trackID: id)
        case "preview": self = .preview(title: value, artist: c.queryItems?.first(where: { $0.name == "a" })?.value)
        default: return nil
        }
    }
}

/// A run of the DJ's words: text (with links to the collection) or a song suggested for playing, drawn with a play
/// icon.
public enum RadioDJSegment: Hashable, Sendable {
    case text(AttributedString)
    /// A song in the collection: plays it.
    case play(AttributedString)
    /// A song not in the collection: plays an Apple Music preview.
    case preview(AttributedString)
    /// An artist or album not in the collection: a link to a web page about it.
    case external(AttributedString)
}

/// Wikipedia articles about artists and albums not in the collection, checked before they're linked: the likely
/// titles are asked for in one request ("Affection (Lisa Stansfield album)", "Affection (album)", "Affection"), and
/// the first that is a real article (not missing, not a disambiguation page) about that album (its description names
/// an album and the artist) or about a musician wins. When none is, the articles the disambiguation pages among them
/// list are checked the same way, then a search for the name (with the artist); only articles named after it count,
/// and without the artist only when a single album has that name. Nothing found means no link.
public struct WikipediaArticleFinder: Sendable {
    public typealias Get = @Sendable (URL) async throws -> Data
    private let get: Get

    public init(get: Get? = nil) {
        self.get = get ?? { url in
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw NetworkError.http(code, url.absoluteString) }
            return data
        }
    }

    /// "album|Affection|Lisa Stansfield", what a checked article is kept under.
    public static func key(kind: String, name: String, artist: String?) -> String {
        "\(kind)|\(name)|\(kind == "album" ? artist ?? "" : "")"
    }

    /// The article's address, or nil when there's no article for it (or Wikipedia can't be reached).
    public func article(kind: String, name: String, artist: String?) async -> URL? {
        let candidates = Self.candidates(kind: kind, name: name, artist: artist)
        guard !candidates.isEmpty, let data = try? await get(Self.requestURL(titles: candidates)) else { return nil }
        if let title = Self.pick(data, candidates: candidates, kind: kind, artist: artist) { return Self.pageURL(title: title) }
        for page in Self.disambiguations(data).prefix(2) {
            if let links = try? await get(Self.linksURL(page)), let title = Self.pickAmong(links, name: name, kind: kind, artist: artist) {
                return Self.pageURL(title: title)
            }
        }
        let terms = [name, artist, kind == "album" ? "album" : "musician"].compactMap { $0 }.joined(separator: " ")
        if let found = try? await get(Self.searchURL(terms)), let title = Self.pickAmong(found, name: name, kind: kind, artist: artist) {
            return Self.pageURL(title: title)
        }
        return nil
    }

    static func candidates(kind: String, name: String, artist: String?) -> [String] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { return [] }
        let artist = artist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let titles: [String] = switch kind {
        case "album": [artist.map { "\(name) (\($0) album)" }, "\(name) (album)", name, artist.map { "\(name) (\($0) EP)" }].compactMap { $0 }
        case "artist": [name, "\(name) (musician)", "\(name) (singer)", "\(name) (band)", "\(name) (rapper)"]
        default: []
        }
        // Wikipedia's titles can't hold these.
        return titles.filter { !$0.contains(where: { "|#<>[]{}".contains($0) }) }
    }

    static func requestURL(titles: [String]) -> URL {
        apiURL([URLQueryItem(name: "titles", value: titles.joined(separator: "|"))])
    }

    /// The articles a disambiguation page lists.
    static func linksURL(_ page: String) -> URL {
        apiURL([URLQueryItem(name: "generator", value: "links"), URLQueryItem(name: "titles", value: page),
                URLQueryItem(name: "gplnamespace", value: "0"), URLQueryItem(name: "gpllimit", value: "max")])
    }

    static func searchURL(_ terms: String) -> URL {
        apiURL([URLQueryItem(name: "generator", value: "search"), URLQueryItem(name: "gsrsearch", value: terms),
                URLQueryItem(name: "gsrlimit", value: "10")])
    }

    /// A query for pages with their description and whether they're disambiguation pages.
    private static func apiURL(_ items: [URLQueryItem]) -> URL {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"), URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "prop", value: "pageprops|description"), URLQueryItem(name: "ppprop", value: "disambiguation"),
        ] + items
        return c.url!
    }

    /// The disambiguation pages among the answer's pages.
    static func disambiguations(_ data: Data) -> [String] {
        let pages = (try? JSONDecoder().decode(JSONValue.self, from: data))?["query"]?["pages"]?.array ?? []
        return pages.filter { $0["pageprops"]?["disambiguation"] != nil }.compactMap { $0["title"]?.string }
    }

    /// From a list of pages (a disambiguation page's links, search results): the first, in search order or else the
    /// shortest title, that's named after `name` ("Real Love (Lisa Stansfield album)" for "Real Love") and about it.
    /// Without the artist, an album is picked only when it's the only one by that name: "Affection" alone could be
    /// Lisa Stansfield's, Jody Watley's or Koda Kumi's.
    static func pickAmong(_ data: Data, name: String, kind: String, artist: String?) -> String? {
        let pages = (try? JSONDecoder().decode(JSONValue.self, from: data))?["query"]?["pages"]?.array ?? []
        let key = RadioDJLinker.norm(name)
        let about = pages
            .filter { $0["missing"] == nil && $0["pageprops"]?["disambiguation"] == nil }
            .filter { page in page["title"]?.string.map { RadioDJLinker.forms($0).contains(key) } ?? false }
            .filter { page in
                isAbout(kind: kind, title: page["title"]?.string ?? "", description: page["description"]?.string ?? "", artist: artist)
            }
        if kind == "album", artist == nil, Set(about.compactMap { $0["title"]?.string }).count > 1 { return nil }
        return about
            .sorted { a, b in
                let ia = a["index"]?.int ?? Int.max, ib = b["index"]?.int ?? Int.max
                return ia != ib ? ia < ib : (a["title"]?.string?.count ?? 0) < (b["title"]?.string?.count ?? 0)
            }
            .first?["title"]?.string
    }

    static func pageURL(title: String) -> URL {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? title
        return URL(string: "https://en.wikipedia.org/wiki/\(path)")!
    }

    static let albumWords = ["album", "ep", "soundtrack", "compilation", "mixtape", "live album"]
    static let musicianWords = ["musician", "singer", "band", "rapper", "songwriter", "composer", "group", "guitarist",
                                "pianist", "drummer", "bassist", "vocalist", "saxophonist", "trumpeter", "producer", "dj",
                                "duo", "trio", "quartet", "orchestra", "conductor", "violinist", "cellist", "organist",
                                "keyboardist", "bandleader", "performer", "music", "supergroup", "ensemble"]

    /// The title of the first candidate that is a real article about it, from the API's answer.
    static func pick(_ data: Data, candidates: [String], kind: String, artist: String?) -> String? {
        guard let query = (try? JSONDecoder().decode(JSONValue.self, from: data))?["query"] else { return nil }
        func map(_ key: String) -> [String: String] {
            Dictionary((query[key]?.array ?? []).compactMap { e in e["from"]?.string.flatMap { f in e["to"]?.string.map { (f, $0) } } },
                       uniquingKeysWith: { a, _ in a })
        }
        let normalized = map("normalized"), redirects = map("redirects")
        var pages: [String: JSONValue] = [:]
        for page in query["pages"]?.array ?? [] { if let title = page["title"]?.string { pages[title] = page } }
        for candidate in candidates {
            let title = normalized[candidate].map { redirects[$0] ?? $0 } ?? redirects[candidate] ?? candidate
            guard let page = pages[title], page["missing"] == nil, page["invalid"] == nil,
                  page["pageprops"]?["disambiguation"] == nil else { continue }
            let description = page["description"]?.string ?? ""
            if isAbout(kind: kind, title: title, description: description, artist: artist) { return title }
        }
        return nil
    }

    static func isAbout(kind: String, title: String, description: String, artist: String?) -> Bool {
        let words = Set(RadioDJLinker.norm(description).split(separator: " ").map(String.init))
        let text = RadioDJLinker.norm(description + " " + title)
        switch kind {
        case "album":
            guard albumWords.contains(where: { $0.contains(" ") ? text.contains($0) : words.contains($0) }) || title.lowercased().contains("album") else { return false }
            guard let artist else { return true }
            return text.contains(RadioDJLinker.norm(artist))
        case "artist":
            return musicianWords.contains { words.contains($0) }
        default:
            return false
        }
    }
}

/// Turns the references the DJ writes (`[Kind of Blue](album)`, `[So What](song "Miles Davis")`, `[So What](play)`,
/// `[Miles Davis](artist)`) into links to what the listener owns. Names are matched loosely (case, accents,
/// punctuation, "the", "&"), the hint and the page's album and artist break ties, and anything not found or still
/// ambiguous is shown as plain text, so a link never opens the wrong record.
public struct RadioDJLinker: Sendable {
    private struct Song: Sendable { var track: Track; var albumKey: String }

    private var artists: [String: String] = [:]
    private var albums: [String: [(key: String, artist: String)]] = [:]
    private var items: [String: [CollectionItem]] = [:]
    private var songs: [String: [Song]] = [:]
    private var pageAlbumKey: String?
    private var pageArtist: String?
    private let canPlay: @Sendable (Track) -> Bool

    /// `canPlay`: whether a song can play here (on the phone, only songs on it); others link to their album instead.
    public init(tracks: [Track], collection: MusicCollection, subject: RadioDJSubject?, canPlay: @escaping @Sendable (Track) -> Bool = { _ in true }) {
        self.canPlay = canPlay
        setPage(subject)
        var seenAlbums = Set<String>()
        for t in tracks {
            for name in [t.artist, t.effectiveAlbumArtist] where !name.isEmpty { artists[Self.norm(name)] = artists[Self.norm(name)] ?? name }
            let key = LibrarySearch.key(t)
            if seenAlbums.insert(key).inserted, !t.album.isEmpty {
                for form in Self.forms(t.album) { albums[form, default: []].append((key, t.effectiveAlbumArtist)) }
            }
            if !t.title.isEmpty {
                for form in Self.forms(t.title) { songs[form, default: []].append(Song(track: t, albumKey: key)) }
            }
        }
        for item in collection.items where !item.album.isEmpty {
            if !item.artist.isEmpty { artists[Self.norm(item.artist)] = artists[Self.norm(item.artist)] ?? item.artist }
            guard !seenAlbums.contains(item.albumKey) else { continue }
            for form in Self.forms(item.album) { items[form, default: []].append(item) }
        }
    }

    /// The page the conversation is about, which breaks ties between songs and albums of the same name.
    public mutating func setPage(_ subject: RadioDJSubject?) {
        switch subject?.kind {
        case .album: pageAlbumKey = SearchIndex.albumKey(album: subject!.title, artist: subject!.artist ?? ""); pageArtist = subject!.artist
        case .artist: pageAlbumKey = nil; pageArtist = subject!.title
        case .page, nil: pageAlbumKey = nil; pageArtist = nil
        }
    }

    // MARK: Matching

    /// Lowercased, accents and punctuation dropped, "&" as "and", without a leading "the".
    static func norm(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            .split(separator: " ")
        let joined = words.joined(separator: " ")
        return joined.hasPrefix("the ") ? String(joined.dropFirst(4)) : joined
    }

    /// The name, and without what's in parentheses or brackets ("So What (Remastered)" is also "so what").
    static func forms(_ s: String) -> [String] {
        let full = norm(s)
        let bare = norm(s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression))
        return bare.isEmpty || bare == full ? [full] : [full, bare]
    }

    private func matches(_ name: String, _ hint: String?) -> Bool { hint.map { Self.norm(name) == Self.norm($0) } ?? false }

    public func resolve(kind: String, name: String, hint: String?) -> RadioDJReference? {
        let key = Self.norm(name)
        guard !key.isEmpty else { return nil }
        switch kind {
        case "artist":
            return artists[key].map(RadioDJReference.artist)
        case "album":
            if let found = pick(albums[key] ?? [], artist: \.artist, preferring: { $0.key == pageAlbumKey }, hint: hint) {
                return .album(key: found.key)
            }
            return pick(items[key] ?? [], artist: \.artist, preferring: { _ in false }, hint: hint).map { .item(id: $0.id) }
        case "song", "play":
            var pool = songs[key] ?? []
            // The hint (an artist or album) must match: a song by someone else isn't the one meant.
            if let hint {
                pool = pool.filter { matches($0.track.artist, hint) || matches($0.track.effectiveAlbumArtist, hint) || matches($0.track.album, hint) }
            }
            // Then the page's album, then its artist, narrow it down.
            let onPage = pool.filter { $0.albumKey == pageAlbumKey }
            if !onPage.isEmpty { pool = onPage }
            let byArtist = pool.filter { matches($0.track.effectiveAlbumArtist, pageArtist) || matches($0.track.artist, pageArtist) }
            if !byArtist.isEmpty { pool = byArtist }
            // Versions by one artist are fine (the first); several artists are ambiguous.
            guard let song = pool.first, Set(pool.map { Self.norm($0.track.artist) }).count == 1 else { return nil }
            // Every song that can play here gets the play button, whichever way the DJ tagged it.
            return canPlay(song.track) ? .play(trackID: song.track.id) : .song(trackID: song.track.id)
        default:
            return nil
        }
    }

    /// One of `candidates`: the hint's artist, then `preferring`, then the page's artist, then the only one.
    private func pick<T>(_ candidates: [T], artist: KeyPath<T, String>, preferring: (T) -> Bool, hint: String?) -> T? {
        guard !candidates.isEmpty else { return nil }
        if let hint {
            let hinted = candidates.filter { matches($0[keyPath: artist], hint) }
            if let first = hinted.first { return first }
        }
        if let first = candidates.first(where: preferring) { return first }
        if let first = candidates.first(where: { matches($0[keyPath: artist], pageArtist) }) { return first }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: Rendering

    static let pattern = try! NSRegularExpression(pattern: #"\[([^\[\]\n]{1,200})\]\((artist|album|song|play)(?:\s+"([^"\n]{0,200})")?\)"#)
    /// A reference still being written at the end of a streaming reply.
    static let partial = try! NSRegularExpression(pattern: #"\[[^\[\]\n]{0,200}(\]\([^)\n]{0,220})?$"#)

    /// The DJ's words as segments. `streaming`: hides a reference still being written at the end. `webPages`: the checked
    /// Wikipedia articles of artists and albums not in the collection, by `WikipediaArticleFinder.key` (others aren't
    /// linked).
    public func render(_ raw: String, streaming: Bool = false, webPages: [String: URL] = [:]) -> [RadioDJSegment] {
        var text = raw
        if streaming, let m = Self.partial.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text) {
            text.removeSubrange(r)
        }
        var segments: [RadioDJSegment] = []
        var markdown = ""
        func flush() {
            if !markdown.isEmpty { segments.append(.text(RadioDJ.attributed(markdown))) }
            markdown = ""
        }
        var cursor = text.startIndex
        for m in Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let labelRange = Range(m.range(at: 1), in: text),
                  let kindRange = Range(m.range(at: 2), in: text) else { continue }
            markdown += text[cursor..<whole.lowerBound]
            cursor = whole.upperBound
            let label = String(text[labelRange])
            let kind = String(text[kindRange])
            let hint = Range(m.range(at: 3), in: text).map { String(text[$0]) }
            func emphasized(_ link: URL) -> AttributedString {
                var title = AttributedString(label)
                title.link = link
                title.inlinePresentationIntent = .stronglyEmphasized
                return title
            }
            switch resolve(kind: kind, name: label, hint: hint) {
            case let .play(id)?:
                flush()
                segments.append(.play(emphasized(RadioDJReference.play(trackID: id).url)))
            case let reference?:
                markdown += "[\(Self.escaped(label))](\(reference.url.absoluteString))"
            case nil:
                // Not in the collection: a preview to hear (by the hinted artist, else the page's), a page to read.
                let artist = hint ?? pageArtist
                if kind == "song" || kind == "play" {
                    if artist != nil {
                        flush()
                        segments.append(.preview(emphasized(RadioDJReference.preview(title: label, artist: artist).url)))
                    } else {
                        markdown += "“\(Self.escaped(label))”"
                    }
                } else if let page = webPages[WikipediaArticleFinder.key(kind: kind, name: label, artist: artist)] {
                    flush()
                    var title = AttributedString(label)
                    title.link = page
                    if kind == "album" { title.inlinePresentationIntent = .emphasized }
                    segments.append(.external(title))
                } else {
                    markdown += kind == "album" ? "*\(Self.escaped(label))*" : Self.escaped(label)
                }
            }
        }
        markdown += text[cursor...]
        flush()
        return segments
    }

    /// The artists and albums in `raw` that aren't in the collection: what to look up on Wikipedia.
    public func webCandidates(_ raw: String) -> [(kind: String, name: String, artist: String?)] {
        var out: [(kind: String, name: String, artist: String?)] = []
        var seen = Set<String>()
        for m in Self.pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let labelRange = Range(m.range(at: 1), in: raw), let kindRange = Range(m.range(at: 2), in: raw) else { continue }
            let kind = String(raw[kindRange]), label = String(raw[labelRange])
            guard kind == "album" || kind == "artist" else { continue }
            let hint = Range(m.range(at: 3), in: raw).map { String(raw[$0]) }
            guard resolve(kind: kind, name: label, hint: hint) == nil else { continue }
            let artist = kind == "album" ? hint ?? pageArtist : nil
            if seen.insert(WikipediaArticleFinder.key(kind: kind, name: label, artist: artist)).inserted {
                out.append((kind, label, artist))
            }
        }
        return out
    }

    /// Without a library to link to: every reference as plain text.
    public static func plain(_ raw: String, streaming: Bool = false) -> [RadioDJSegment] {
        RadioDJLinker(tracks: [], collection: .empty, subject: nil).render(raw, streaming: streaming)
    }

    /// The label with characters markdown would read as emphasis or links kept literal.
    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s {
            if "*_`[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
