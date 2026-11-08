import Foundation

// The Shop's price guide: what an album (or one edition of it) sells for on Discogs and eBay (`EbayPrices.swift`).
// Discogs' part comes from its public marketplace
// figures: the lowest price and copies for sale of the album's master and of a few of its editions (the one you're
// holding when it's known, the most collected one, the original), with how many people have and want each, plus,
// with the user's personal access token, Discogs' suggested prices by condition (they need seller settings on
// Discogs) and the copies already in their Discogs collection. It works without AI: the Shop shows it on both
// apps, and the Radio DJ reads it through the `discogs_prices` tool (`RadioDJShopping.swift`).

/// What to price: an album by name, narrowed by whatever is known about the edition.
public struct PriceGuideRequest: Hashable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case cd, vinyl, any

        public var medium: CollectionMedium? {
            switch self {
            case .cd: .cd
            case .vinyl: .vinyl
            case .any: nil
            }
        }

        public var name: String {
            switch self {
            case .cd: "CD"
            case .vinyl: "Vinyl"
            case .any: "Any Format"
            }
        }

        public init(_ shop: ShopFormat) { self = shop == .vinyl ? .vinyl : .cd }
        public var shopFormat: ShopFormat { self == .vinyl ? .vinyl : .cd }
    }

    public var artist: String
    public var album: String
    public var format: Format
    public var barcode: String
    public var catalogNumber: String
    public var label: String
    public var country: String
    public var year: Int?
    /// Known Discogs IDs (a picked search result, the Mac Shop's MusicBrainz links): no search needed.
    public var releaseID: Int?
    public var masterID: Int?

    public init(artist: String, album: String, format: Format = .any, barcode: String = "", catalogNumber: String = "",
                label: String = "", country: String = "", year: Int? = nil, releaseID: Int? = nil, masterID: Int? = nil) {
        self.artist = artist; self.album = album; self.format = format; self.barcode = barcode
        self.catalogNumber = catalogNumber; self.label = label; self.country = country; self.year = year
        self.releaseID = DiscogsLink.isValid(releaseID) ? releaseID : nil
        self.masterID = DiscogsLink.isValid(masterID) ? masterID : nil
    }

    /// Digits of the barcode, when it reads as one (6 to 20 digits).
    var barcodeDigits: String? {
        let digits = barcode.filter { ("0"..."9").contains($0) }
        return (6...20).contains(digits.count) ? digits : nil
    }
}

/// One of Discogs' conditions and what Discogs suggests asking for a copy in it.
public struct DiscogsConditionPrice: Hashable, Sendable {
    public var condition: String
    public var price: Money

    public init(condition: String, price: Money) { self.condition = condition; self.price = price }

    /// "VG+" from "Very Good Plus (VG+)".
    public var short: String {
        guard let open = condition.lastIndex(of: "("), condition.hasSuffix(")") else { return condition }
        return String(condition[condition.index(after: open)..<condition.index(before: condition.endIndex)])
    }

    /// Best first: Mint down to Poor.
    static let order = ["Mint (M)", "Near Mint (NM or M-)", "Very Good Plus (VG+)", "Very Good (VG)", "Good Plus (G+)",
                        "Good (G)", "Fair (F)", "Poor (P)"]
}

/// One edition (Discogs release) with its marketplace figures.
public struct DiscogsPricedEdition: Hashable, Sendable, Identifiable {
    /// Why it's in the guide.
    public enum Role: String, Hashable, Sendable {
        case identified, mostCollected, original, newest

        public var name: String {
            switch self {
            case .identified: "This edition"
            case .mostCollected: "Most common"
            case .original: "Original"
            case .newest: "Latest reissue"
            }
        }
    }

    public var releaseID: Int
    public var title: String
    public var year: Int?
    public var country: String
    public var label: String
    public var catalogNumber: String
    /// "LP, Album, Mono", "CD, Album, Remastered".
    public var format: String
    public var roles: [Role]
    public var lowest: Money?
    public var forSale: Int
    public var have: Int?
    public var want: Int?
    public var rating: Double?
    public var ratingCount: Int?
    /// Best condition first; empty without a token (or seller settings).
    public var suggestions: [DiscogsConditionPrice] = []
    /// What it has sold for on Discogs (read from its release page for a copy's value only; nil: not read, or never sold).
    public var sales: DiscogsSalesHistory?

    public var id: Int { releaseID }
    public var webURL: URL? { DiscogsLink.releaseURL(releaseID) }
    /// Where its copies for sale are listed.
    public var marketURL: URL? { URL(string: "https://www.discogs.com/sell/release/\(releaseID)") }

