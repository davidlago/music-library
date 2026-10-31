import Foundation

// Sending the physical collection to the user's collection on Discogs, one way: the Mac is where the collection is
// edited, and Discogs gets a copy of it. Each CD and record is one instance of its Discogs release there (copies of
// the same edition are instances of the same release). The release comes from the item's own Discogs edition, else
// its MusicBrainz release's Discogs link, else a barcode search that leaves exactly one edition. Each sync is
// planned first (`DiscogsSyncPlan`) and shown: additions are picked, removals listed but left unpicked, so nothing
// is taken off Discogs unless the user ticks it. Which instance is which item is kept in `discogs_sync`, a Mac-only
// table (like `rip_checks`), with the release each item was matched to.
//
// Discogs' API needs the user's personal access token (Settings ▸ Developers on discogs.com) for their collection;
// it's kept in the keychain (`DiscogsToken.keychainAccount`). Authenticated requests may go at 60 a minute.

/// A Discogs personal access token, sent in the Authorization header.
public enum DiscogsToken {
    public static let keychainAccount = "discogsToken"

    /// Trimmed; nil unless it's letters and digits only (Discogs' tokens are 40 of them), so nothing else can go
    /// into a header.
    public static func cleaned(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...100).contains(t.count), t.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return t
    }
}

/// The account a token belongs to (`/oauth/identity`).
public struct DiscogsIdentity: Hashable, Codable, Sendable {
    public var id: Int
    public var username: String

    public init(id: Int, username: String) { self.id = id; self.username = username }

    /// Discogs usernames are letters, digits, `_`, `.` and `-`; anything else is refused before it goes in a path.
    public static func isValidUsername(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
        } && name != "." && name != ".."
    }

    public var profileURL: URL? { URL(string: "https://www.discogs.com/user/\(username)/collection") }
}

/// A folder of the user's collection. Folder 0 ("All") is every folder's releases and can't be added to; folder 1
/// ("Uncategorized") is where Discogs puts releases by default.
public struct DiscogsFolder: Hashable, Codable, Sendable, Identifiable {
    public static let all = 0, uncategorized = 1

    public var id: Int
    public var name: String
    public var count: Int

    public init(id: Int, name: String, count: Int) { self.id = id; self.name = name; self.count = count }
}

/// One copy in the user's Discogs collection.
public struct DiscogsInstance: Hashable, Sendable, Identifiable {
    public var instanceID: Int
    public var releaseID: Int
    public var folderID: Int
    public var title: String
    public var artist: String
    /// "CD", "2×12\" Vinyl".
    public var formatDetail: String
    public var medium: CollectionMedium?
    public var year: Int?
    public var catalogNumber: String
    public var dateAdded: Date?

    public var id: Int { instanceID }
    public var webURL: URL? { DiscogsLink.releaseURL(releaseID) }

    public init(instanceID: Int, releaseID: Int, folderID: Int = DiscogsFolder.uncategorized, title: String = "", artist: String = "",
                formatDetail: String = "", medium: CollectionMedium? = nil, year: Int? = nil, catalogNumber: String = "",
                dateAdded: Date? = nil) {
        self.instanceID = instanceID; self.releaseID = releaseID; self.folderID = folderID; self.title = title
        self.artist = artist; self.formatDetail = formatDetail; self.medium = medium; self.year = year
        self.catalogNumber = catalogNumber; self.dateAdded = dateAdded
    }
}

public enum DiscogsCollectionParser {
    public static func identity(_ data: Data) throws -> DiscogsIdentity {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? Int,
              let name = o["username"] as? String, DiscogsIdentity.isValidUsername(name) else { throw DiscogsError.badResponse }
        return DiscogsIdentity(id: id, username: name)
    }

