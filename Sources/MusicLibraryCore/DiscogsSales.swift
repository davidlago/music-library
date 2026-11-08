import Foundation

// What a pressing has sold for on Discogs: the Low, Median and High of its sales and the last sale's date, the
// Statistics box on its release page. The API doesn't give them (only what's for sale now), so they're read from the
// page, which embeds its data as JSON (`<script id="dsdata">`, Apollo's cache: `Release:{"discogsId":<id>}` →
// `statistics` with `min`, `median`, `max` and `lastSaleDate`). The page sits behind Cloudflare, so each app reads it
// in a hidden web view (`CDShopPageLoader.discogsReader`) running `DiscogsSalesHistory.script`; the parser is pure.

/// A pressing's sales on Discogs.
public struct DiscogsSalesHistory: Hashable, Sendable {
    public var releaseID: Int
    public var low: Money
    public var median: Money
    public var high: Money
    public var lastSold: Date?

    public init(releaseID: Int, low: Money, median: Money, high: Money, lastSold: Date? = nil) {
        self.releaseID = releaseID; self.low = low; self.median = median; self.high = high; self.lastSold = lastSold
    }

    /// The release page, where the statistics are.
    public static func url(releaseID: Int) -> URL? {
        guard DiscogsLink.isValid(releaseID) else { return nil }
        return URL(string: "https://www.discogs.com/release/\(releaseID)")
    }

    /// Run in the release page (a function body, for `callAsyncJavaScript`): the page's releases that carry
    /// statistics, as JSON (`{"currency":…,"releases":[{"discogsId":…,"statistics":…}]}`), or "" without its data.
    public static let script = """
    const el = document.getElementById('dsdata');
    if (!el) return '';
    let d;
    try { d = JSON.parse(el.textContent); } catch (e) { return ''; }
    const releases = [];
    for (const [k, v] of Object.entries(d.data || {})) {
      if (k.startsWith('Release:') && v && typeof v === 'object' && 'statistics' in v)
        releases.push({discogsId: v.discogsId, statistics: v.statistics, lowestForSalePrice: v.lowestForSalePrice ?? null});
    }
    return JSON.stringify({currency: d.currency ?? null, releases});
    """

    /// The release's sales from the script's output; nil when it has none (never sold) or the text doesn't read.
    /// Untrusted: amounts must be sensible money, the low no more than the median, the median no more than the high.
    public static func parse(_ text: String, releaseID: Int) -> DiscogsSalesHistory? {
        guard text.utf8.count <= 1_000_000,
              let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let releases = root["releases"] as? [[String: Any]],
              let release = releases.first(where: { ($0["discogsId"] as? NSNumber)?.intValue == releaseID }),
              let stats = release["statistics"] as? [String: Any],
              let low = price(stats["min"]), let median = price(stats["median"]), let high = price(stats["max"]),
              low.currency == median.currency, median.currency == high.currency,
              low.amount <= median.amount, median.amount <= high.amount else { return nil }
        let lastSold = (stats["lastSaleDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return DiscogsSalesHistory(releaseID: releaseID, low: low, median: median, high: high, lastSold: lastSold)
    }

    /// A `Price`: the amount converted to the visitor's currency when the page converted it, else as sold.
    private static func price(_ value: Any?) -> Money? {
        guard let price = value as? [String: Any] else { return nil }
        let converted = price.first { $0.key.hasPrefix("converted(") }?.value as? [String: Any]
        for p in [converted, price].compactMap({ $0 }) {
            if let amount = (p["amount"] as? NSNumber)?.doubleValue, amount.isFinite, let currency = p["currency"] as? String,
               let money = WantedAlbum.validMoney(DiscogsMarketParser.money(amount, currency.uppercased())) {
                return money
            }
        }
        return nil
    }
}

/// How Discogs' release pages are read: in a hidden web view (each app has one), running `DiscogsSalesHistory.script`.
public struct DiscogsPageReader: Sendable {
    /// The script's output for a release page.
    public var sales: @Sendable (URL) async throws -> String

    public init(sales: @escaping @Sendable (URL) async throws -> String) { self.sales = sales }
}