    /// "US 1959 · Columbia CL 1355 · LP, Album, Mono".
    public var details: String {
        let place = [country, year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let label = [self.label, catalogNumber].filter { !$0.isEmpty }.joined(separator: " ")
        return [place, label, format].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What a playable copy goes for: Very Good to Near Mint suggestions, when Discogs gave them.
    public var fairRange: (low: Money, high: Money)? {
        let middle = suggestions.filter { ["VG", "VG+", "NM or M-"].contains($0.short) }.map(\.price)
        guard let low = middle.min(), let high = middle.max() else { return nil }
        return (low, high)
    }
}

/// A copy in the user's Discogs collection that is a version of the album.
public struct DiscogsOwnedCopy: Hashable, Sendable, Identifiable {
    public var instanceID: Int
    public var releaseID: Int
    public var title: String
    public var format: String
    public var year: Int?
    public var catalogNumber: String
    /// The very edition being priced.
    public var sameEdition: Bool

    public var id: Int { instanceID }
    public var webURL: URL? { DiscogsLink.releaseURL(releaseID) }
}

/// What the album sells for on Discogs and eBay.
public struct PriceGuide: Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var request: PriceGuideRequest
    /// As Discogs lists it (empty when nothing was found).
    public var artist = ""
    public var title = ""
    public var year: Int?
    public var masterID: Int?
    /// Every version, any format: the cheapest copy and how many are for sale.
    public var masterLowest: Money?
    public var masterForSale: Int?
    /// Versions in the format (as far as they were read).
    public var versions = 0
    public var editions: [DiscogsPricedEdition] = []
    /// Copies in the user's Discogs collection (nil: not checked, no account).
    public var ownedOnDiscogs: [DiscogsOwnedCopy]?
    public var thumbnail: URL?
    /// Recent eBay sales (signed in to eBay only) and eBay listings for sale now (nil: not read).
    public var ebaySold: EbayPriceSummary?
    public var ebayForSale: EbayPriceSummary?
    /// What couldn't be read, and why.
    public var notes: [String] = []
    /// The currency of the lowest prices (suggestions are in the account's selling currency).
    public var currency = "USD"

    public init(request: PriceGuideRequest) { self.request = request }

    public var found: Bool { masterID != nil || !editions.isEmpty }
    /// Anything to show: Discogs found it, or eBay has copies.
    public var hasPrices: Bool { found || ebaySold?.isEmpty == false || ebayForSale?.isEmpty == false }

    public var webURL: URL? {
        if let masterID { return URL(string: "https://www.discogs.com/master/\(masterID)") }
        return editions.first?.webURL
    }

    /// Every copy of the album in the format for sale on Discogs.
    public var marketURL: URL? {
        if let masterID {
            var c = URLComponents(string: "https://www.discogs.com/sell/list")
            c?.queryItems = [URLQueryItem(name: "master_id", value: String(masterID))]
                + (request.format == .any ? [] : [URLQueryItem(name: "format", value: request.format.shopFormat.discogsFormat)])
            return c?.url
        }
        return editions.first?.marketURL
    }

    /// A price range to lead with, from the best source there is: recent eBay sales (used), Discogs' suggestions for
    /// a playable copy of the edition, eBay asking prices (used), else the cheapest Discogs copy.
    public struct FairPrice: Hashable, Sendable {
        public var low: Money
        public var high: Money
        public var source: String
        /// From a pressing's Discogs sales: their median (the estimate) and the last sale's date.
        public var median: Money?
        public var lastSold: Date?

        public var text: String { low == high ? PriceGuide.text(low) : "\(PriceGuide.text(low))–\(PriceGuide.text(high))" }
    }

    public var fairPrice: FairPrice? {
        if let sold = ebaySold?.used ?? ebaySold?.new, sold.count >= 3 {
            return FairPrice(low: sold.typicalLow, high: sold.typicalHigh, source: "eBay sales, \(sold.count) recently sold")
        }
        if let edition = headline, let range = edition.fairRange {
            return FairPrice(low: range.low, high: range.high, source: "Discogs' suggestion, VG to NM")
        }
        if let listed = ebayForSale?.used, listed.count >= 3 {
            return FairPrice(low: listed.typicalLow, high: listed.typicalHigh, source: "eBay asking prices, \(listed.count) used for sale")
        }
        if let lowest = headline?.lowest {
            return FairPrice(low: lowest, high: lowest, source: "the cheapest copy on Discogs")
        }
        return nil
    }

    /// The Shop's estimate: what Discogs suggests for a Very Good to Near Mint copy of the album's most common
    /// pressing (the most collected edition), plus what a seller in the US typically charges to ship one when that's
    /// known (`shipping`, in the guide's currency). Without suggestions (they need a Discogs token), the cheapest copy
    /// of that pressing on Discogs; without any Discogs prices, `fairPrice`.
    public func shopEstimate(shipping: Money?) -> FairPrice? {
        guard let edition = mostCommon else { return fairPrice }
        let pressing = edition.details.isEmpty ? "" : " (\(edition.details))"
        func plus(_ money: Money) -> Money {
            guard let shipping, shipping.currency == money.currency else { return money }
            return Money(money.amount + shipping.amount, money.currency)
        }
        let shipped: String
        if let shipping, (edition.fairRange?.low.currency ?? edition.lowest?.currency) == shipping.currency {
            shipped = ", plus about \(Self.text(shipping)) shipping from a US seller"
        } else {
            shipped = ", before shipping"
        }
        if let range = edition.fairRange {
            return FairPrice(low: plus(range.low), high: plus(range.high),
                             source: "Discogs' suggestion for the most common pressing, VG to NM\(shipped)\(pressing)")
        }
        if let lowest = edition.lowest {
            return FairPrice(low: plus(lowest), high: plus(lowest),
                             source: "the cheapest copy of the most common pressing on Discogs\(shipped)\(pressing)")
        }
        return fairPrice
    }

    /// What a copy you own is worth, from Discogs alone (never eBay): the copy's own pressing when the guide
    /// identified it, else the album's most common one (`valuedEdition`); Discogs' suggestion for the copy's media
    /// grade when it's graded and Discogs has one, else its Very Good to Near Mint suggestions, else the low to high of
    /// what that pressing has sold for on Discogs (its median the estimate), else the cheapest copy of it for sale;
    /// nil when Discogs has no price for it. No shipping: it's what the copy is worth.
    public func copyEstimate(grade: CollectionGrade?) -> FairPrice? {
        let own = editions.first { $0.roles.contains(.identified) }
        guard let edition = valuedEdition else { return nil }
        let pressing = own != nil ? "this pressing" : "the most common pressing"
        if let grade, grade.isMediaGrade,
           let suggestion = edition.suggestions.first(where: { $0.condition.caseInsensitiveCompare(grade.discogsName) == .orderedSame }) {
            return FairPrice(low: suggestion.price, high: suggestion.price,
                             source: "Discogs' suggestion for \(pressing) in \(grade.short)")
        }
        if let range = edition.fairRange {
            return FairPrice(low: range.low, high: range.high, source: "Discogs' suggestion for \(pressing), VG to NM")
        }
        if let sales = edition.sales {
            return FairPrice(low: sales.low, high: sales.high, source: "Discogs sales of \(pressing), any condition",
                             median: sales.median, lastSold: sales.lastSold)
        }
        if let lowest = edition.lowest {
            return FairPrice(low: lowest, high: lowest, source: "the cheapest copy of \(pressing) on Discogs")
        }
        return nil
    }

    /// The pressing a copy's value comes from: the one identified, else the album's most common.
    public var valuedEdition: DiscogsPricedEdition? {
        editions.first { $0.roles.contains(.identified) } ?? mostCommon
    }

    /// The album's most common pressing: the most collected edition, else the one to lead with.
    public var mostCommon: DiscogsPricedEdition? {
        editions.first { $0.roles.contains(.mostCollected) } ?? headline
    }

    /// The edition to lead with: the one identified, else the most collected.
    public var headline: DiscogsPricedEdition? {
        editions.first { $0.roles.contains(.identified) } ?? editions.first { $0.roles.contains(.mostCollected) } ?? editions.first
    }

    /// The store links' target: the album in the format, pinned to the identified edition when there is one.
    public var shoppingTarget: CDShoppingTarget {
        var links = CDShopLinks()
        links.discogsMaster = masterID
        let identified = editions.first { $0.roles.contains(.identified) }
        links.discogsRelease = identified?.releaseID
        var target = CDShoppingTarget(album: title.isEmpty ? request.album : title, artist: artist.isEmpty ? request.artist : artist,
                                      releaseGroupId: nil, edition: nil, links: links, format: request.format.shopFormat)
        target.typedBarcode = request.barcodeDigits
        return target
    }

    /// The guide as text, for the Radio DJ.
    public var summary: String {
        let ebay = [ebaySold, ebayForSale].compactMap { $0?.summary }
        guard found else {
            var text = "Discogs has nothing matching \(request.album.isEmpty ? "that" : "“\(request.album)”")\(request.artist.isEmpty ? "" : " by \(request.artist)")"
            text += request.format == .any ? "." : " on \(request.format.name)."
            text += " Check the title and artist as printed, or try another format."
            return ([text] + ebay + notes).joined(separator: "\n")
        }
        var lines: [String] = []
        var head = "Discogs: \(artist.isEmpty ? request.artist : artist) – \(title.isEmpty ? request.album : title)"
        if let masterID { head += " (master \(masterID)\(year.map { ", first released \($0)" } ?? ""))" }
        head += "."
        if versions > 0 { head += " \(versions) version\(versions == 1 ? "" : "s")\(request.format == .any ? "" : " on \(request.format.name)")." }
        if let masterForSale {
            head += " \(masterForSale) cop\(masterForSale == 1 ? "y" : "ies") of any version for sale\(masterLowest.map { ", from \(Self.text($0))" } ?? "")."
        }
        lines.append(head)
        if !editions.isEmpty {
            lines.append("Editions (prices in \(currency) are the lowest asking price now; suggested prices are Discogs' estimates by condition, from recent sales):")
            for e in editions {
                var line = "- \(e.roles.map(\.name).joined(separator: ", ")): release \(e.releaseID), \(e.details)"
                line += e.forSale > 0 ? ": \(e.forSale) for sale\(e.lowest.map { " from \(Self.text($0))" } ?? "")" : ": none for sale now"
                if let have = e.have, let want = e.want { line += "; \(have) have it, \(want) want it" }
                if let rating = e.rating, let count = e.ratingCount, count > 0 { line += String(format: "; rated %.2f/5 (%d)", rating, count) }
                if !e.suggestions.isEmpty {
                    line += ". Suggested: " + e.suggestions.map { "\($0.short) \(Self.text($0.price))" }.joined(separator: ", ")
                }
                if let s = e.sales {
                    line += ". Sold on Discogs: low \(Self.text(s.low)), median \(Self.text(s.median)), high \(Self.text(s.high))"
                    if let last = s.lastSold { line += ", last \(last.formatted(.iso8601.year().month().day()))" }
                }
                lines.append(line + ".")
            }
        }
        switch ownedOnDiscogs {
        case nil: break
        case let copies? where copies.isEmpty: lines.append("Their Discogs collection has no version of it.")
        case let copies?:
            lines.append("Their Discogs collection has \(copies.count) cop\(copies.count == 1 ? "y" : "ies"): "
                         + copies.prefix(6).map { c in
                             "\(c.title) (release \(c.releaseID), \([c.format, c.year.map(String.init) ?? "", c.catalogNumber].filter { !$0.isEmpty }.joined(separator: ", "))\(c.sameEdition ? ", this very edition" : ""))"
                         }.joined(separator: "; ") + ".")
        }
        lines += ebay
        lines += notes
        return lines.joined(separator: "\n")
    }

    /// "$48.88", "€12.00".
    public static func text(_ money: Money) -> String {
        money.amount.formatted(.currency(code: money.currency).locale(Locale(identifier: "en_US")))
    }
}

// MARK: Parsing

public enum DiscogsMarketParser {
    public struct Master: Hashable, Sendable {
        public var id: Int
        public var title: String
        public var artist: String
        public var year: Int?
        public var lowest: Double?
        public var forSale: Int
        public var thumbnail: URL?
    }

