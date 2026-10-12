import Foundation

// A public library catalog run on Aspen Discovery (such as the Minuteman Library Network's
// https://natick.minlib.net). Aspen's JSON API is restricted to the library's own servers, so the catalog is
// read the way its website reads itself: the search results page (20 results a page) and the AJAX endpoints
// behind "Where is it?", "Show Editions" and My Account. The pages sit behind Cloudflare, which turns away
// plain HTTP clients, so the app loads them in a web view; everything here is pure parsing and URL building.

// MARK: Query

public enum CatalogSearchField: String, CaseIterable, Codable, Sendable, Identifiable {
    case keyword = "Keyword"
    case title = "AllTitles"
    case artist = "Author"
    case subject = "Subject"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .keyword: "Keyword"
        case .title: "Title"
        case .artist: "Artist"
        case .subject: "Subject"
        }
    }
}

/// The catalog's own sort orders (the values its results page offers).
public enum CatalogSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case relevance = "relevance"
    case newest = "year desc,title asc"
    case oldest = "year asc,title asc"
    case artist = "author asc,title asc"
    case title = "title"
    case recentlyAdded = "days_since_added asc"
    case popular = "popularity desc"
    case mostHolds = "total_holds desc"
    case callNumber = "callnumber_sort"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: "Best Match"
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .artist: "Artist"
        case .title: "Title"
        case .recentlyAdded: "Recently Added"
        case .popular: "Most Checked Out"
        case .mostHolds: "Most Holds"
        case .callNumber: "Call Number"
        }
    }
}

/// One catalog search: text, the owning libraries (any of them), "available now at" a library, and the order.
public struct CatalogQuery: Hashable, Codable, Sendable {
    public var text: String
    public var field: CatalogSearchField
    /// Libraries that own a copy (any of them); empty for the whole network.
    public var libraries: [String]
    /// Only titles on the shelf right now at this library.
    public var availableAt: String?
    public var sort: CatalogSort
    public var format: String

    public init(text: String = "", field: CatalogSearchField = .keyword, libraries: [String] = [],
                availableAt: String? = nil, sort: CatalogSort = .relevance, format: String = "Music CD") {
        self.text = text; self.field = field; self.libraries = libraries
        self.availableAt = availableAt; self.sort = sort; self.format = format
    }

    /// The results page path, relative to the catalog's site.
    public func path(page: Int = 1) -> String {
        var filters = ["format:\"\(format)\""]
        filters += libraries.map { "owning_location:\"\($0)\"" }
        if let availableAt { filters.append("available_at:\"\(availableAt)\"") }
        var items: [(String, String)] = [("lookfor", text.trimmingCharacters(in: .whitespaces)), ("searchIndex", field.rawValue)]
        items += filters.map { ("filter[]", $0) }
        items += [("sort", sort.rawValue), ("view", "list"), ("searchSource", "local")]
        if page > 1 { items.append(("page", String(page))) }
        return "/Search/Results?" + CatalogPaths.query(items)
    }
}

public enum CatalogPaths {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// Every library and branch in the network that owns a copy, with counts for the search `searchId`.
    public static func libraryFacet(searchId: String) -> String {
        "/Search/AJAX?" + query([("method", "getSearchFacetPopup"), ("searchId", searchId), ("facetName", "owning_location")])
    }

    /// Copies at every library ("Where is it?").
    public static func copies(workId: String, format: String = "Music CD") -> String {
        "/GroupedWork/\(encode(workId))/AJAX?" + query([("method", "getCopyDetails"), ("format", format), ("recordId", workId)])
    }

    /// The work's editions: publisher, year, edition, UPC and status of each.
    public static func editions(workId: String, variationId: String, format: String = "Music CD") -> String {
        "/GroupedWork/AJAX?" + query([("method", "getRelatedManifestations"), ("id", workId),
                                     ("format", format.replacingOccurrences(of: " ", with: "_")), ("variationId", variationId)])
    }

    public static func work(_ workId: String) -> String { "/GroupedWork/\(encode(workId))/Home" }

    public static func cover(workId: String, size: String = "medium") -> String {
        "/bookcover.php?" + query([("id", workId), ("size", size), ("type", "grouped_work"), ("category", "Music")])
    }

    /// The "Add to List" form, which lists the patron's lists.
    public static let userLists = "/MyAccount/AJAX?method=getSaveToListForm&source=GroupedWork&sourceId=lists"

    public static func addToList(listId: String, workId: String, notes: String = "") -> String {
        "/MyAccount/AJAX?" + query([("method", "saveToList"), ("notes", notes), ("listId", listId),
                                    ("source", "GroupedWork"), ("sourceId", workId)])
    }