    public static func folders(_ data: Data) throws -> [DiscogsFolder] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["folders"] as? [[String: Any]] else {
            throw DiscogsError.badResponse
        }
        return list.compactMap { f in
            guard let id = f["id"] as? Int, id >= 0 else { return nil }
            let name = DiscogsParser.trimmed(f["name"] as? String ?? "")
            return DiscogsFolder(id: id, name: name.isEmpty ? "Folder \(id)" : String(name.prefix(200)), count: max(0, f["count"] as? Int ?? 0))
        }
    }

    /// One page of a folder's releases, and how many pages there are.
    public static func page(_ data: Data) throws -> (instances: [DiscogsInstance], pages: Int) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["releases"] as? [[String: Any]] else {
            throw DiscogsError.badResponse
        }
        let pages = ((o["pagination"] as? [String: Any])?["pages"] as? Int) ?? 1
        let dates = ISO8601DateFormatter()
        let instances = list.compactMap { r -> DiscogsInstance? in
            guard let release = r["id"] as? Int, DiscogsLink.isValid(release), let instance = r["instance_id"] as? Int, instance > 0 else {
                return nil
            }
            let info = r["basic_information"] as? [String: Any] ?? [:]
            let media = DiscogsParser.media(info["formats"] as? [[String: Any]] ?? [])
            let labels = info["labels"] as? [[String: Any]] ?? []
            let catno = labels.lazy.compactMap { $0["catno"] as? String }.map(DiscogsParser.trimmed).first { !$0.isEmpty && $0.lowercased() != "none" }
            return DiscogsInstance(
                instanceID: instance, releaseID: release, folderID: max(0, r["folder_id"] as? Int ?? DiscogsFolder.uncategorized),
                title: DiscogsParser.trimmed(info["title"] as? String ?? ""), artist: DiscogsParser.credit(info["artists"]),
                formatDetail: media.isEmpty ? "" : CDEditionParser.formatSummary(media), medium: CollectionMedium(musicBrainzFormats: media),
                year: (info["year"] as? Int).flatMap { (1000...9999).contains($0) ? $0 : nil }, catalogNumber: catno ?? "",
                dateAdded: (r["date_added"] as? String).flatMap(dates.date(from:)))
        }
        return (instances, max(1, pages))
    }

    /// One page of a master's versions (its releases), as candidates, and how many pages there are.
    public static func versions(_ data: Data) throws -> (candidates: [DiscogsCandidate], pages: Int) {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["versions"] as? [[String: Any]] else {
            throw DiscogsError.badResponse
        }
        let pages = ((o["pagination"] as? [String: Any])?["pages"] as? Int) ?? 1
        let candidates = list.compactMap { v -> DiscogsCandidate? in
            guard let id = v["id"] as? Int, DiscogsLink.isValid(id) else { return nil }
            let formats = (v["major_formats"] as? [String] ?? []).map { $0.lowercased() == "vinyl" ? "Vinyl" : $0 }
            let catnos = (v["catno"] as? String ?? "").split(separator: ",").map { DiscogsParser.trimmed(String($0)) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
            return DiscogsCandidate(
                releaseID: id, title: DiscogsParser.trimmed(v["title"] as? String ?? ""), medium: CollectionMedium(musicBrainzFormats: formats),
                catalogNumbers: catnos, country: DiscogsParser.trimmed(v["country"] as? String ?? ""),
                year: Int((v["released"] as? String ?? "").prefix(4)).flatMap { (1000...9999).contains($0) ? $0 : nil },
                notes: v["format"] as? String ?? "")
        }
        return (candidates, max(1, pages))
    }

    /// The instance a release was added as.
    public static func addedInstance(_ data: Data) throws -> Int {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["instance_id"] as? Int, id > 0 else {
            throw DiscogsError.badResponse
        }
        return id
    }
}