    public struct Release: Hashable, Sendable {
        public var edition: DiscogsPricedEdition
        public var masterID: Int?
        public var artist: String
        public var thumbnail: URL?
    }

    /// A master's version with how many have and want it.
    public struct Version: Hashable, Sendable {
        public var candidate: DiscogsCandidate
        public var label: String
        public var have: Int
        public var want: Int
    }

    /// An album found by a search: a master (all its editions), or a release with no master.
    public struct Hit: Hashable, Sendable, Identifiable {
        public var masterID: Int?
        public var releaseID: Int?
        public var artist: String
        public var title: String
        public var year: Int?
        public var formats: [String]
        public var label: String
        public var country: String
        public var thumbnail: URL?
        public var have: Int?

        public var id: String { masterID.map { "m\($0)" } ?? releaseID.map { "r\($0)" } ?? title }
    }

    public static func master(_ data: Data) throws -> Master {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? Int, DiscogsLink.isValid(id) else {
            throw DiscogsError.badResponse
        }
        let images = (o["images"] as? [[String: Any]] ?? [])
            .sorted { ($0["type"] as? String == "primary" ? 0 : 1) < ($1["type"] as? String == "primary" ? 0 : 1) }
        return Master(id: id, title: DiscogsParser.trimmed(o["title"] as? String ?? ""), artist: DiscogsParser.credit(o["artists"]),
                      year: year(o["year"]), lowest: number(o["lowest_price"]), forSale: o["num_for_sale"] as? Int ?? 0,
                      thumbnail: images.lazy.compactMap { DiscogsParser.image($0["uri150"]) }.first)
    }

