import Foundation

// eBay in the Shop's price guide: what copies of an album are listed for now (anyone can see that), and, once the
// user has signed in to eBay in the app's own web view (opt-in; the app never sees the password, only eBay's
// cookies in the web view's data store), what copies actually sold for recently. eBay sends the Sold Items search to
// its sign-in page otherwise. Pages are read like the Mac Shop reads eBay: in a hidden web view, one at a time, when
// the user asks; `EbayPrices.script` runs in the page and hands back each listing's text as JSON, so the parsing
// here needs no HTML parser (the phone has none).

/// One listing on an eBay search page, sold or for sale.
public struct EbayListing: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var price: Money
    /// nil: the listing doesn't say.
    public var isNew: Bool?
    public var isAuction: Bool
    /// When it sold (sold searches only).
    public var soldOn: Date?

    public var url: URL? { URL(string: "https://www.ebay.com/itm/\(id)") }
}

/// Prices of several copies: the cheapest, the middle half and the dearest.
public struct PriceSpread: Hashable, Sendable {
    public var count: Int
    public var low: Money
    public var typicalLow: Money
    public var median: Money
    public var typicalHigh: Money
    public var high: Money

    /// nil for no prices; all in the first price's currency (others are left out).
    public init?(_ prices: [Money]) {
        guard let currency = prices.first?.currency else { return nil }
        let sorted = prices.filter { $0.currency == currency }.sorted()
        guard !sorted.isEmpty else { return nil }
        func at(_ q: Double) -> Money {
            let position = q * Double(sorted.count - 1)
            let i = Int(position.rounded(.down)), j = min(i + 1, sorted.count - 1)
            let f = Decimal(position - Double(i))
            let value = sorted[i].amount + (sorted[j].amount - sorted[i].amount) * f
            var rounded = Decimal()
            var v = value
            NSDecimalRound(&rounded, &v, 2, .plain)
            return Money(rounded, currency)
        }
        count = sorted.count
        low = sorted[0]; high = sorted[sorted.count - 1]
        typicalLow = at(0.25); median = at(0.5); typicalHigh = at(0.75)
    }

    /// "$18–$44 (median $30, 12 copies)".
    public var text: String {
        let range = typicalLow == typicalHigh ? PriceGuide.text(median) : "\(PriceGuide.text(typicalLow))–\(PriceGuide.text(typicalHigh))"
        return "\(range) (median \(PriceGuide.text(median)), \(count) cop\(count == 1 ? "y" : "ies"), \(PriceGuide.text(low)) to \(PriceGuide.text(high)))"
    }
}

/// What eBay shows for the album: listings for sale now, and (signed in) recent sales.
public struct EbayPriceSummary: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case forSale, sold }

    public var kind: Kind
    /// Listings that are the album in the format (others on the page are left out).
    public var listings: [EbayListing]
    public var used: PriceSpread?
    public var new: PriceSpread?
    /// Copies whose title names the identified edition's catalog number.
    public var edition: PriceSpread?
    /// Auctions among them (for sale: the price is the bid so far).
    public var auctions: Int
    /// The search, to open in a browser.
    public var searchURL: URL

    public init(kind: Kind, listings: [EbayListing], catalogNumber: String, searchURL: URL) {
        self.kind = kind
        self.searchURL = searchURL
        self.listings = listings
        // A running auction's price is only the bid so far.
        let priced = kind == .sold ? listings : listings.filter { !$0.isAuction }
        used = PriceSpread(priced.filter { $0.isNew == false }.map(\.price))
        new = PriceSpread(priced.filter { $0.isNew == true }.map(\.price))
        let code = CDOfferMatcher.compact(catalogNumber)
        edition = code.count >= 4 ? PriceSpread(priced.filter { CDOfferMatcher.compact($0.title).contains(code) }.map(\.price)) : nil
        auctions = listings.filter(\.isAuction).count
    }

    public var isEmpty: Bool { listings.isEmpty }

    /// For the Radio DJ.
    public var summary: String {
        let what = kind == .sold ? "eBay sold listings (recent sales, what buyers actually paid, before shipping)"
            : "eBay listings for sale now (asking prices, before shipping; auctions left out)"
        guard !isEmpty else { return "\(what): none found for this album." }
        var parts = ["\(what): \(listings.count) found."]
        if let used { parts.append("Used: \(used.text).") }
        if let new { parts.append("New/sealed: \(new.text).") }
        if let edition { parts.append("Titles naming this edition's catalog number: \(edition.text).") }
        if kind == .forSale, auctions > 0 { parts.append("\(auctions) running auction\(auctions == 1 ? "" : "s").") }
        if kind == .sold {
            let dates = listings.compactMap(\.soldOn)
            if let first = dates.min(), let last = dates.max() {
                parts.append("Sold between \(PurchaseDay(first).string) and \(PurchaseDay(last).string).")
            }
        }
        return parts.joined(separator: " ")
    }
}