/// The user's Discogs account and collection, with their personal access token. Requests are spaced to stay under
/// Discogs' 60 a minute (`window` in any `period`).
public actor DiscogsCollectionClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Releases per page of the collection (Discogs' most).
    static let perPage = 100
    /// At most this many pages are read (100,000 releases).
    static let maxPages = 1000

    private let token: String?
    private let transport: Transport
    private let window: Int
    private let period: TimeInterval
    private var recent: [Date] = []

    /// Pages of a master's versions read at most (300 releases).
    static let maxVersionPages = 3

    /// `token` must be one `DiscogsToken.cleaned` accepts. Without one only the database can be read, at 25 requests a
    /// minute (pass a smaller `window`).
    public init(token: String?, transport: Transport? = nil, window: Int = 50, period: TimeInterval = 60) {
        self.token = token
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        self.window = window
        self.period = period
    }

    public func identity() async throws -> DiscogsIdentity {
        try DiscogsCollectionParser.identity(try await send("GET", path: "/oauth/identity"))
    }

    public func folders(username: String) async throws -> [DiscogsFolder] {
        try DiscogsCollectionParser.folders(try await send("GET", path: "\(try Self.user(username))/collection/folders"))
    }

    /// Every release in the collection (folder 0, oldest first), page by page; `progress` gets pages read and pages.
    public func collection(username: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [DiscogsInstance] {
        let base = "\(try Self.user(username))/collection/folders/\(DiscogsFolder.all)/releases"
        var all: [DiscogsInstance] = []
        var page = 1, pages = 1
        repeat {
            try Task.checkCancellation()
            let data = try await send("GET", path: base, query: [
                "page": String(page), "per_page": String(Self.perPage), "sort": "added", "sort_order": "asc",
            ])
            let read = try DiscogsCollectionParser.page(data)
            all += read.instances
            pages = min(read.pages, Self.maxPages)
            progress?(page, pages)
            page += 1
        } while page <= pages
        // A release added while the pages were read can show on two of them.
        var seen = Set<Int>()
        return all.filter { seen.insert($0.instanceID).inserted }
    }

    /// Adds a copy of the release to a folder (not 0); returns its instance.
    public func add(releaseID: Int, folderID: Int, username: String) async throws -> Int {
        guard DiscogsLink.isValid(releaseID), folderID > 0 else { throw DiscogsError.badResponse }
        let path = "\(try Self.user(username))/collection/folders/\(folderID)/releases/\(releaseID)"
        return try DiscogsCollectionParser.addedInstance(try await send("POST", path: path))
    }

    /// Removes one copy. One that's already gone counts as removed.
    public func remove(_ instance: DiscogsInstance, username: String) async throws {
        guard DiscogsLink.isValid(instance.releaseID), instance.instanceID > 0 else { throw DiscogsError.badResponse }
        // The instance's own folder: "All" can't be removed from.
        let folder = instance.folderID > 0 ? instance.folderID : DiscogsFolder.uncategorized
        let path = "\(try Self.user(username))/collection/folders/\(folder)/releases/\(instance.releaseID)/instances/\(instance.instanceID)"
        do {
            _ = try await send("DELETE", path: path)
        } catch DiscogsError.http(404) {}
    }

    /// Releases with the barcode, as editions (`DiscogsParser.parseSearch`), of any medium: the code says which release.
    public func searchBarcode(_ barcode: String, medium: CollectionMedium) async throws -> [CollectionEdition] {
        guard (6...20).contains(barcode.count), barcode.allSatisfy({ ("0"..."9").contains($0) }) else { return [] }
        let data = try await send("GET", path: "/database/search", query: ["type": "release", "barcode": barcode, "per_page": "50"])
        return try DiscogsParser.parseSearch(data, medium: medium)
    }

    /// A database search (`catno`, `artist`, `release_title`…) for releases of the medium.
    public func search(_ params: [String: String], medium: CollectionMedium) async throws -> [CollectionEdition] {
        var query = params.merging(["type": "release", "per_page": "50"]) { a, _ in a }
        if let format = Self.format(medium) { query["format"] = format }
        return try DiscogsParser.parseSearch(try await send("GET", path: "/database/search", query: query), medium: medium)
    }

    /// A master's releases of the medium, oldest first.
    public func versions(masterID: Int, medium: CollectionMedium) async throws -> [DiscogsCandidate] {
        guard DiscogsLink.isValid(masterID) else { return [] }
        var all: [DiscogsCandidate] = []
        var page = 1, pages = 1
        repeat {
            var query = ["page": String(page), "per_page": String(Self.perPage), "sort": "released", "sort_order": "asc"]
            if let format = Self.format(medium) { query["format"] = format }
            let read = try DiscogsCollectionParser.versions(try await send("GET", path: "/masters/\(masterID)/versions", query: query))
            all += read.candidates
            pages = min(read.pages, Self.maxVersionPages)
            page += 1
        } while page <= pages
        return all.filter { $0.medium == medium }
    }

    static func format(_ medium: CollectionMedium) -> String? {
        switch medium {
        case .cd: "CD"
        case .vinyl: "Vinyl"
        case .download, .other: nil
        }
    }

    static func user(_ username: String) throws -> String {
        guard DiscogsIdentity.isValidUsername(username) else { throw DiscogsError.badResponse }
        return "/users/\(username)"
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

    private func send(_ method: String, path: String, query: [String: String] = [:]) async throws -> Data {
        guard var c = URLComponents(string: DiscogsClient.baseURL + path) else { throw DiscogsError.badResponse }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw DiscogsError.badResponse }
        await throttle()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.discogs.v2.discogs+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        let (data, code) = try await transport(request)
        switch code {
        case 200, 201, 204: return data
        case 401, 403: throw DiscogsError.unauthorized
        case 429: throw DiscogsError.busy
        default: throw DiscogsError.http(code)
        }
    }
}

// MARK: Matching items to releases

/// How sure a match is.
public enum DiscogsMatchQuality: String, Hashable, Sendable {
    /// The item's own Discogs edition, its MusicBrainz release's Discogs link, or a release with its barcode and its
    /// catalog number.
    case exact
    /// A pressing with its barcode or catalog number (pressings often share them).
    case edition
    /// A pressing of the album picked by country and year: the edition may be another one.
    case closest
}

public struct DiscogsMatch: Hashable, Sendable {
    public var releaseID: Int
    public var quality: DiscogsMatchQuality

    public init(releaseID: Int, quality: DiscogsMatchQuality) { self.releaseID = releaseID; self.quality = quality }
}

/// What MusicBrainz says about a copy's release: often more than the item has (most items added from a library album
/// have no barcode or catalog number of their own), and its Discogs links.
public struct MusicBrainzEditionFacts: Hashable, Sendable {
    public var barcode: String?
    public var catalogNumbers: [String] = []
    /// ISO code: "CA", "GB", "XE".
    public var country: String?
    public var year: Int?
    public var releaseGroupID: String?
    /// The release's Discogs release or master, else its release group's master.
    public var links = CDShopLinks()

    public init() {}

    /// A release lookup with `inc=url-rels+labels+release-groups`.
    public static func parse(_ data: Data) throws -> MusicBrainzEditionFacts {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscogsError.badResponse }
        var facts = MusicBrainzEditionFacts()
        facts.links = try CDShopLinks.parse(data)
        if let code = o["barcode"] as? String, (6...20).contains(code.count), code.allSatisfy({ ("0"..."9").contains($0) }) {
            facts.barcode = code
        }
        facts.catalogNumbers = CreditDerivation.dedupe((o["label-info"] as? [[String: Any]] ?? []).compactMap {
            ($0["catalog-number"] as? String).map(DiscogsParser.trimmed)
        }.filter { !$0.isEmpty && $0.lowercased() != "[none]" })
        facts.country = (o["country"] as? String).flatMap { $0.count == 2 ? $0.uppercased() : nil }
        facts.year = (o["date"] as? String).flatMap { Int($0.prefix(4)) }.flatMap { (1000...9999).contains($0) ? $0 : nil }
        facts.releaseGroupID = MBID.validated((o["release-group"] as? [String: Any])?["id"] as? String)
        return facts
    }
}

extension MusicBrainzClient {
    /// The release's facts, with its release group's Discogs master when the release links to nothing on Discogs.
    public func editionFacts(releaseId: String, releaseGroupId: String?) async throws -> MusicBrainzEditionFacts {
        let url = try Self.lookupURL("release", id: releaseId, query: "inc=url-rels+labels+release-groups&fmt=json")
        var facts = try MusicBrainzEditionFacts.parse(try await fetchData(url))
        if facts.links.discogsRelease == nil, facts.links.discogsMaster == nil,
           let group = MBID.validated(releaseGroupId) ?? facts.releaseGroupID {
            let links = try CDShopLinks.parse(try await fetchData(Self.lookupURL("release-group", id: group, query: "inc=url-rels&fmt=json")))
            facts.links.discogsMaster = links.discogsMaster
        }
        return facts
    }
}