    /// A release with its marketplace figures (`/releases/<id>?curr_abbr=…`; `lowest_price` is in that currency).
    public static func release(_ data: Data, currency: String) throws -> Release {
        let base = try DiscogsParser.parseRelease(data)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscogsError.badResponse }
        let community = o["community"] as? [String: Any] ?? [:]
        let rating = community["rating"] as? [String: Any] ?? [:]
        let format = [base.media.isEmpty ? "" : CDEditionParser.formatSummary(base.media), base.formatNotes]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let edition = DiscogsPricedEdition(
            releaseID: base.id, title: base.title, year: base.year, country: base.country, label: base.labels.first ?? "",
            catalogNumber: base.catalogNumbers.first ?? "", format: format, roles: [],
            lowest: number(o["lowest_price"]).map { money($0, currency) }, forSale: o["num_for_sale"] as? Int ?? 0,
            have: community["have"] as? Int, want: community["want"] as? Int,
            rating: number(rating["average"]), ratingCount: rating["count"] as? Int)
        return Release(edition: edition, masterID: base.masterID, artist: base.artist, thumbnail: base.thumbnail)
    }

    public static func versions(_ data: Data) throws -> (versions: [Version], pages: Int) {
        let read = try DiscogsCollectionParser.versions(data)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = o["versions"] as? [[String: Any]] else {
            throw DiscogsError.badResponse
        }
        var extra: [Int: (label: String, have: Int, want: Int)] = [:]
        for v in list {
            guard let id = v["id"] as? Int else { continue }
            let community = (v["stats"] as? [String: Any])?["community"] as? [String: Any] ?? [:]
            extra[id] = (DiscogsParser.clean(v["label"] as? String ?? ""), community["in_collection"] as? Int ?? 0, community["in_wantlist"] as? Int ?? 0)
        }
        let versions = read.candidates.map { c in
            Version(candidate: c, label: extra[c.releaseID]?.label ?? "", have: extra[c.releaseID]?.have ?? 0, want: extra[c.releaseID]?.want ?? 0)
        }
        return (versions, read.pages)
    }