    public static func list(_ listId: String, page: Int = 1) -> String {
        "/MyAccount/MyList/\(encode(listId))" + (page > 1 ? "?page=\(page)" : "")
    }

    /// Removes an entry; the reply is the list's first page without it.
    public static func removeFromList(listId: String, entryId: String) -> String {
        "/MyAccount/MyList/\(encode(listId))?delete=\(encode(entryId))"
    }

    public static let login = "/AJAX/JSON?method=loginUser"
    public static let logout = "/MyAccount/Logout"
    public static let checkouts = "/MyAccount/AJAX?method=getCheckouts&source=all"
    public static let holds = "/MyAccount/AJAX?method=getHolds&source=all"

    /// The form body of a sign-in request. No `ldapLogin` field: the site's own form leaves it out, and an empty
    /// one sends the server down its LDAP path, which fails.
    public static func loginBody(username: String, password: String) -> String {
        query([("username", username), ("password", password), ("rememberMe", "true")])
    }

    /// "https://natick.minlib.net" → "Natick", the library a branch site is scoped to.
    public static func siteLibrary(_ site: URL) -> String? {
        guard let host = site.host, let first = host.split(separator: ".").first, host.split(separator: ".").count > 2,
              !["www", "catalog", "search"].contains(first.lowercased()) else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }
}

// MARK: Models

/// Where a title can be had, from the point of view of the catalog site's own library.
public enum CatalogAvailability: String, Codable, Sendable {
    /// On the shelf here.
    case here
    /// Not here (checked out or not owned) but on a shelf elsewhere in the network.
    case elsewhere
    /// Every copy is checked out, in transit or on hold.
    case unavailable
    case onOrder
    case online
    case unknown

    /// Aspen's status class ("status-on-shelf", "status-available-elsewhere"…).
    public init(statusClass: String) {
        let c = statusClass.lowercased()
        if c.contains("on-order") { self = .onOrder }
        else if c.contains("available-online") { self = .online }
        else if c.contains("available-elsewhere") { self = .elsewhere }
        else if c.contains("on-shelf") || c.contains("library-use-only") || c == "status-available" { self = .here }
        else if c.contains("checked-out") || c.contains("on-hold") || c.contains("in-transit") || c.contains("unavailable") { self = .unavailable }
        else { self = .unknown }
    }

    public var isAvailableNow: Bool { self == .here || self == .elsewhere }
}

/// One title in a page of search results (an Aspen "grouped work").
public struct CatalogItem: Identifiable, Hashable, Codable, Sendable {
    /// The grouped work ID ("d0797869-8043-715e-f883-2100b5c2cd80-eng").
    public var id: String
    /// The title before any ": subtitle", as cataloged ("Sgt. Pepper's lonely hearts club band").
    public var title: String
    public var subtitle: String?
    /// The main entry as cataloged ("Miranda, Lin-Manuel, 1980-"); nil for compilations.
    public var author: String?
    public var year: Int?
    public var language: String?
    public var series: String?
    /// The ILS record of the edition shown (".b34105876").
    public var recordId: String?
    /// Aspen's variation ID, needed to list the editions.
    public var variationId: String?
    public var statusText: String
    public var availability: CatalogAvailability
    /// The shelf and call number at the catalog site's library, when it has a copy.
    public var shelfLocation: String?
    public var callNumber: String?
    public var availableCopies: Int?
    /// The work's page on the catalog site.
    public var pagePath: String

    public init(id: String, title: String, subtitle: String? = nil, author: String? = nil, year: Int? = nil,
                language: String? = nil, series: String? = nil, recordId: String? = nil, variationId: String? = nil,
                statusText: String = "", availability: CatalogAvailability = .unknown, shelfLocation: String? = nil,
                callNumber: String? = nil, availableCopies: Int? = nil, pagePath: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.author = author; self.year = year
        self.language = language; self.series = series; self.recordId = recordId; self.variationId = variationId
        self.statusText = statusText; self.availability = availability; self.shelfLocation = shelfLocation
        self.callNumber = callNumber; self.availableCopies = availableCopies
        self.pagePath = pagePath ?? CatalogPaths.work(id)
    }

    /// "Hamilton: Original Broadway Cast Recording": catalogs capitalize only the first word.
    public var displayTitle: String {
        let main = CatalogText.titleCase(title)
        guard let subtitle, !subtitle.isEmpty else { return main }
        return "\(main): \(CatalogText.titleCase(subtitle))"
    }

    /// "Lin-Manuel Miranda" for "Miranda, Lin-Manuel, 1980-"; empty for compilations.
    public var artist: String { author.map(CatalogText.displayName) ?? "" }

    public var coverPath: String { CatalogPaths.cover(workId: id) }
}