/// What's known about a copy's edition: the item's own details, filled in from its MusicBrainz release.
public struct DiscogsEditionFacts: Hashable, Sendable {
    public var medium: CollectionMedium
    public var album: String
    public var artist: String
    public var barcode: String?
    public var catalogNumbers: [String]
    /// An ISO code ("CA") or a Discogs name ("Canada").
    public var country: String?
    public var year: Int?
    public var discogsRelease: Int?
    public var discogsMaster: Int?

    public init(item: CollectionItem) {
        medium = item.medium
        album = item.album
        artist = item.artist
        barcode = item.barcode
        catalogNumbers = (item.catalogNumber ?? "").split(separator: ",").map { DiscogsParser.trimmed(String($0)) }.filter { !$0.isEmpty }
        country = item.country
        year = item.year
        discogsRelease = item.discogsReleaseID
    }

    /// Adds what the item doesn't say. The release's date is the edition's (the item's year may be the album's).
    public mutating func add(_ mb: MusicBrainzEditionFacts) {
        if barcode == nil { barcode = mb.barcode }
        catalogNumbers = CreditDerivation.dedupe(catalogNumbers + mb.catalogNumbers)
        if country == nil { country = mb.country }
        if let y = mb.year { year = y }
        discogsRelease = discogsRelease ?? mb.links.discogsRelease
        discogsMaster = mb.links.discogsMaster
    }
}

/// A Discogs release that could be the copy: from a database search or a master's versions.
public struct DiscogsCandidate: Hashable, Sendable {
    public var releaseID: Int
    public var title: String
    public var medium: CollectionMedium?
    public var catalogNumbers: [String]
    /// Discogs' name: "US", "UK", "Canada", "Europe".
    public var country: String
    public var year: Int?
    public var barcodes: [String]
    /// "Album, Reissue".
    public var notes: String

    public init(releaseID: Int, title: String = "", medium: CollectionMedium?, catalogNumbers: [String] = [], country: String = "",
                year: Int? = nil, barcodes: [String] = [], notes: String = "") {
        self.releaseID = releaseID; self.title = title; self.medium = medium; self.catalogNumbers = catalogNumbers
        self.country = country; self.year = year; self.barcodes = barcodes; self.notes = notes
    }

    /// A search result; nil without a release id.
    public init?(edition e: CollectionEdition) {
        guard let id = e.discogsReleaseID else { return nil }
        self.init(releaseID: id, title: e.title, medium: e.medium,
                  catalogNumbers: e.catalogNumber.split(separator: ",").map { DiscogsParser.trimmed(String($0)) }.filter { !$0.isEmpty },
                  country: e.country, year: Int(e.date.prefix(4)).flatMap { (1000...9999).contains($0) ? $0 : nil },
                  barcodes: e.barcode.isEmpty ? [] : [e.barcode], notes: e.formatNotes)
    }
}

/// Which Discogs release a CD or record is.
public enum DiscogsReleaseMatcher {
    /// Items with no release found are looked up again after this long (Discogs and MusicBrainz grow).
    public static let retryAfter: TimeInterval = 30 * 24 * 3600
    /// Bumped when matching finds more: items an older matcher found nothing for are looked up again.
    public static let version = 2

    /// The items sent to Discogs: stored CDs and records.
    public static func isSynced(_ item: CollectionItem) -> Bool {
        item.origin == .stored && (item.medium == .cd || item.medium == .vinyl)
    }

    /// What a match is made from, so it's made again when the item's edition changes.
    public static func basis(of item: CollectionItem) -> String {
        [item.medium.rawValue, item.releaseID ?? "", item.barcode ?? "", item.catalogNumber ?? "", item.country ?? ""].joined(separator: "|")
    }

    /// The release the item is, when it's known without asking: its own Discogs edition, else a match saved for
    /// its current edition. `.none` means a lookup is due.
    public enum Known: Equatable, Sendable { case release(Int, DiscogsMatchQuality), noMatch, none }

    public static func known(_ item: CollectionItem, row: DiscogsSyncRow?, now: Date = Date()) -> Known {
        if let id = item.discogsReleaseID { return .release(id, .exact) }
        guard let row, row.basis == basis(of: item) else { return .none }
        // The first matcher only took a release link or a barcode with one pressing: exact.
        if let id = row.releaseID { return .release(id, row.quality ?? .exact) }
        return row.matcher >= version && now.timeIntervalSince(row.checkedAt) < retryAfter ? .noMatch : .none
    }

    /// Whether there's anything to look the item up by.
    public static func canLookUp(_ item: CollectionItem) -> Bool {
        item.releaseID != nil || item.barcode != nil || item.catalogNumber != nil || (!item.album.isEmpty && !item.artist.isEmpty)
    }

