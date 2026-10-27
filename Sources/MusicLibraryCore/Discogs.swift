import Foundation

// Discogs' database (api.discogs.com, no key): a second place to find the edition you own when MusicBrainz doesn't
// list it, which is often the case for records. Add to Collection and Change Edition… search it by barcode, words or
// catalog number, or look up a pasted release link; the release picked gives the item its details, cover and track
// list (`CollectionItem.discogsReleaseID`, read again for the album info and for Digitize Vinyl).

public enum DiscogsError: Error, LocalizedError, Equatable {
    /// 429: Discogs allows 25 requests a minute without a key.
    case busy
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .busy: "Discogs is busy. Try again in a minute."
        case .http(let code): "Discogs answered with an error (HTTP \(code))."
        case .badResponse: "Discogs sent something unexpected."
        }
    }
}

/// Discogs links: a release page ("https://www.discogs.com/release/2772432-Miles-Davis-Kind-Of-Blue", with or without
/// a language path, "discogs.com/release/2772432") or the site's own "[r2772432]" shorthand.
public enum DiscogsLink {
    public static func releaseID(in text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[r"), t.hasSuffix("]") { return id(String(t.dropFirst(2).dropLast())) }
        let lower = t.lowercased()
        guard lower.contains("discogs.com/"), !lower.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: lower.hasPrefix("http") ? t : "https://" + t), let host = url.host?.lowercased(),
              host == "discogs.com" || host.hasSuffix(".discogs.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let i = parts.firstIndex(where: { $0.lowercased() == "release" }), i + 1 < parts.count else { return nil }
        return id(String(parts[i + 1].prefix { $0.isNumber }))
    }

    public static func releaseURL(_ id: Int) -> URL? { URL(string: "https://www.discogs.com/release/\(id)") }

    /// A release ID: 1 to 999,999,999.
    static func id(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 9, s.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(s), n > 0 else { return nil }
        return n
    }

    static func isValid(_ id: Int?) -> Bool { id.map { (1...999_999_999).contains($0) } ?? false }

    /// Images are only downloaded over https from Discogs' own hosts.
    public static func isImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "discogs.com" || host.hasSuffix(".discogs.com")
    }
}

/// One Discogs release, as its page lists it.
public struct DiscogsRelease: Hashable, Sendable {
    public var id: Int
    public var title: String
    public var artist: String
    /// "2016-08-26", "1959", "" (Discogs' "-00" parts dropped).
    public var released: String
    public var year: Int?
    public var country: String
    public var labels: [String]
    public var catalogNumbers: [String]
    public var barcode: String
    /// One name per disc, as MusicBrainz names them: "12\" Vinyl", "CD", "Digital Media".
    public var media: [String]
    /// "LP, Album, Reissue, Gatefold, 180g".
    public var formatNotes: String
    public var masterID: Int?
    /// Genres, then styles.
    public var genres: [String]
    public var tracks: [ReleaseTrack]
    /// The primary image first.
    public var images: [URL]
    public var thumbnail: URL?

    public var webURL: URL? { DiscogsLink.releaseURL(id) }

    /// The release as an edition to pick.
    public var edition: CollectionEdition {
        var e = CollectionEdition(
            id: CollectionEdition.discogsID(id), title: title, artist: artist, date: released, country: country,
            recordLabel: MusicBrainzParser.joinedUnique(labels), catalogNumber: MusicBrainzParser.joinedUnique(catalogNumbers),
            barcode: barcode, formatDetail: media.isEmpty ? "" : CDEditionParser.formatSummary(media),
            discCount: max(media.count, Set(tracks.map(\.discNo)).count), trackCount: tracks.count,
            releaseGroupTitle: title, medium: CollectionMedium(musicBrainzFormats: media))
        e.discogsReleaseID = id
        e.discogsMasterID = masterID
        e.formatNotes = formatNotes
        e.thumbnail = thumbnail
        return e
    }

    /// The release in the form MusicBrainz releases take, for album info and naming digitized tracks. It has no
    /// MusicBrainz IDs: `id` is empty, and so is every track's recording.
    public var releaseInfo: ReleaseInfo {
        var r = ReleaseInfo(id: "", releaseGroupId: nil, album: title, albumArtist: artist, date: released.isEmpty ? nil : released,
                            year: year, originalYear: nil, discTotal: tracks.map(\.discNo).max() ?? 0, tracks: tracks)
        r.label = MusicBrainzParser.joinedUnique(labels)
        r.catalogNumber = MusicBrainzParser.joinedUnique(catalogNumbers)
        r.barcode = barcode
        r.country = country
        // Genres before the styles under them: the first few become the files' genre tag.
        r.releaseGenres = genres.enumerated().map { Genre(name: $0.element, count: genres.count - $0.offset) }
        return r
    }
}