public struct CatalogPage: Sendable {
    public var items: [CatalogItem]
    public var total: Int
    public var page: Int
    /// The search's ID on the site, for its facet popups.
    public var searchId: String?

    public init(items: [CatalogItem], total: Int, page: Int, searchId: String? = nil) {
        self.items = items; self.total = total; self.page = page; self.searchId = searchId
    }

    public var hasMore: Bool { page * CatalogPage.pageSize < total }
    public static let pageSize = 20
}

/// A library or branch in the network, with how many matching titles it owns.
public struct CatalogLibrary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public var name: String
    public var count: Int?

    public init(name: String, count: Int? = nil) { self.name = name; self.count = count }
}

/// The copies at one shelf location ("Where is it?").
public struct CatalogCopy: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(location)\u{1}\(callNumber)" }
    /// "Natick", from "Natick - Audiovisual".
    public var library: String
    public var location: String
    public var callNumber: String
    public var available: Int
    public var total: Int

    public var isAvailable: Bool { available > 0 }
}

/// One edition of a work ("Show Editions").
public struct CatalogEdition: Identifiable, Hashable, Codable, Sendable {
    public var id: String { recordId }
    public var recordId: String
    /// "[2015] Atlantic Recording Company"
    public var published: String?
    public var year: Int?
    public var publisher: String?
    /// "[Explicit version]"
    public var edition: String?
    /// "2 audio discs : CD audio, digital ; 4 3/4 in."
    public var physical: String?
    public var upc: String?
    public var statusText: String
    public var availability: CatalogAvailability
}

/// The extra details on a work's page.
public struct CatalogWorkDetails: Hashable, Codable, Sendable {
    public struct Contributor: Hashable, Codable, Sendable {
        public var name: String
        public var role: String?
    }

    public struct Contents: Hashable, Codable, Sendable {
        /// "From the Music CD - [Explicit version]"
        public var heading: String?
        public var tracks: [String]
    }

    public var contributors: [Contributor] = []
    public var upcs: [String] = []
    public var subjects: [String] = []
    public var contents: [Contents] = []

    public init() {}
}

/// One of the patron's lists on the catalog site.
public struct CatalogUserList: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// A title on one of the patron's lists; `entryId` identifies it for removal.
public struct CatalogListEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { entryId }
    public var entryId: String
    public var item: CatalogItem

    public init(entryId: String, item: CatalogItem) { self.entryId = entryId; self.item = item }
}

public struct CatalogListPage: Sendable {
    public var entries: [CatalogListEntry]
    public var total: Int
    public var page: Int
}

/// A title the signed-in patron has checked out.
public struct CatalogCheckout: Identifiable, Hashable, Codable, Sendable {
    public var id: String { recordId ?? "\(title)\u{1}\(due ?? "")" }
    public var title: String
    public var subtitle: String?
    public var author: String?
    public var format: String?
    public var callNumber: String?
    /// As shown ("Oct 20, 2026").
    public var due: String?
    public var renewed: String?
    public var recordId: String?
    public var coverPath: String?

    public var displayTitle: String {
        let main = CatalogText.titleCase(title)
        guard let subtitle, !subtitle.isEmpty else { return main }
        return "\(main): \(CatalogText.titleCase(subtitle))"
    }

    public var artist: String { author.map(CatalogText.displayName) ?? "" }

    public var dueDate: Date? {
        guard let due else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f.date(from: due)
    }
}

public enum CatalogError: Error, LocalizedError, Equatable {
    case blocked(Int)
    case http(Int)
    case badResponse(String)
    case signIn(String)
    case notSignedIn
    /// The site asked for fewer requests (HTTP 429); nothing more is sent before this time.
    case rateLimited(Date)

    public var errorDescription: String? {
        switch self {
        case .blocked(let code): "The library catalog turned the request away (HTTP \(code)). Wait a minute and try again."
        case .http(let code): "The library catalog returned HTTP \(code)."
        case .badResponse(let what): "Unexpected response from the library catalog: \(what)."
        case .signIn(let message): message
        case .notSignedIn: "Sign in to your library account in Settings first."
        case .rateLimited(let until):
            "The library's website asked for a pause. Trying again at \(until.formatted(date: .omitted, time: .shortened))."
        }
    }
}

// MARK: Text