    /// The candidate that's most likely the copy, of its medium: a barcode (`byBarcode`: all of them were found by
    /// it) and catalog number say which edition, country and year which pressing; ties go to the plainer pressing
    /// (not a reissue, repress or club edition), then the oldest Discogs entry; a release titled exactly like the album
    /// beats one whose title only holds its words. Nil when none is of the medium.
    public static func best(_ candidates: [DiscogsCandidate], for facts: DiscogsEditionFacts, byBarcode: Bool = false) -> DiscogsMatch? {
        let code = facts.barcode.map(barcodeDigits)
        let catnos = facts.catalogNumbers.map(normalized).filter { !$0.isEmpty }
        let country = facts.country.map(discogsCountries) ?? []
        let album = tokens(facts.album).words
        var top: (score: Double, candidate: DiscogsCandidate, barcode: Bool, catno: Int)?
        for c in candidates where c.medium == facts.medium && DiscogsLink.isValid(c.releaseID) {
            let barcode = byBarcode || (code.map { b in c.barcodes.contains { barcodeDigits($0) == b } } ?? false)
            let theirs = c.catalogNumbers.map(normalized).filter { !$0.isEmpty }
            let catno = catnos.contains(where: theirs.contains) ? 2
                : catnos.contains { mine in theirs.contains { sharesCatalogNumber(mine, $0) } } ? 1 : 0
            var score = (barcode ? 8.0 : 0) + (catno == 2 ? 6 : catno == 1 ? 4 : 0)
            if !country.isEmpty, !c.country.isEmpty {
                let parts = Set(c.country.lowercased().components(separatedBy: " & "))
                score += !parts.isDisjoint(with: country) ? 3 : -1
            }
            if let y = facts.year, let theirs = c.year { score += y == theirs ? 2 : -1 }
            if !isRepress(c.notes) { score += 0.5 }
            if !album.isEmpty, tokens(c.title).words == album { score += 1 }
            if let t = top, t.score > score || (t.score == score && t.candidate.releaseID < c.releaseID) { continue }
            top = (score, c, barcode, catno)
        }
        guard let top else { return nil }
        let quality: DiscogsMatchQuality = top.barcode && top.catno == 2 ? .exact : top.barcode || top.catno > 0 ? .edition : .closest
        return DiscogsMatch(releaseID: top.candidate.releaseID, quality: quality)
    }

    /// Whether a search result is the album, whatever the accents, case, punctuation and articles: nearly all the
    /// words of the shorter title are in the longer one ("Chronicle" and "Chronicle: The 20 Greatest Hits"; "Vol. One"
    /// is "Volume 1"), and volume and part numbers agree.
    public static func isSameAlbum(_ title: String, _ album: String) -> Bool {
        let a = tokens(title), b = tokens(album)
        guard !a.words.isEmpty, !b.words.isEmpty, a.volumes == b.volumes else { return false }
        let (short, long) = a.words.count <= b.words.count ? (a.words, b.words) : (b.words, a.words)
        return Double(short.intersection(long).count) >= 0.8 * Double(short.count)
    }

    static func tokens(_ s: String) -> (words: Set<String>, volumes: [String]) {
        let numbers = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
                       "nine": "9", "ten": "10", "i": "1", "ii": "2", "iii": "3", "iv": "4"]
        let list = words(s).split(separator: " ").map(String.init).map { w -> String in
            switch w {
            case "volume", "vol": "vol"
            case "pt": "part"
            default: w
            }
        }
        var volumes: [String] = []
        for (i, w) in list.enumerated() where (w == "vol" || w == "part") && i + 1 < list.count {
            volumes.append(numbers[list[i + 1]] ?? list[i + 1])
        }
        let words = list.filter { !["the", "a", "an", "and", "vol", "part"].contains($0) }.map { numbers[$0] ?? $0 }
        return (Set(words), volumes)
    }

    static func words(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// Letters and digits, lowercased: "CDP 7 46001 2" and "cdp7460012" are the same catalog number.
    static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// "539 786-2" in "314 539 786-2": one holds the other, at least 5 characters of it.
    static func sharesCatalogNumber(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 5 && long.contains(short)
    }

    /// Without the leading zeros that UPCs and EANs of the same code differ by.
    static func barcodeDigits(_ s: String) -> String {
        let digits = s.filter { ("0"..."9").contains($0) }
        return String(digits.drop { $0 == "0" })
    }

    static func isRepress(_ notes: String) -> Bool {
        let n = notes.lowercased()
        return ["reissue", "repress", "club edition", "promo", "unofficial"].contains { n.contains($0) }
    }

    /// How Discogs names the country of an ISO code (MusicBrainz's), lowercased: "US" → us, "GB" → uk, "XE" → europe,
    /// "CA" → canada; a name is taken as it is.
    static func discogsCountries(_ country: String) -> Set<String> {
        let c = country.trimmingCharacters(in: .whitespaces)
        guard c.count == 2 else { return c.isEmpty ? [] : [c.lowercased()] }
        let code = c.uppercased()
        let special: [String: String] = ["US": "us", "GB": "uk", "XE": "europe", "XW": "worldwide", "CZ": "czech republic",
                                         "KR": "south korea", "RU": "russia", "TW": "taiwan", "HK": "hong kong"]
        if let name = special[code] { return [name] }
        guard let name = Locale(identifier: "en_US").localizedString(forRegionCode: code) else { return [code.lowercased()] }
        return [name.lowercased()]
    }
}

