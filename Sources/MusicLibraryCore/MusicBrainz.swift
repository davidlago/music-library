import Foundation

public enum NetworkError: Error, LocalizedError {
    case http(Int, String)
    case badResponse(String)
    public var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "HTTP \(code) from \(url)"
        case .badResponse(let m): return "Unexpected response: \(m)"
        }
    }
}

public struct DiscRelease: Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String
    public var country: String
    public var label: String
    public var catalogNumber: String
    public var barcode: String
    public var format: String
    public var mediumPosition: Int
    public var mediumCount: Int
    public var releaseGroupId: String?
    public var exactMatch: Bool

    public var year: Int? { date.count >= 4 ? Int(date.prefix(4)) : nil }
}

public enum MusicBrainzParser {
    static func parseDiscReleases(_ data: Data, discID: String?, trackCount: Int) throws -> [DiscRelease] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz disc lookup is not a JSON object")
        }
        var out: [DiscRelease] = []
        for rel in root["releases"] as? [[String: Any]] ?? [] {
            guard let id = rel["id"] as? String else { continue }
            let media = rel["media"] as? [[String: Any]] ?? []
            var chosen: [String: Any]?
            var exact = false
            if let discID {
                chosen = media.first { m in (m["discs"] as? [[String: Any]] ?? []).contains { ($0["id"] as? String) == discID } }
                exact = chosen != nil
            }
            if chosen == nil {
                chosen = media.first { ($0["track-count"] as? Int) == trackCount }
            }
            guard let medium = chosen else { continue }
            let labels = rel["label-info"] as? [[String: Any]] ?? []
            let group = rel["release-group"] as? [String: Any]
            out.append(DiscRelease(
                id: id, title: rel["title"] as? String ?? "", artist: creditString(rel["artist-credit"]),
                date: rel["date"] as? String ?? "", country: rel["country"] as? String ?? "",
                label: joinedUnique(labels.compactMap { ($0["label"] as? [String: Any])?["name"] as? String }),
                catalogNumber: joinedUnique(labels.compactMap { $0["catalog-number"] as? String }),
                barcode: rel["barcode"] as? String ?? "", format: medium["format"] as? String ?? "",
                mediumPosition: medium["position"] as? Int ?? 1, mediumCount: media.count,
                releaseGroupId: group?["id"] as? String, exactMatch: exact))
        }
        return out.enumerated().sorted { a, b in
            if a.element.exactMatch != b.element.exactMatch { return a.element.exactMatch }
            let da = a.element.date, db = b.element.date
            if da != db {
                if da.isEmpty { return false }
                if db.isEmpty { return true }
                return da < db
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func parseDiscLookup(_ data: Data, discID: String, trackCount: Int) throws -> [DiscRelease] {
        try parseDiscReleases(data, discID: discID, trackCount: trackCount)
    }

    public static func parseReleaseSearch(_ data: Data, trackCount: Int) throws -> [DiscRelease] {
        try parseDiscReleases(data, discID: nil, trackCount: trackCount)
    }

    static func creditString(_ credit: Any?) -> String {
        guard let list = credit as? [[String: Any]] else { return "" }
        return list.map { ($0["name"] as? String ?? (($0["artist"] as? [String: Any])?["name"] as? String) ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
    }

    static func year(_ date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    static func rank(_ c: MatchCandidate, albumHint: String) -> Int {
        var r = 0
        let hint = TextNormalizer.normalize(albumHint)
        if !hint.isEmpty, TextNormalizer.normalize(c.album) == hint { r += 4 }
        if c.releaseStatus == "Official" { r += 2 }
        if c.releaseType == "Album" { r += 1 }
        if !c.secondaryTypes.isEmpty { r -= 2 }
        return r
    }

    public static func parseSearch(_ data: Data, albumHint: String = "", limit: Int = 25) throws -> [MatchCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkError.badResponse("MusicBrainz search is not a JSON object")
        }
        var out: [MatchCandidate] = []
        for rec in root["recordings"] as? [[String: Any]] ?? [] {
            guard let rid = rec["id"] as? String else { continue }
            let title = rec["title"] as? String ?? ""
            let artist = creditString(rec["artist-credit"])
            let score = (rec["score"] as? Int) ?? Int(rec["score"] as? String ?? "") ?? 0
            let duration = (rec["length"] as? Double).map { $0 / 1000 }
            let releases = rec["releases"] as? [[String: Any]] ?? []
            if releases.isEmpty {
                out.append(MatchCandidate(recordingId: rid, releaseId: "", title: title, artist: artist, album: "",
                                          durationSeconds: duration, score: score))
                continue
            }
            for rel in releases {
                guard let relId = rel["id"] as? String else { continue }
                let group = rel["release-group"] as? [String: Any]
                let date = rel["date"] as? String
                out.append(MatchCandidate(
                    recordingId: rid, releaseId: relId, releaseGroupId: group?["id"] as? String,
                    title: title, artist: artist, album: rel["title"] as? String ?? "",
                    date: date, year: year(date), durationSeconds: duration, score: score,
                    releaseType: group?["primary-type"] as? String, releaseStatus: rel["status"] as? String,
                    secondaryTypes: group?["secondary-types"] as? [String] ?? []))
            }
        }
        let sorted = out.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            let ra = rank(a.element, albumHint: albumHint), rb = rank(b.element, albumHint: albumHint)
            if ra != rb { return ra > rb }
            let da = a.element.date ?? "", db = b.element.date ?? ""
            if da != db {
                if da.isEmpty { return false }
                if db.isEmpty { return true }
                return da < db
            }
            return a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(limit))
    }

    static func creditSort(_ credit: Any?) -> String {
        guard let list = credit as? [[String: Any]] else { return "" }
        return list.map { (($0["artist"] as? [String: Any])?["sort-name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }.joined()
    }

    static func creditArtistIds(_ credit: Any?) -> [String] {
        guard let list = credit as? [[String: Any]] else { return [] }
        return list.compactMap { ($0["artist"] as? [String: Any])?["id"] as? String }
    }

    static func genres(_ raw: Any?) -> [Genre] {
        (raw as? [[String: Any]] ?? []).compactMap { g in
            guard let name = g["name"] as? String else { return nil }
            return Genre(name: name, count: g["count"] as? Int ?? 0)
        }
    }

    static func artistCredits(_ relations: Any?, scope: Credit.Scope) -> [Credit] {
        (relations as? [[String: Any]] ?? []).compactMap { rel in
            guard (rel["target-type"] as? String) == "artist", let type = rel["type"] as? String,
                  let artist = rel["artist"] as? [String: Any], let name = artist["name"] as? String else { return nil }
            return Credit(role: type, name: name, artistId: artist["id"] as? String,
                          attributes: rel["attributes"] as? [String] ?? [], scope: scope)
        }
    }

    static func joinedUnique(_ xs: [String]) -> String { CreditDerivation.dedupe(xs).joined(separator: "; ") }

    public static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String else {
            throw NetworkError.badResponse("MusicBrainz release is malformed")
        }
        let media = root["media"] as? [[String: Any]] ?? []
        var tracks: [ReleaseTrack] = []
        for (mi, medium) in media.enumerated() {
            let discNo = medium["position"] as? Int ?? (mi + 1)
            let total = medium["track-count"] as? Int ?? (medium["tracks"] as? [[String: Any]])?.count ?? 0
            for t in medium["tracks"] as? [[String: Any]] ?? [] {
                let rec = t["recording"] as? [String: Any]
                guard let rid = rec?["id"] as? String else { continue }
                let length = (t["length"] as? Double) ?? (rec?["length"] as? Double)
                let credit = t["artist-credit"] ?? rec?["artist-credit"]
                var credits = artistCredits(rec?["relations"], scope: .recording)
                var workTitle = "", iswcs: [String] = [], workIds: [String] = []
                for rel in rec?["relations"] as? [[String: Any]] ?? [] {
                    guard (rel["target-type"] as? String) == "work", let work = rel["work"] as? [String: Any] else { continue }
                    if workTitle.isEmpty { workTitle = work["title"] as? String ?? "" }
                    if let wid = work["id"] as? String { workIds.append(wid) }
                    iswcs += work["iswcs"] as? [String] ?? []
                    credits += artistCredits(work["relations"], scope: .work)
                }
                tracks.append(ReleaseTrack(
                    recordingId: rid,
                    title: t["title"] as? String ?? rec?["title"] as? String ?? "",
                    artist: creditString(credit),
                    discNo: discNo, trackNo: t["position"] as? Int ?? 0, trackTotal: total,
                    durationSeconds: length.map { $0 / 1000 },
                    releaseTrackId: t["id"] as? String ?? "", numberLabel: t["number"] as? String ?? "",
                    isrcs: rec?["isrcs"] as? [String] ?? [], credits: credits, workTitle: workTitle,
                    iswcs: CreditDerivation.dedupe(iswcs), workIds: CreditDerivation.dedupe(workIds),
                    artistSort: creditSort(credit), artistIds: CreditDerivation.dedupe(creditArtistIds(credit)),
                    genres: genres(rec?["genres"]), mediaFormat: medium["format"] as? String ?? "",
                    discSubtitle: medium["title"] as? String ?? ""))
            }
        }
        let date = root["date"] as? String
        let group = root["release-group"] as? [String: Any]
        var info = ReleaseInfo(
            id: id, releaseGroupId: group?["id"] as? String, album: root["title"] as? String ?? "",
            albumArtist: creditString(root["artist-credit"]), date: date, year: year(date),
            originalYear: year(group?["first-release-date"] as? String),
            discTotal: max(media.count, 1), tracks: tracks)
        info.originalDate = group?["first-release-date"] as? String ?? ""
        info.albumArtistSort = creditSort(root["artist-credit"])
        info.albumArtistIds = CreditDerivation.dedupe(creditArtistIds(root["artist-credit"]))
        let labelInfo = root["label-info"] as? [[String: Any]] ?? []
        info.label = joinedUnique(labelInfo.compactMap { ($0["label"] as? [String: Any])?["name"] as? String })
        info.catalogNumber = joinedUnique(labelInfo.compactMap { $0["catalog-number"] as? String })
        info.barcode = root["barcode"] as? String ?? ""
        info.asin = root["asin"] as? String ?? ""
        info.country = root["country"] as? String ?? ""
        info.status = root["status"] as? String ?? ""
        info.packaging = root["packaging"] as? String ?? ""
        let text = root["text-representation"] as? [String: Any]
        info.language = text?["language"] as? String ?? ""
        info.script = text?["script"] as? String ?? ""
        info.releaseType = group?["primary-type"] as? String ?? ""
        info.secondaryTypes = group?["secondary-types"] as? [String] ?? []
        info.credits = artistCredits(root["relations"], scope: .release)
        info.releaseGenres = genres(root["genres"])
        info.groupGenres = genres(group?["genres"])
        return info
    }
}

public actor MusicBrainzClient {
    public static let baseURL = "https://musicbrainz.org/ws/2"
    private let session: URLSession
    private var contact: String
    private var nextSlot = Date.distantPast
    private let minInterval: TimeInterval

    public init(contact: String = "", session: URLSession = .shared, minInterval: TimeInterval = 1.1) {
        self.contact = contact
        self.session = session
        self.minInterval = minInterval
    }

    public func setContact(_ c: String) { contact = c }

    nonisolated static func luceneEscape(_ s: String) -> String {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        var out = ""
        for ch in s {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    nonisolated static func searchQuery(title: String, artist: String, album: String) -> String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("recording:\"\(luceneEscape(title))\"") }
        if !artist.isEmpty { parts.append("artist:\"\(luceneEscape(artist))\"") }
        if !album.isEmpty { parts.append("release:\"\(luceneEscape(album))\"") }
        return parts.joined(separator: " AND ")
    }

    private func throttle() async {
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(minInterval)
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// Throttled GET shared by the lookups in other files.
    func fetchData(_ url: URL) async throws -> Data { try await fetch(url) }

    private func fetch(_ url: URL) async throws -> Data {
        guard let data = try await fetch(url, allowNotFound: false) else { throw NetworkError.http(404, url.absoluteString) }
        return data
    }

    private func fetch(_ url: URL, allowNotFound: Bool) async throws -> Data? {
        var request = URLRequest(url: url)
        let contactInfo = contact.isEmpty ? AppInfo.homepage : "\(contact); \(AppInfo.homepage)"
        request.setValue("MusicLibrary/\(AppInfo.version) ( \(contactInfo) )", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<2 {
            await throttle()
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if code == 404 && allowNotFound { return nil }
            if code == 503 && attempt == 0 { continue }
            throw NetworkError.http(code, url.absoluteString)
        }
        throw NetworkError.http(503, url.absoluteString)
    }

    public func searchRecordings(title: String, artist: String, album: String = "") async throws -> [MatchCandidate] {
        let query = Self.searchQuery(title: title, artist: artist, album: album)
        guard !query.isEmpty else { return [] }
        var c = URLComponents(string: "\(Self.baseURL)/recording")!
        c.queryItems = [.init(name: "query", value: query), .init(name: "fmt", value: "json"), .init(name: "limit", value: "15")]
        return try MusicBrainzParser.parseSearch(try await fetch(c.url!), albumHint: album)
    }

    public func lookupDisc(_ toc: CDTOC) async throws -> [DiscRelease] {
        var c = URLComponents(string: "\(Self.baseURL)/discid/\(toc.discID)")!
        c.percentEncodedQuery = "toc=\(toc.tocQueryValue)&cdstubs=no&inc=artist-credits+release-groups+labels&fmt=json"
        guard let data = try await fetch(c.url!, allowNotFound: true) else { return [] }
        return try MusicBrainzParser.parseDiscLookup(data, discID: toc.discID, trackCount: toc.audioTracks.count)
    }

    public func searchReleases(album: String, artist: String, trackCount: Int) async throws -> [DiscRelease] {
        var parts: [String] = []
        if !album.isEmpty { parts.append("release:\"\(Self.luceneEscape(album))\"") }
        if !artist.isEmpty { parts.append("artist:\"\(Self.luceneEscape(artist))\"") }
        guard !parts.isEmpty else { return [] }
        parts.append("tracksmedium:\(trackCount)")
        var c = URLComponents(string: "\(Self.baseURL)/release")!
        c.queryItems = [.init(name: "query", value: parts.joined(separator: " AND ")), .init(name: "fmt", value: "json"), .init(name: "limit", value: "25")]
        return try MusicBrainzParser.parseReleaseSearch(try await fetch(c.url!), trackCount: trackCount)
    }

    public func fetchRelease(id: String) async throws -> ReleaseInfo {
        var c = URLComponents(string: "\(Self.baseURL)/release/\(id)")!
        // URLComponents would percent-encode '+', which MusicBrainz reads as a space.
        c.percentEncodedQuery = "inc=recordings+artist-credits+release-groups+labels+isrcs+genres+recording-level-rels+work-rels+work-level-rels+artist-rels&fmt=json"
        return try MusicBrainzParser.parseRelease(try await fetch(c.url!))
    }
}

public struct CoverArtClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private func get(_ urlString: String) async throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, !data.isEmpty { return data }
        if code == 404 { return nil }
        if code == 200 { return nil }
        throw NetworkError.http(code, urlString)
    }

    /// `size` is 250, 500 or 1200.
    public func fetchFront(releaseId: String, releaseGroupId: String?, size: Int = 500) async throws -> Data? {
        if !releaseId.isEmpty,
           let d = try await get("https://coverartarchive.org/release/\(releaseId)/front-\(size)") { return d }
        if let rg = releaseGroupId, !rg.isEmpty {
            return try await get("https://coverartarchive.org/release-group/\(rg)/front-\(size)")
        }
        return nil
    }

    public func thumbnail(for c: MatchCandidate) async -> Data? {
        try? await fetchFront(releaseId: c.releaseId, releaseGroupId: c.releaseGroupId, size: 250)
    }
}