    /// `/marketplace/price_suggestions/<id>`: one price per condition, best condition first.
    public static func suggestions(_ data: Data) throws -> [DiscogsConditionPrice] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscogsError.badResponse }
        let prices = o.compactMap { condition, raw -> DiscogsConditionPrice? in
            guard let p = raw as? [String: Any], let value = number(p["value"]), value > 0,
                  let currency = p["currency"] as? String, currency.count == 3 else { return nil }
            return DiscogsConditionPrice(condition: condition, price: money(value, currency))
        }
        func rank(_ c: String) -> Int { DiscogsConditionPrice.order.firstIndex(of: c) ?? DiscogsConditionPrice.order.count }
        return prices.sorted { (rank($0.condition), $0.condition) < (rank($1.condition), $1.condition) }
    }

    /// A database search of masters or releases (`type=master`/`release`), as albums.
    public static func hits(_ data: Data) throws -> [Hit] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DiscogsError.badResponse }
        return (o["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? Int, DiscogsLink.isValid(id) else { return nil }
            let full = r["title"] as? String ?? ""
            let (artist, title) = full.range(of: " - ").map { (String(full[..<$0.lowerBound]), String(full[$0.upperBound...])) } ?? ("", full)
            let isMaster = r["type"] as? String == "master"
            let master = isMaster ? id : (r["master_id"] as? Int).flatMap { DiscogsLink.isValid($0) ? $0 : nil }
            let community = r["community"] as? [String: Any] ?? [:]
            return Hit(masterID: master, releaseID: isMaster ? nil : id, artist: DiscogsParser.clean(artist),
                       title: DiscogsParser.trimmed(title), year: year(r["year"]), formats: r["format"] as? [String] ?? [],
                       label: (r["label"] as? [String])?.first.map(DiscogsParser.clean) ?? "", country: r["country"] as? String ?? "",
                       thumbnail: DiscogsParser.image(r["thumb"]), have: community["have"] as? Int)
        }
    }

    static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 ? d : nil
    }

    static func year(_ raw: Any?) -> Int? {
        let y = (raw as? Int) ?? (raw as? String).flatMap { Int($0.prefix(4)) }
        return y.flatMap { (1000...9999).contains($0) ? $0 : nil }
    }

    /// Rounded to cents (Discogs' numbers are binary floating point).
    static func money(_ value: Double, _ currency: String) -> Money {
        Money(Decimal(string: String(format: "%.2f", value)) ?? Decimal(value), currency)
    }
}

// MARK: Requests

extension DiscogsCollectionClient {
    /// Discogs' marketplace currencies (`curr_abbr`).
    public static let currencies: Set<String> = ["USD", "GBP", "EUR", "CAD", "AUD", "JPY", "CHF", "MXN", "BRL", "NZD", "SEK", "ZAR"]

    public func master(id: Int, currency: String) async throws -> DiscogsMarketParser.Master {
        guard DiscogsLink.isValid(id) else { throw DiscogsError.badResponse }
        return try DiscogsMarketParser.master(try await send("GET", path: "/masters/\(id)", query: ["curr_abbr": currency]))
    }

    public func marketRelease(id: Int, currency: String) async throws -> DiscogsMarketParser.Release {
        guard DiscogsLink.isValid(id) else { throw DiscogsError.badResponse }
        return try DiscogsMarketParser.release(try await send("GET", path: "/releases/\(id)", query: ["curr_abbr": currency]), currency: currency)
    }

    /// A master's versions with their have/want counts, in the format (nil: all), at most `pages` pages.
    public func marketVersions(masterID: Int, medium: CollectionMedium?, pages maxPages: Int = 4) async throws -> [DiscogsMarketParser.Version] {
        guard DiscogsLink.isValid(masterID) else { return [] }
        var all: [DiscogsMarketParser.Version] = []
        var page = 1, pages = 1
        repeat {
            var query = ["page": String(page), "per_page": String(Self.perPage), "sort": "released", "sort_order": "asc"]
            if let medium, let format = Self.format(medium) { query["format"] = format }
            let read = try DiscogsMarketParser.versions(try await send("GET", path: "/masters/\(masterID)/versions", query: query))
            all += read.versions
            pages = min(read.pages, maxPages)
            page += 1
        } while page <= pages
        return medium.map { m in all.filter { $0.candidate.medium == m } } ?? all
    }

    /// Needs the token, and seller settings on the account.
    public func priceSuggestions(releaseID: Int) async throws -> [DiscogsConditionPrice] {
        guard DiscogsLink.isValid(releaseID) else { return [] }
        return try DiscogsMarketParser.suggestions(try await send("GET", path: "/marketplace/price_suggestions/\(releaseID)"))
    }

    /// Albums for typed words (masters first, then releases without one), in the format.
    public func searchAlbums(_ text: String, format: PriceGuideRequest.Format) async throws -> [DiscogsMarketParser.Hit] {
        let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !words.isEmpty else { return [] }
        var query = ["type": "master", "q": words, "per_page": "30"]
        if let medium = format.medium, let name = Self.format(medium) { query["format"] = name }
        let masters = try DiscogsMarketParser.hits(try await send("GET", path: "/database/search", query: query))
        if !masters.isEmpty { return masters }
        query["type"] = "release"
        // Releases of one master are one album.
        var seen = Set<String>()
        return try DiscogsMarketParser.hits(try await send("GET", path: "/database/search", query: query)).filter { seen.insert($0.id).inserted }
    }

    /// Releases with the barcode (any format), as albums.
    public func searchBarcodeAlbums(_ barcode: String) async throws -> [DiscogsMarketParser.Hit] {
        let digits = barcode.filter { ("0"..."9").contains($0) }
        guard (6...20).contains(digits.count) else { return [] }
        return try DiscogsMarketParser.hits(try await send("GET", path: "/database/search", query: ["type": "release", "barcode": digits, "per_page": "30"]))
    }

    /// Releases for a database search (`artist`, `release_title`, `catno`, `barcode`…), any format unless given.
    func searchReleaseHits(_ params: [String: String], medium: CollectionMedium?) async throws -> [DiscogsMarketParser.Hit] {
        var query = params.merging(["type": "release", "per_page": "50"]) { a, _ in a }
        if let medium, let format = Self.format(medium) { query["format"] = format }
        return try DiscogsMarketParser.hits(try await send("GET", path: "/database/search", query: query))
    }
}