public enum EbayPrices {
    /// Runs in the search page (`callAsyncJavaScript`): each listing card's id, title, price and lines of text, as
    /// JSON, up to "Results matching fewer words" (those don't have everything searched for).
    public static let script = """
    const stop = [...document.querySelectorAll('h2, h3, span, div, li')].find(e => e.childElementCount < 4 && /Results matching fewer words/i.test(e.textContent || ''));
    const seen = new Set(); const out = [];
    for (const c of document.querySelectorAll('li.s-card')) {
      if (stop && (stop.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      const id = c.getAttribute('data-listingid') || '';
      if (!id || id === '123456' || seen.has(id)) continue; seen.add(id);
      const t = c.querySelector('.s-card__title .primary') || c.querySelector('.s-card__title');
      const title = (t ? t.textContent : '').replace(/Opens in a new window or tab/g, '').trim();
      const p = c.querySelector('.s-card__price');
      out.push({id, title, price: p ? p.textContent.trim() : '',
        subtitles: [...c.querySelectorAll('.s-card__subtitle, .s-card__caption')].map(e => e.textContent.trim()),
        rows: [...c.querySelectorAll('.s-card__attribute-row')].map(e => e.textContent.trim())});
      if (out.length >= 240) break;
    }
    return JSON.stringify({stopFound: !!stop, items: out});
    """

    /// The search page for the album: listings for sale, or recent sales; the format's category (records, CDs; any:
    /// all of Music), the most listings per page.
    public static func url(for request: PriceGuideRequest, artist: String, album: String, sold: Bool) -> URL? {
        let artist = artist.lowercased() == "various artists" ? "" : artist
        let words = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.ebay.com/sch/i.html")
        let category = request.format == .any ? "11233" : request.format.shopFormat.eBayCategory
        c?.queryItems = [URLQueryItem(name: "_nkw", value: String(words.prefix(150))), URLQueryItem(name: "_sacat", value: category),
                         URLQueryItem(name: "_ipg", value: "240")]
            + (sold ? [URLQueryItem(name: "LH_Sold", value: "1"), URLQueryItem(name: "LH_Complete", value: "1")] : [])
        return c?.url
    }

    /// The listings in what `script` returned (untrusted: it's the page's text).
    public static func parse(_ json: String, now: Date = Date()) -> [EbayListing] {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return [] }
        return items.prefix(240).compactMap { item in
            guard let id = item["id"] as? String, (6...20).contains(id.count), id.allSatisfy({ ("0"..."9").contains($0) }),
                  var title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title != "Shop on eBay",
                  let price = (item["price"] as? String).flatMap({ Money.parse($0) }), price.amount > 0 else { return nil }
            for prefix in ["New Listing", "NEW LISTING"] where title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            let subtitles = (item["subtitles"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            let rows = (item["rows"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            let condition = subtitles.first { s in CDShopConditions.eBay.contains { s.hasPrefix($0) } }
            let isNew: Bool? = condition.map { $0.hasPrefix("Brand New") || $0.hasPrefix("New") }
            let isAuction = rows.contains { $0.range(of: #"^\d+ bids?\b"#, options: .regularExpression) != nil }
            let soldOn = (subtitles + rows).lazy.compactMap { soldDate($0, now: now) }.first
            return EbayListing(id: id, title: String(title.prefix(300)), price: price, isNew: isNew, isAuction: isAuction, soldOn: soldOn)
        }
    }

    /// "Sold  Oct 12, 2026" → that day.
    static func soldDate(_ text: String, now: Date) -> Date? {
        guard let r = text.range(of: #"Sold\s+([A-Z][a-z]{2} \d{1,2}, \d{4})"#, options: .regularExpression) else { return nil }
        let day = text[r].dropFirst(4).trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: day).flatMap { $0 <= now.addingTimeInterval(86_400) ? $0 : nil }
    }

    /// The listings that are the album in the format: titles naming it, not lots or several albums, not another format.
    public static func matching(_ listings: [EbayListing], album: String, artist: String, format: PriceGuideRequest.Format) -> [EbayListing] {
        var seen = Set<String>()
        return listings.filter { listing in
            guard seen.insert(listing.id).inserted else { return false }
            let text = " " + listing.title.lowercased() + " "
            if text.range(of: #"\blots?\b|\bbundle\b|\bcollection of\b"#, options: .regularExpression) != nil { return false }
            if format != .any, format.shopFormat.isOtherFormat(listing.title) { return false }
            guard CDOfferMatcher.names(listing.title, album: album) else { return false }
            // Another album named alongside ("Kind Of Blue And Sketches Of Spain", "Blue Train / Kind of Blue").
            let own = " " + (album + " " + artist).lowercased() + " "
            let joins = [" and ", " & ", " + "].filter { text.contains($0) && !own.contains($0) }
            if !joins.isEmpty || listing.title.contains(" / ") { return false }
            return artist.isEmpty || artist.lowercased() == "various artists" || CDOfferMatcher.names(listing.title, album: artist, fraction: 0.5)
        }
    }
}

/// Condition words eBay puts under a listing's title.
enum CDShopConditions {
    static let eBay = ["Brand New", "New (Other)", "New", "Pre-Owned", "Like New", "Very Good", "Good", "Acceptable", "Open Box",
                       "Refurbished", "Used"]
}