/// Looks an item's release up: its MusicBrainz release's Discogs link; else a barcode search; else the versions of
/// the album's Discogs master; else a search by catalog number, then by artist and title (`best` picks).
public struct DiscogsReleaseLookup: Sendable {
    /// A MusicBrainz release's facts (release and release group IDs).
    public var musicBrainz: @Sendable (String, String?) async throws -> MusicBrainzEditionFacts
    /// Discogs releases with the barcode.
    public var barcode: @Sendable (String, CollectionMedium) async throws -> [CollectionEdition]
    /// A Discogs master's releases of the medium.
    public var versions: @Sendable (Int, CollectionMedium) async throws -> [DiscogsCandidate]
    /// A Discogs database search for releases of the medium.
    public var search: @Sendable ([String: String], CollectionMedium) async throws -> [CollectionEdition]

    public init(musicBrainz: @escaping @Sendable (String, String?) async throws -> MusicBrainzEditionFacts,
                barcode: @escaping @Sendable (String, CollectionMedium) async throws -> [CollectionEdition],
                versions: @escaping @Sendable (Int, CollectionMedium) async throws -> [DiscogsCandidate],
                search: @escaping @Sendable ([String: String], CollectionMedium) async throws -> [CollectionEdition]) {
        self.musicBrainz = musicBrainz; self.barcode = barcode; self.versions = versions; self.search = search
    }

    public func match(for item: CollectionItem) async throws -> DiscogsMatch? {
        if let id = item.discogsReleaseID { return DiscogsMatch(releaseID: id, quality: .exact) }
        var facts = DiscogsEditionFacts(item: item)
        if let mb = item.releaseID { facts.add(try await musicBrainz(mb, item.releaseGroupID)) }
        if let id = facts.discogsRelease, DiscogsLink.isValid(id) { return DiscogsMatch(releaseID: id, quality: .exact) }
        // Searches can find other albums (Discogs matches barcodes loosely too): only those named like it count.
        func named(_ editions: [CollectionEdition]) -> [DiscogsCandidate] {
            editions.filter { facts.album.isEmpty || DiscogsReleaseMatcher.isSameAlbum($0.title, facts.album) }.compactMap(DiscogsCandidate.init)
        }
        if let code = facts.barcode,
           let m = DiscogsReleaseMatcher.best(named(try await barcode(code, facts.medium)), for: facts, byBarcode: true) {
            return m
        }
        if let master = facts.discogsMaster, let m = DiscogsReleaseMatcher.best(try await versions(master, facts.medium), for: facts) {
            return m
        }
        for catno in facts.catalogNumbers.prefix(2) {
            if let m = DiscogsReleaseMatcher.best(named(try await search(["catno": catno], facts.medium)), for: facts) { return m }
        }
        if !facts.album.isEmpty, !facts.artist.isEmpty,
           let m = DiscogsReleaseMatcher.best(named(try await search(["artist": facts.artist, "release_title": facts.album], facts.medium)), for: facts) {
            return m
        }
        return nil
    }
}

// MARK: Plan

/// What a sync would change on Discogs.
public struct DiscogsSyncPlan: Sendable {
    public struct Addition: Identifiable, Hashable, Sendable {
        public enum Reason: Hashable, Sendable {
            case new
            /// Its copy on Discogs was removed there.
            case removedOnDiscogs
            /// Its edition changed here; the copy of the old one is a removal.
            case editionChanged
        }

        public var item: CollectionItem
        public var releaseID: Int
        public var reason: Reason
        public var id: String { item.id }
    }

    public struct Removal: Identifiable, Hashable, Sendable {
        public enum Reason: Hashable, Sendable {
            /// Not one of the items here (added on Discogs, or before syncing).
            case onlyOnDiscogs
            /// Its item was removed here (or is no longer a CD or record).
            case removedHere
            /// The item's old edition: it's now another release.
            case editionChanged(itemID: String)
        }

        public var instance: DiscogsInstance
        public var reason: Reason
        public var id: Int { instance.instanceID }
    }

    /// An item matched to a copy already on Discogs that wasn't linked to it.
    public struct Adoption: Hashable, Sendable {
        public var itemID: String
        public var instance: DiscogsInstance
    }

    public var additions: [Addition] = []
    public var removals: [Removal] = []
    public var adoptions: [Adoption] = []
    /// Items whose copy on Discogs is already linked and up to date.
    public var inSync = 0
    /// CDs and records with no Discogs release found.
    public var unmatched: [CollectionItem] = []

    public init() {}