// MARK: The guide

/// How eBay pages are read: in a hidden web view (each app has one), running `EbayPrices.script`.
public struct EbayReader: Sendable {
    /// The script's JSON for a search page; throws `EbayReadError.signInNeeded` when eBay sent it to its sign-in page.
    public var page: @Sendable (URL) async throws -> String
    /// Whether the user has signed in to eBay in the app (then sold listings can be read).
    public var signedIn: @Sendable () async -> Bool
    /// Read the listings for sale too (the Mac Shop reads eBay's listings itself, so its guide only adds sales).
    public var readsForSale: Bool

    public init(page: @escaping @Sendable (URL) async throws -> String, signedIn: @escaping @Sendable () async -> Bool,
                readsForSale: Bool = true) {
        self.page = page; self.signedIn = signedIn; self.readsForSale = readsForSale
    }
}

public enum EbayReadError: Error, LocalizedError, Equatable {
    case signInNeeded

    public var errorDescription: String? { "eBay wants you to sign in to see sold listings. Sign in to eBay in Settings ▸ Shop." }
}

/// Builds price guides, one Discogs request at a time (the client keeps under the rate limit), and keeps the user's
/// Discogs collection for half an hour to say which versions they own. eBay is read through `ebay` (nil: not at all).
public actor PriceGuides {
    private let client: DiscogsCollectionClient
    private let username: String?
    nonisolated public let hasAccount: Bool
    /// The marketplace currency asked for (the user's when Discogs has it, else US dollars).
    nonisolated public let currency: String
    private var collection: (at: Date, copies: [DiscogsInstance])?
    private var loading: Task<[DiscogsInstance], Error>?
    private let now: @Sendable () -> Date
    private let ebay: EbayReader?
    private let discogsPages: DiscogsPageReader?
    public nonisolated var readsEbay: Bool { ebay != nil }

    /// `token`/`username`: the user's account (checked with `DiscogsToken.cleaned`/`DiscogsIdentity.isValidUsername`);
    /// without them the public figures only, at Discogs' lower anonymous rate.
    /// `discogsPages` reads release pages for what a pressing has sold for (`withSales`; nil: not at all).
    public init(token: String?, username: String?, currency: String, ebay: EbayReader? = nil,
                discogsPages: DiscogsPageReader? = nil,
                transport: DiscogsCollectionClient.Transport? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.ebay = ebay
        self.discogsPages = discogsPages
        let token = token.flatMap(DiscogsToken.cleaned)
        let username = username.flatMap { DiscogsIdentity.isValidUsername($0) ? $0 : nil }
        client = DiscogsCollectionClient(token: token, transport: transport, window: token == nil ? 20 : 50)
        self.username = token == nil ? nil : username
        hasAccount = token != nil && username != nil
        self.currency = DiscogsCollectionClient.currencies.contains(currency.uppercased()) ? currency.uppercased() : "USD"
        self.now = now
    }

    /// Reads the Discogs collection ahead of the first guide (it can take a while for a big one).
    public func prefetchCollection() {
        guard hasAccount else { return }
        Task { _ = try? await ownedCopies() }
    }

    /// Albums for typed words, or for a barcode (typed or scanned).
    public func search(_ text: String, format: PriceGuideRequest.Format) async throws -> [DiscogsMarketParser.Hit] {
        if let digits = PriceGuideRequest(artist: "", album: "", barcode: text).barcodeDigits,
           text.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            return try await barcodeHits(digits)
        }
        return try await client.searchAlbums(text, format: format)
    }

    /// A scanner reads a 12-digit UPC as a 13-digit EAN with a leading 0, and Discogs may list either.
    private func barcodeHits(_ digits: String) async throws -> [DiscogsMarketParser.Hit] {
        let found = try await client.searchBarcodeAlbums(digits)
        guard found.isEmpty, digits.count == 13, digits.hasPrefix("0") else { return found }
        return try await client.searchBarcodeAlbums(String(digits.dropFirst()))
    }

    /// Discogs and eBay together (eBay read while Discogs is). `readsForSale` overrides the reader's own setting
    /// (the Mac's Buy List and item pages want eBay's listings even though its Shop reads them itself).
    public func fullGuide(for request: PriceGuideRequest, readsForSale: Bool? = nil) async -> PriceGuide {
        async let ebay = ebayPrices(for: request, readsForSale: readsForSale)
        var guide = await guide(for: request)
        let (sold, forSale, notes) = await ebay
        guide.ebaySold = sold
        guide.ebayForSale = forSale
        guide.notes += notes
        return guide
    }

    /// What eBay shows for the album: recent sales when signed in, and copies for sale now. Never throws.
    public func ebayPrices(for request: PriceGuideRequest, readsForSale: Bool? = nil) async -> (sold: EbayPriceSummary?, forSale: EbayPriceSummary?, notes: [String]) {
        guard let ebay else { return (nil, nil, []) }
        let now = now()
        @Sendable func read(sold: Bool) async -> (EbayPriceSummary?, String?) {
            guard let url = EbayPrices.url(for: request, artist: request.artist, album: request.album, sold: sold) else { return (nil, nil) }
            do {
                let listings = EbayPrices.matching(EbayPrices.parse(try await ebay.page(url), now: now), album: request.album,
                                                   artist: request.artist, format: request.format)
                return (EbayPriceSummary(kind: sold ? .sold : .forSale, listings: listings, catalogNumber: request.catalogNumber, searchURL: url), nil)
            } catch EbayReadError.signInNeeded {
                return (nil, "eBay's sign-in has expired, so its sold listings weren't read: sign in to eBay again in Settings ▸ Shop.")
            } catch {
                return (nil, "Couldn't read eBay's \(sold ? "sold listings" : "listings") (\(error.localizedDescription)).")
            }
        }
        let sold = await ebay.signedIn() ? await read(sold: true) : (nil, nil)
        let forSale = readsForSale ?? ebay.readsForSale ? await read(sold: false) : (nil, nil)
        return (sold.0, forSale.0, [sold.1, forSale.1].compactMap { $0 })
    }

    /// The guide with what the pressing a copy is valued by (`PriceGuide.valuedEdition`) has sold for on Discogs, when
    /// Discogs' suggestions don't already price it (one page read). What failed goes in its notes.
    public func withSales(_ guide: PriceGuide) async -> PriceGuide {
        guard let discogsPages, let edition = guide.valuedEdition, edition.fairRange == nil, edition.sales == nil,
              let index = guide.editions.firstIndex(where: { $0.releaseID == edition.releaseID }),
              let url = DiscogsSalesHistory.url(releaseID: edition.releaseID) else { return guide }
        var guide = guide
        do {
            guide.editions[index].sales = DiscogsSalesHistory.parse(try await discogsPages.sales(url), releaseID: edition.releaseID)
        } catch {
            guide.notes.append("Couldn't read what this pressing sold for on Discogs (\(error.localizedDescription)).")
        }
        return guide
    }

    /// A quick guide to one edition, for valuing many copies in a row: with its Discogs release known, only that
    /// release (and its suggested prices with an account: two requests); otherwise the whole Discogs guide. No eBay.
    public func editionGuide(for request: PriceGuideRequest) async -> PriceGuide {
        guard let releaseID = request.releaseID else { return await guide(for: request) }
        var guide = PriceGuide(request: request)
        guide.currency = currency
        do {
            let release = try await client.marketRelease(id: releaseID, currency: currency)
            var edition = release.edition
            edition.roles = [.identified]
            if hasAccount { edition.suggestions = (try? await client.priceSuggestions(releaseID: releaseID)) ?? [] }
            guide.editions = [edition]
            guide.masterID = release.masterID
            guide.title = edition.title
            guide.artist = release.artist
            guide.thumbnail = release.thumbnail
        } catch DiscogsError.busy {
            guide.notes.append("Discogs is busy (too many requests); try again in a minute.")
        } catch {
            guide.notes.append("Couldn't read the edition from Discogs (\(error.localizedDescription)).")
        }
        return guide
    }

    /// Discogs' guide for an album. Never throws: what couldn't be read is in its `notes`.
    public func guide(for request: PriceGuideRequest) async -> PriceGuide {
        var guide = PriceGuide(request: request)
        guide.currency = currency
        let medium = request.format.medium
        func note(_ error: Error, _ what: String) {
            let message = switch error {
            case DiscogsError.busy: "Discogs is busy (too many requests): \(what) wasn't read; try again in a minute."
            case DiscogsError.unauthorized: "Discogs didn't accept the access token: \(what) wasn't read."
            default: "Couldn't read \(what) from Discogs (\(error.localizedDescription))."
            }
            if !guide.notes.contains(message) { guide.notes.append(message) }
        }

        // 1. The edition, when what's printed on it pins it down.
        var identified: DiscogsMarketParser.Release?
        var identifiedID = request.releaseID
        if identifiedID == nil {
            do { identifiedID = try await findEdition(request) } catch { note(error, "the edition search") }
        }
        if let id = identifiedID {
            do { identified = try await client.marketRelease(id: id, currency: currency) } catch { note(error, "the edition") }
        }

        // 2. The album: its master, from the edition or by name.
        var masterID = request.masterID ?? identified?.masterID
        if masterID == nil, identified == nil, !request.album.isEmpty {
            do {
                let hits = try await client.searchReleaseHits(nameQuery(request), medium: medium)
                    .filter { DiscogsReleaseMatcher.isSameAlbum($0.title, request.album) && ShopOwnership.sameArtist($0.artist, request.artist) }
                let masters = Dictionary(grouping: hits.compactMap(\.masterID), by: { $0 }).mapValues(\.count)
                masterID = masters.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
                if masterID == nil, let release = hits.first?.releaseID {
                    identified = try await client.marketRelease(id: release, currency: currency)
                }
            } catch { note(error, "the album search") }
        }

        var versions: [DiscogsMarketParser.Version] = []
        if let masterID {
            do {
                let master = try await client.master(id: masterID, currency: currency)
                guide.masterID = master.id
                guide.title = master.title
                guide.artist = master.artist
                guide.year = master.year
                guide.thumbnail = master.thumbnail
                guide.masterLowest = master.lowest.map { DiscogsMarketParser.money($0, currency) }
                guide.masterForSale = master.forSale
            } catch { note(error, "the album") }
            do {
                versions = try await client.marketVersions(masterID: masterID, medium: medium)
                guide.versions = versions.count
            } catch { note(error, "the album's editions") }
        }
        if let identified {
            if guide.title.isEmpty { guide.title = identified.edition.title }
            if guide.artist.isEmpty { guide.artist = identified.artist }
            if guide.thumbnail == nil { guide.thumbnail = identified.thumbnail }
        }

        // 3. The editions to price: this one, the most collected, the original (else the latest).
        var picks: [(Int, DiscogsPricedEdition.Role)] = []
        if let identified { picks.append((identified.edition.releaseID, .identified)) }
        if let common = versions.max(by: { ($0.have, -$0.candidate.releaseID) < ($1.have, -$1.candidate.releaseID) }) {
            picks.append((common.candidate.releaseID, .mostCollected))
        }
        let dated = versions.filter { $0.candidate.year != nil }
        if let first = dated.map({ $0.candidate.year! }).min(),
           let original = dated.filter({ $0.candidate.year == first }).max(by: { $0.have < $1.have }) {
            picks.append((original.candidate.releaseID, .original))
        }
        if Set(picks.map(\.0)).count < 3, let last = dated.map({ $0.candidate.year! }).max(),
           let newest = dated.filter({ $0.candidate.year == last }).max(by: { $0.have < $1.have }) {
            picks.append((newest.candidate.releaseID, .newest))
        }
        var order: [Int] = []
        var roles: [Int: [DiscogsPricedEdition.Role]] = [:]
        for (id, role) in picks {
            if roles[id] == nil { order.append(id) }
            roles[id, default: []].append(role)
        }
        var suggestionsFailed = false
        for id in order.prefix(3) {
            var edition: DiscogsPricedEdition
            if let identified, identified.edition.releaseID == id {
                edition = identified.edition
            } else {
                do { edition = try await client.marketRelease(id: id, currency: currency).edition } catch { note(error, "an edition's prices"); continue }
            }
            edition.roles = roles[id] ?? []
            if hasAccount, !suggestionsFailed {
                do {
                    edition.suggestions = try await client.priceSuggestions(releaseID: id)
                } catch {
                    suggestionsFailed = true
                    guide.notes.append("Discogs gave no suggested prices by condition (they need seller settings filled in on discogs.com).")
                }
            }
            guide.editions.append(edition)
        }

        // 4. Copies they already have on Discogs.
        if hasAccount, guide.found {
            do {
                let editionIDs = Set(versions.map(\.candidate.releaseID) + guide.editions.map(\.releaseID))
                let identifiedRelease = identified?.edition.releaseID
                guide.ownedOnDiscogs = try await ownedCopies().filter { copy in
                    if let master = guide.masterID, copy.masterID == master { return true }
                    if editionIDs.contains(copy.releaseID) { return true }
                    return copy.masterID == nil && DiscogsReleaseMatcher.isSameAlbum(copy.title, guide.title.isEmpty ? request.album : guide.title)
                        && ShopOwnership.sameArtist(copy.artist, guide.artist.isEmpty ? request.artist : guide.artist)
                }.map {
                    DiscogsOwnedCopy(instanceID: $0.instanceID, releaseID: $0.releaseID, title: $0.title, format: $0.formatDetail,
                                     year: $0.year, catalogNumber: $0.catalogNumber, sameEdition: $0.releaseID == identifiedRelease)
                }
            } catch { note(error, "your Discogs collection") }
        }
        return guide
    }

    /// The release the barcode or catalog number names, among those of the album.
    private func findEdition(_ request: PriceGuideRequest) async throws -> Int? {
        let medium = request.format.medium
        var hits: [DiscogsMarketParser.Hit] = []
        if let barcode = request.barcodeDigits {
            // Discogs matches barcodes loosely: keep the album's.
            hits = try await barcodeHits(barcode)
        }
        if hits.isEmpty, !request.catalogNumber.isEmpty {
            var params = ["catno": String(request.catalogNumber.prefix(60))]
            if !request.artist.isEmpty { params["artist"] = String(request.artist.prefix(100)) }
            hits = try await client.searchReleaseHits(params, medium: medium)
        }
        let album = request.album
        hits = hits.filter { album.isEmpty || DiscogsReleaseMatcher.isSameAlbum($0.title, album) }
        guard !hits.isEmpty else { return nil }
        let country = request.country.isEmpty ? [] : DiscogsReleaseMatcher.discogsCountries(request.country)
        return hits.max { score($0, request, country) < score($1, request, country) }?.releaseID
    }

    private func score(_ hit: DiscogsMarketParser.Hit, _ request: PriceGuideRequest, _ countries: Set<String>) -> Int {
        var s = 0
        if let medium = request.format.medium, CollectionMedium(musicBrainzFormats: hit.formats) == medium { s += 4 }
        if let year = request.year, hit.year == year { s += 2 }
        if !request.label.isEmpty, DiscogsReleaseMatcher.normalized(hit.label) == DiscogsReleaseMatcher.normalized(request.label) { s += 1 }
        if countries.contains(hit.country.lowercased()) { s += 2 }
        return s
    }

    private func nameQuery(_ request: PriceGuideRequest) -> [String: String] {
        var params = ["release_title": String(request.album.prefix(200))]
        if !request.artist.isEmpty, request.artist.lowercased() != "various artists" { params["artist"] = String(request.artist.prefix(200)) }
        return params
    }

    private func ownedCopies() async throws -> [DiscogsInstance] {
        if let collection, now().timeIntervalSince(collection.at) < 30 * 60 { return collection.copies }
        guard let username else { return [] }
        if let loading { return try await loading.value }
        let client = client
        let task = Task { try await client.collection(username: username) }
        loading = task
        defer { loading = nil }
        let copies = try await task.value
        collection = (now(), copies)
        return copies
    }
}