public enum CatalogText {
    static let dateQualifier = try! NSRegularExpression(pattern: #"^(\d{4}(-\d{4})?-?|b\. \d{4}|d\. \d{4}|active .*|\d{2}th cent\.?|approximately .*)$"#)
    static let groupQualifier = try! NSRegularExpression(pattern: #"\s*\((musical group|group|band|ensemble|musician|singer|vocalist|rapper|performer|composer|conductor|keyboard player|[a-z ]+ player)\)\s*$"#, options: .caseInsensitive)

    /// A catalog name heading as people write it: "Miranda, Lin-Manuel, 1980-" → "Lin-Manuel Miranda",
    /// "Dropkick Murphys (Musical group)" → "Dropkick Murphys". Group names keep their commas.
    public static func displayName(_ heading: String) -> String {
        var s = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGroup = s.range(of: "(musical group)", options: .caseInsensitive) != nil || s.range(of: "(group)", options: .caseInsensitive) != nil
        while let m = groupQualifier.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            s.removeSubrange(r)
        }
        var parts = s.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        while parts.count > 1, let last = parts.last,
              dateQualifier.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil {
            parts.removeLast()
        }
        if parts.last?.hasSuffix(".") == true, parts.last?.split(separator: " ").count ?? 0 > 1 {
            parts[parts.count - 1].removeLast()
        }
        guard !isGroup, parts.count == 2, !parts[1].contains("&"), !parts[1].lowercased().contains(" and ") else {
            return parts.joined(separator: ", ")
        }
        return "\(parts[1]) \(parts[0])"
    }

    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of",
                                          "on", "or", "over", "the", "to", "up", "with", "vs", "vs.", "de", "la", "le", "et"]

    /// Catalog titles use sentence case ("Sgt. Pepper's lonely hearts club band"); show them in title case.
    /// Words that already have capitals ("NOW", "LEGEND", "McCartney") are left alone.
    public static func titleCase(_ s: String) -> String {
        var out: [String] = []
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        for (i, w) in words.enumerated() {
            let word = String(w)
            let lower = word.lowercased()
            if word != lower || word.isEmpty { out.append(word); continue }
            if i > 0, i < words.count - 1, smallWords.contains(lower) { out.append(word); continue }
            out.append(capitalizeFirstLetter(word))
        }
        return out.joined(separator: " ")
    }

    static func capitalizeFirstLetter(_ w: String) -> String {
        guard let i = w.firstIndex(where: \.isLetter) else { return w }
        return w[..<i] + w[i].uppercased() + w[w.index(after: i)...]
    }

    /// A key for comparing titles and names: case, accents, punctuation, "&"/"and" and a leading "The" ignored.
    public static func key(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let mapped = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var words = String(mapped).split(separator: " ").map(String.init)
        if words.first == "the", words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// The first four-digit year in "[2025]", "2026.", "p2015, c2016".
    public static func year(_ s: String?) -> Int? {
        guard let s, let r = s.range(of: #"(1[89]|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    /// "1,975" → 1975.
    static func number(_ s: Substring) -> Int? { Int(s.replacingOccurrences(of: ",", with: "")) }

    /// A barcode as MusicBrainz stores it: GTIN-14 "00075678668432" and UPC-A "075678668432" are the same code.
    /// Older catalog records often drop a UPC's leading zero and check digit ("7464395412" for "074643954129"):
    /// those are completed first.
    public static func barcodeVariants(_ upc: String) -> [String] {
        let digits = upc.filter(\.isNumber)
        guard digits.count >= 8 else { return [] }
        let trimmed = String(digits.drop { $0 == "0" })
        var out: [String] = []
        if let completed = completedUPC(digits) {
            out += [completed, "0" + completed]
        }
        for length in [12, 13] where trimmed.count <= length {
            out.append(String(repeating: "0", count: length - trimmed.count) + trimmed)
        }
        if trimmed.count > 13 { out.append(trimmed) }
        return out
    }

    /// A 10- or 11-digit code that isn't a valid UPC-A once padded, as the UPC-A with its check digit added.
    static func completedUPC(_ digits: String) -> String? {
        guard digits.count == 10 || digits.count == 11 else { return nil }
        let padded = String(repeating: "0", count: 12 - digits.count) + digits
        guard upcCheckDigit(padded.prefix(11)) != padded.last?.wholeNumberValue else { return nil }
        let body = String(repeating: "0", count: 11 - digits.count) + digits
        return upcCheckDigit(Substring(body)).map { body + String($0) }
    }

    /// Whether looking a code up may find more than it did before `completedUPC` (see `CatalogEnricher.version`).
    public static func isTruncatedUPC(_ upc: String) -> Bool { completedUPC(upc.filter(\.isNumber)) != nil }

    /// The UPC-A check digit for 11 digits.
    static func upcCheckDigit(_ body: Substring) -> Int? {
        let values = body.compactMap(\.wholeNumberValue)
        guard values.count == 11 else { return nil }
        let sum = values.enumerated().reduce(0) { $0 + ($1.offset.isMultiple(of: 2) ? 3 : 1) * $1.element }
        return (10 - sum % 10) % 10
    }
}