    /// `releases`: each item's release, where known. `links`: the instance each item (here or removed) was linked to
    /// in this account. `remote`: the collection on Discogs.
    public static func make(items: [CollectionItem], releases: [String: Int], links: [String: DiscogsSyncRow.Link],
                            remote: [DiscogsInstance]) -> DiscogsSyncPlan {
        var plan = DiscogsSyncPlan()
        let byInstance = Dictionary(remote.map { ($0.instanceID, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<Int>()
        var oldEditions: [Int: String] = [:]
        var unlinked: [(item: CollectionItem, release: Int, reason: Addition.Reason)] = []
        let synced = items.filter(DiscogsReleaseMatcher.isSynced)

        // Items already linked to a copy there first, so a copy is never matched to two items.
        for item in synced {
            let release = releases[item.id]
            if let link = links[item.id], let instance = byInstance[link.instanceID], !claimed.contains(instance.instanceID) {
                if release == nil || release == instance.releaseID {
                    // Up to date, or no longer matched here: a copy is never removed for that.
                    claimed.insert(instance.instanceID)
                    plan.inSync += 1
                } else if let release {
                    oldEditions[instance.instanceID] = item.id
                    unlinked.append((item, release, .editionChanged))
                }
            } else if let release {
                unlinked.append((item, release, links[item.id] != nil ? .removedOnDiscogs : .new))
            } else {
                plan.unmatched.append(item)
            }
        }
        // Then the others, each taking a copy of its release that no item has (so the first sync adds nothing
        // that's already there), else added.
        var free: [Int: [DiscogsInstance]] = [:]
        for instance in remote where !claimed.contains(instance.instanceID) && oldEditions[instance.instanceID] == nil {
            free[instance.releaseID, default: []].append(instance)
        }
        for (item, release, reason) in unlinked {
            if var copies = free[release], !copies.isEmpty {
                let instance = copies.removeFirst()
                free[release] = copies
                claimed.insert(instance.instanceID)
                plan.adoptions.append(Adoption(itemID: item.id, instance: instance))
            } else {
                plan.additions.append(Addition(item: item, releaseID: release, reason: reason))
            }
        }
        let syncedIDs = Set(synced.map(\.id))
        let linkedElsewhere = Set(links.filter { !syncedIDs.contains($0.key) }.map(\.value.instanceID))
        for instance in remote where !claimed.contains(instance.instanceID) {
            let reason: Removal.Reason = if let id = oldEditions[instance.instanceID] { .editionChanged(itemID: id) }
                else if linkedElsewhere.contains(instance.instanceID) { .removedHere }
                else { .onlyOnDiscogs }
            plan.removals.append(Removal(instance: instance, reason: reason))
        }
        return plan
    }

    public var isEmpty: Bool { additions.isEmpty && removals.isEmpty && adoptions.isEmpty }
}

/// What a sync did.
public struct DiscogsSyncOutcome: Sendable, Equatable {
    public var added = 0
    public var linked = 0
    public var removed = 0
    /// "Kind of Blue: Discogs answered with an error (HTTP 404)."
    public var failures: [String] = []
    public var cancelled = false

    public init() {}
}

public enum DiscogsSync {
    /// Links the adopted copies, adds `additions`, then removes `removals` (each saved as it's done, so an
    /// interrupted sync loses nothing). A rejected token stops it (thrown); other failures are listed and it goes on.
    public static func run(_ plan: DiscogsSyncPlan, additions: [DiscogsSyncPlan.Addition], removals: [DiscogsSyncPlan.Removal],
                           client: DiscogsCollectionClient, username: String, folderID: Int, database: Database,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> DiscogsSyncOutcome {
        var outcome = DiscogsSyncOutcome()
        let folder = folderID > 0 ? folderID : DiscogsFolder.uncategorized
        for a in plan.adoptions {
            try database.linkDiscogsInstance(itemID: a.itemID, username: username, instance: a.instance)
            outcome.linked += 1
        }
        let total = additions.count + removals.count
        var done = 0
        progress?(0, total)
        func failed(_ name: String, _ error: Error) throws {
            if case DiscogsError.unauthorized = error { throw error }
            outcome.failures.append("\(name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        for a in additions {
            if Task.isCancelled { outcome.cancelled = true; return outcome }
            do {
                let instance = try await client.add(releaseID: a.releaseID, folderID: folder, username: username)
                try database.linkDiscogsInstance(itemID: a.item.id, username: username,
                                                 instance: DiscogsInstance(instanceID: instance, releaseID: a.releaseID, folderID: folder))
                outcome.added += 1
            } catch is CancellationError {
                outcome.cancelled = true; return outcome
            } catch {
                try failed(a.item.album.isEmpty ? a.item.artist : a.item.album, error)
            }
            done += 1
            progress?(done, total)
        }
        for r in removals {
            if Task.isCancelled { outcome.cancelled = true; return outcome }
            do {
                try await client.remove(r.instance, username: username)
                try database.unlinkDiscogsInstance(r.instance.instanceID, username: username)
                outcome.removed += 1
            } catch is CancellationError {
                outcome.cancelled = true; return outcome
            } catch {
                try failed(r.instance.title.isEmpty ? "Release \(r.instance.releaseID)" : r.instance.title, error)
            }
            done += 1
            progress?(done, total)
        }
        return outcome
    }
}

// MARK: Saved links

/// One item's row in `discogs_sync`: the release it was matched to (from what, and when) and the copy on Discogs
/// it's linked to.
public struct DiscogsSyncRow: Hashable, Sendable {
    public struct Link: Hashable, Sendable {
        public var instanceID: Int
        public var releaseID: Int
        public init(instanceID: Int, releaseID: Int) { self.instanceID = instanceID; self.releaseID = releaseID }
    }

    public var itemID: String
    /// `DiscogsReleaseMatcher.basis` of the item when it was matched; empty for a row made by linking.
    public var basis: String
    /// Nil: none found.
    public var releaseID: Int?
    public var checkedAt: Date
    public var username: String?
    public var instanceID: Int?
    public var instanceReleaseID: Int?
    public var folderID: Int?
    /// How sure the match is; nil for one made by the first matcher (exact).
    public var quality: DiscogsMatchQuality?
    /// The `DiscogsReleaseMatcher.version` that matched it (1 for rows without one).
    public var matcher: Int

    public init(itemID: String, basis: String, releaseID: Int?, checkedAt: Date, username: String? = nil,
                instanceID: Int? = nil, instanceReleaseID: Int? = nil, folderID: Int? = nil, quality: DiscogsMatchQuality? = nil,
                matcher: Int = DiscogsReleaseMatcher.version) {
        self.itemID = itemID; self.basis = basis; self.releaseID = releaseID; self.checkedAt = checkedAt
        self.username = username; self.instanceID = instanceID; self.instanceReleaseID = instanceReleaseID; self.folderID = folderID
        self.quality = quality; self.matcher = matcher
    }

    /// The copy it's linked to in this account.
    public func link(for username: String) -> Link? {
        guard let instanceID, let instanceReleaseID, self.username?.lowercased() == username.lowercased() else { return nil }
        return Link(instanceID: instanceID, releaseID: instanceReleaseID)
    }
}

extension Database {
    /// Mac-only, created without a schema version change (see `createRipChecksTable`). Rows outlive their items, so a
    /// removed item's copy on Discogs can be offered for removal.
    func createDiscogsSyncTable() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS discogs_sync(
            item_id TEXT PRIMARY KEY, basis TEXT NOT NULL, release_id INTEGER, checked_at REAL NOT NULL,
            username TEXT, instance_id INTEGER, instance_release_id INTEGER, folder_id INTEGER, quality TEXT, matcher INTEGER)
        """)
        // Added with the second matcher.
        let present = try columns(of: "discogs_sync")
        if !present.contains("quality") { try exec("ALTER TABLE discogs_sync ADD COLUMN quality TEXT") }
        if !present.contains("matcher") { try exec("ALTER TABLE discogs_sync ADD COLUMN matcher INTEGER") }
    }

    /// By item id. Rows are untrusted (the file may come from elsewhere): values that don't validate read as unknown.
    /// Columns added later read as unknown when missing (a copy that wasn't opened by this version).
    public func discogsSyncRows() throws -> [String: DiscogsSyncRow] {
        let present = try columns(of: "discogs_sync")
        guard !present.isEmpty else { return [:] }
        let select = ["item_id", "basis", "release_id", "checked_at", "username", "instance_id", "instance_release_id", "folder_id",
                      "quality", "matcher"].map { present.contains($0) ? $0 : "NULL" }.joined(separator: ",")
        let rows = try query("SELECT \(select) FROM discogs_sync") { r -> DiscogsSyncRow? in
            guard let id = r.string(0)?.lowercased(), CollectionItem.isValidID(id) else { return nil }
            let checked = r.double(3)
            let release = r.int(2).flatMap { DiscogsLink.isValid($0) ? $0 : nil }
            var row = DiscogsSyncRow(itemID: id, basis: String((r.string(1) ?? "").prefix(1000)), releaseID: release,
                                     checkedAt: Date(timeIntervalSince1970: checked.isFinite ? checked : 0),
                                     quality: r.string(8).flatMap(DiscogsMatchQuality.init(rawValue:)), matcher: max(1, r.int(9) ?? 1))
            if let user = r.string(4), DiscogsIdentity.isValidUsername(user), let instance = r.int(5), instance > 0,
               let instanceRelease = r.int(6), DiscogsLink.isValid(instanceRelease) {
                row.username = user
                row.instanceID = instance
                row.instanceReleaseID = instanceRelease
                row.folderID = r.int(7).map { max(0, $0) }
            }
            return row
        }
        return Dictionary(rows.compactMap { $0 }.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Saves the releases items were matched to, keeping their links.
    public func saveDiscogsMatches(_ rows: [DiscogsSyncRow]) throws {
        try transaction {
            for row in rows where CollectionItem.isValidID(row.itemID) {
                try exec("""
                INSERT INTO discogs_sync(item_id,basis,release_id,checked_at,quality,matcher) VALUES(?,?,?,?,?,?)
                ON CONFLICT(item_id) DO UPDATE SET basis=excluded.basis, release_id=excluded.release_id, checked_at=excluded.checked_at,
                    quality=excluded.quality, matcher=excluded.matcher
                """, [.text(row.itemID), .text(row.basis), .int(row.releaseID), .double(row.checkedAt.timeIntervalSince1970),
                      row.quality.map { .text($0.rawValue) } ?? .null, .int(row.matcher)])
            }
        }
    }

    /// Links an item to a copy on Discogs (replacing its link), keeping its match.
    public func linkDiscogsInstance(itemID: String, username: String, instance: DiscogsInstance, at date: Date = Date()) throws {
        guard CollectionItem.isValidID(itemID), DiscogsIdentity.isValidUsername(username) else { throw CollectionError.invalidItem }
        try exec("""
        INSERT INTO discogs_sync(item_id,basis,release_id,checked_at,username,instance_id,instance_release_id,folder_id)
        VALUES(?,'',NULL,?,?,?,?,?)
        ON CONFLICT(item_id) DO UPDATE SET username=excluded.username, instance_id=excluded.instance_id,
            instance_release_id=excluded.instance_release_id, folder_id=excluded.folder_id
        """, [.text(itemID), .double(date.timeIntervalSince1970), .text(username), .int(instance.instanceID),
              .int(instance.releaseID), .int(instance.folderID)])
    }

    /// Forgets the items linked to a copy that was removed from Discogs; rows of items no longer here go.
    public func unlinkDiscogsInstance(_ instanceID: Int, username: String) throws {
        try transaction {
            try exec("""
            UPDATE discogs_sync SET username=NULL, instance_id=NULL, instance_release_id=NULL, folder_id=NULL
            WHERE instance_id=? AND lower(username)=lower(?)
            """, [.int(instanceID), .text(username)])
            try exec("DELETE FROM discogs_sync WHERE instance_id IS NULL AND item_id NOT IN (SELECT id FROM collection_items)")
        }
    }
}