public enum DiscogsParser {
    /// The releases in a database search, in Discogs' order. With a `medium`, only those with a medium of it;
    /// downloads take any release, as on MusicBrainz.
    public static func parseSearch(_ data: Data, medium: CollectionMedium? = nil) throws -> [CollectionEdition] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscogsError.badResponse }
        let all = (root["results"] as? [[String: Any]] ?? []).compactMap(searchEdition)
        switch medium {
        case nil, .download?: return all
        case let wanted?: return all.filter { $0.medium == wanted }
        }
    }

    static func searchEdition(_ r: [String: Any]) -> CollectionEdition? {
        guard (r["type"] as? String ?? "release") == "release", let id = r["id"] as? Int, DiscogsLink.isValid(id) else { return nil }
        // Search results only have "Artist - Title".
        let full = r["title"] as? String ?? ""
        let (artist, title) = full.range(of: " - ").map { (String(full[..<$0.lowerBound]), String(full[$0.upperBound...])) } ?? ("", full)
        let formats = r["formats"] as? [[String: Any]] ?? []
        let media = Self.media(formats)
        var e = CollectionEdition(
            id: CollectionEdition.discogsID(id), title: trimmed(title), artist: clean(artist), date: r["year"] as? String ?? "",
            country: r["country"] as? String ?? "",
            // The first label is the release's; the rest are often distributors and other companies.
            recordLabel: (r["label"] as? [String])?.first.map(clean) ?? "", catalogNumber: trimmed(r["catno"] as? String ?? ""),
            barcode: barcode(r["barcode"] as? [String] ?? []), formatDetail: media.isEmpty ? "" : CDEditionParser.formatSummary(media),
            discCount: media.count, releaseGroupTitle: trimmed(title), medium: CollectionMedium(musicBrainzFormats: media))
        if e.catalogNumber.lowercased() == "none" { e.catalogNumber = "" }
        e.discogsReleaseID = id
        e.discogsMasterID = (r["master_id"] as? Int).flatMap { DiscogsLink.isValid($0) ? $0 : nil }
        e.formatNotes = notes(formats)
        e.thumbnail = image(r["thumb"])
        return e
    }

    public static func parseRelease(_ data: Data) throws -> DiscogsRelease {
        guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = r["id"] as? Int,
              DiscogsLink.isValid(id) else { throw DiscogsError.badResponse }
        let formats = r["formats"] as? [[String: Any]] ?? []
        let media = Self.media(formats)
        let artist = credit(r["artists"])
        let labels = r["labels"] as? [[String: Any]] ?? []
        let identifiers = r["identifiers"] as? [[String: Any]] ?? []
        let code = barcode(identifiers.filter { $0["type"] as? String == "Barcode" }.compactMap { $0["value"] as? String })
        let images = (r["images"] as? [[String: Any]] ?? [])
            .sorted { ($0["type"] as? String == "primary" ? 0 : 1) < ($1["type"] as? String == "primary" ? 0 : 1) }
        return DiscogsRelease(
            id: id, title: trimmed(r["title"] as? String ?? ""), artist: artist, released: date(r["released"] as? String ?? ""),
            year: (r["year"] as? Int).flatMap { (1000...9999).contains($0) ? $0 : nil }, country: r["country"] as? String ?? "",
            labels: labels.compactMap { ($0["name"] as? String).map(clean) }.filter { !$0.isEmpty },
            // A label entry sometimes gives the barcode as its catalog number.
            catalogNumbers: labels.compactMap { $0["catno"] as? String }.map(trimmed)
                .filter { !$0.isEmpty && $0.lowercased() != "none" && (code.isEmpty || barcode([$0]) != code) },
            barcode: code,
            media: media, formatNotes: notes(formats),
            masterID: (r["master_id"] as? Int).flatMap { DiscogsLink.isValid($0) ? $0 : nil },
            genres: CreditDerivation.dedupe((r["genres"] as? [String] ?? []) + (r["styles"] as? [String] ?? [])),
            tracks: tracks(r["tracklist"] as? [[String: Any]] ?? [], media: media, artist: artist),
            images: images.compactMap { image($0["uri"]) }, thumbnail: images.lazy.compactMap { image($0["uri150"]) }.first)
    }

    // MARK: Tracks

    /// The release's songs, numbered from 1 on each disc. A record's sides go two to a disc when it has more than one
    /// ("C1" starts the second LP), "2-3" names its disc, and a CD's numbers starting over start the next disc.
    /// Headings are left out; a work's movements are songs of their own when each has a position ("A1a", "A1b").
    static func tracks(_ list: [[String: Any]], media: [String], artist: String) -> [ReleaseTrack] {
        struct Raw { var position: String; var title: String; var duration: Double?; var artist: String }
        func raw(_ t: [String: Any], title: String? = nil) -> Raw {
            let own = credit(t["artists"])
            return Raw(position: (t["position"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                       title: title ?? t["title"] as? String ?? "", duration: duration(t["duration"] as? String ?? ""),
                       artist: own.isEmpty ? artist : own)
        }
        var flat: [Raw] = []
        for t in list {
            switch t["type_"] as? String ?? "track" {
            case "heading": continue
            case "index":
                let name = t["title"] as? String ?? ""
                let subs = (t["sub_tracks"] as? [[String: Any]] ?? []).filter { $0["type_"] as? String != "heading" }
                let positions = subs.map { ($0["position"] as? String ?? "").trimmingCharacters(in: .whitespaces) }
                if !subs.isEmpty, !positions.contains(""), Set(positions).count == subs.count {
                    flat += subs.map { s in
                        let part = s["title"] as? String ?? ""
                        return raw(s, title: name.isEmpty ? part : part.isEmpty ? name : "\(name): \(part)")
                    }
                } else {
                    var whole = raw(t)
                    if whole.position.isEmpty { whole.position = positions.first { !$0.isEmpty } ?? "" }
                    flat.append(whole)
                }
            default: flat.append(raw(t))
            }
        }
        let sided = media.count > 1 && !flat.isEmpty && flat.allSatisfy { side($0.position) != nil }
        var disc = 1, lastPlain: Int?
        var counts: [Int: Int] = [:]
        var out: [(disc: Int, number: Int, raw: Raw)] = []
        for t in flat {
            if let (d, _) = discAndTrack(t.position) {
                disc = d
            } else if sided, let s = side(t.position) {
                disc = min(s / 2 + 1, media.count)
            } else if let n = Int(t.position) {
                if let last = lastPlain, n <= last, disc < media.count { disc += 1 }
                lastPlain = n
            }
            counts[disc, default: 0] += 1
            out.append((disc, counts[disc]!, t))
        }
        return out.map { d, n, t in
            ReleaseTrack(recordingId: "", title: t.title, artist: t.artist, discNo: d, trackNo: n, trackTotal: counts[d] ?? 0,
                         durationSeconds: t.duration, numberLabel: TracklistEntry.position(t.position, number: n) ?? "",
                         mediaFormat: d <= media.count ? media[d - 1] : "")
        }
    }

    /// "B2" → 1 (the second side); nil unless the position is one letter and a number.
    static func side(_ position: String) -> Int? {
        let p = position.uppercased()
        guard let first = p.unicodeScalars.first, ("A"..."Z").contains(first),
              p.dropFirst().allSatisfy({ $0.isNumber }) else { return nil }
        return Int(first.value - UnicodeScalar("A").value)
    }

    /// "2-3", "CD2-03", "2.3" → (2, 3).
    static func discAndTrack(_ position: String) -> (Int, Int)? {
        var p = Substring(position.uppercased())
        for prefix in ["CD", "LP", "DVD", "DISC"] where p.hasPrefix(prefix) { p = p.dropFirst(prefix.count); break }
        let parts = p.split(whereSeparator: { $0 == "-" || $0 == "." })
        guard parts.count == 2, let d = Int(parts[0]), let n = Int(parts[1]), (1...99).contains(d), n > 0 else { return nil }
        return (d, n)
    }

    /// "3:32" or "1:02:03" in seconds.
    static func duration(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let seconds = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? Double(seconds) : nil
    }

    // MARK: Fields

    /// Discogs' formats as MusicBrainz names them, one per disc. A box is the discs in it.
    static func media(_ formats: [[String: Any]]) -> [String] {
        var out: [String] = []
        for f in formats {
            let name = (f["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let descriptions = f["descriptions"] as? [String] ?? []
            let qty = Int(f["qty"] as? String ?? "") ?? (f["qty"] as? Int) ?? 1
            let mb: String
            switch name.lowercased() {
            case "box set", "all media", "": continue
            case "vinyl": mb = descriptions.first { ["12\"", "10\"", "7\""].contains($0) }.map { "\($0) Vinyl" } ?? "Vinyl"
            case "cdr": mb = "CD-R"
            case "file": mb = "Digital Media"
            default: mb = name
            }
            out += Array(repeating: mb, count: min(max(qty, 1), 99))
        }
        return Array(out.prefix(99))
    }

    /// The format's descriptions and free text, without the size already in the media: "LP, Album, Reissue, 180 gram".
    static func notes(_ formats: [[String: Any]]) -> String {
        var parts: [String] = []
        for f in formats {
            parts += (f["descriptions"] as? [String] ?? []).filter { !["12\"", "10\"", "7\""].contains($0) }
            if let text = f["text"] as? String { parts.append(text) }
        }
        return CreditDerivation.dedupe(parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).joined(separator: ", ")
    }

    /// The first value that reads as a UPC/EAN (8 to 14 digits, spaces and dashes allowed): search results list the
    /// runout matrix and other codes with it.
    static func barcode(_ values: [String]) -> String {
        for v in values where v.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            let digits = v.filter { ("0"..."9").contains($0) }
            if (8...14).contains(digits.count) { return digits }
        }
        return ""
    }

    /// "Pink Floyd", "Simon & Garfunkel", "Miles Davis Quintet, The": the credited names (Discogs' "name variation"
    /// when there is one) with their joins.
    static func credit(_ raw: Any?) -> String {
        var out = ""
        for a in raw as? [[String: Any]] ?? [] {
            let anv = (a["anv"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            out += anv.isEmpty ? clean(a["name"] as? String ?? "") : anv
            let join = (a["join"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !join.isEmpty { out += join == "," ? ", " : " \(join) " }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// An artist's or label's name without the number Discogs adds to tell those of the same name apart
    /// ("Nirvana (2)") and the asterisk of a name variation. Titles are left as they are ("Live (1999)").
    static func clean(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("*") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        return s.replacingOccurrences(of: #" \([0-9]+\)$"#, with: "", options: .regularExpression)
    }

    /// "1959-00-00" → "1959", "1987-07-00" → "1987-07".
    static func date(_ s: String) -> String {
        var parts = s.trimmingCharacters(in: .whitespaces).split(separator: "-").map(String.init)
        while let last = parts.last, last.allSatisfy({ $0 == "0" }) { parts.removeLast() }
        guard let year = parts.first, year.count == 4, Int(year) != nil else { return "" }
        return parts.prefix(3).joined(separator: "-")
    }

    static func image(_ raw: Any?) -> URL? {
        guard let s = raw as? String, !s.isEmpty, let url = URL(string: s), DiscogsLink.isImageURL(url) else { return nil }
        return url
    }
}

/// Discogs' database API without a key: at most 25 requests a minute, so requests are spaced to stay under it
/// (`window` of them in any `period`), and a 429 says to try again later.
public actor DiscogsClient {
    public static let baseURL = "https://api.discogs.com"
    private let session: URLSession
    private let window: Int
    private let period: TimeInterval
    private var recent: [Date] = []

    public init(session: URLSession = .shared, window: Int = 20, period: TimeInterval = 60) {
        self.session = session
        self.window = window
        self.period = period
    }

    /// Editions matching what the user typed, at most 50: a pasted release link, a barcode lookup, else the words,
    /// then the text as a catalog number.
    public func searchEditions(_ query: CollectionReleaseQuery) async throws -> [CollectionEdition] {
        if let id = DiscogsLink.releaseID(in: query.text) { return [try await release(id: id).edition] }
        if let barcode = query.barcode {
            return CollectionEditionParser.preferring(query.medium, try await search(["barcode": barcode], medium: nil))
        }
        let format: [String: String] = switch query.medium {
        case .cd: ["format": "CD"]
        case .vinyl: ["format": "Vinyl"]
        case .download, .other: [:]
        }
        let text = query.text.trimmingCharacters(in: .whitespaces)
        var found = try await search(format.merging(["q": text]) { a, _ in a }, medium: query.medium)
        if found.isEmpty, text.contains(where: \.isNumber) {
            found = try await search(format.merging(["catno": text]) { a, _ in a }, medium: query.medium)
        }
        return found
    }

    public func release(id: Int) async throws -> DiscogsRelease {
        guard DiscogsLink.isValid(id), let url = URL(string: "\(Self.baseURL)/releases/\(id)") else { throw DiscogsError.badResponse }
        return try DiscogsParser.parseRelease(try await get(url))
    }

    /// A release's image (not counted against the API's limit: it's another host).
    public func image(_ url: URL) async throws -> Data? {
        guard DiscogsLink.isImageURL(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty ? data : nil
    }

    private func search(_ params: [String: String], medium: CollectionMedium?) async throws -> [CollectionEdition] {
        guard var c = URLComponents(string: "\(Self.baseURL)/database/search") else { return [] }
        c.queryItems = [.init(name: "type", value: "release"), .init(name: "per_page", value: "50")]
            + params.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = c.url else { return [] }
        return try DiscogsParser.parseSearch(try await get(url), medium: medium)
    }

    private func throttle() async {
        while true {
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0) >= period }
            guard recent.count >= window, let oldest = recent.first else { break }
            let wait = period - now.timeIntervalSince(oldest)
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.05) * 1_000_000_000))
        }
        recent.append(Date())
    }

    private func get(_ url: URL) async throws -> Data {
        await throttle()
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.discogs.v2.discogs+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 429: throw DiscogsError.busy
        default: throw DiscogsError.http(code)
        }
    }
}
