// XMLDocument (used to parse tidied HTML) is macOS only, and so is reading the stores' pages.
#if os(macOS)
import Foundation

/// Reads marketplace pages (as a browser engine rendered them) into offers. Like the catalog's, pages are cut
/// into one fragment per listing before they're parsed. Links and images are kept only when they're https on the
/// store's own site; listings without a price or a link are dropped.
public enum CDShopParser {
    public static func parse(_ html: String, request: CDShopRequest) -> [CDOffer] {
        let match: CDOffer.Match = switch request.kind {
        case .edition: .edition
        case .album: .album
        case .keywords: .possible
        }
        switch request.shop {
        case .discogs: return parseDiscogs(html, match: match)
        case .ebay: return parseEBay(html, match: match)
        case .cdandlp: return parseCDandLP(html, match: match)
        case .alibris: return parseAlibris(html, match: match)
        default: return []
        }
    }

    /// Whether the page is a bot check rather than the page asked for.
    public static func isChallenge(title: String) -> Bool {
        ["Just a moment", "Attention Required", "Pardon Our Interruption", "Security Measure", "Robot Check"]
            .contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// One fragment per occurrence of `marker` (an opening tag), each ending where the next starts or at `end`.
    static func fragments(_ html: String, marker: String, end: [String] = []) -> [String] {
        var parts = html.components(separatedBy: marker).dropFirst().map { marker + $0 }
        if let last = parts.indices.last {
            for e in end {
                if let r = parts[last].range(of: e) { parts[last] = String(parts[last][..<r.lowerBound]) }
            }
        }
        return parts
    }

    static func link(_ href: String?, shop: CDShop, base: String) -> URL? {
        guard let href, !href.isEmpty, let url = URL(string: href, relativeTo: URL(string: base))?.absoluteURL,
              shop.owns(url) else { return nil }
        return url
    }

    // MARK: Discogs

    /// The marketplace list (`/shop/list`, for a release or a master): one `<article class="msr-listing-card">`
    /// per item. It's drawn by script and only the rows in view are in the page, so the app renders it tall.
    static func parseDiscogs(_ html: String, match: CDOffer.Match) -> [CDOffer] {
        fragments(html, marker: "<article class=\"msr-listing-card").compactMap { fragment in
            guard let doc = try? HTMLFragment(fragment) else { return nil }
            let base = "https://www.discogs.com/"
            guard let href = doc.first("//a[contains(@href,'/shop/item/') or contains(@href,'/sell/item/')]")?.attr("href"),
                  let url = link(href, shop: .discogs, base: base),
                  let id = url.pathComponents.last.flatMap({ Int($0) }),
                  let price = doc.first("//span[contains(@class,'msr-listing-card-price')]").flatMap({ Money.parse($0.text) }) else { return nil }
            func text(_ cls: String) -> String { doc.first("//*[contains(concat(' ',normalize-space(@class),' '),' \(cls) ')]")?.text ?? "" }
            let title = doc.first("//a[contains(@class,'hifi-title-link')]")?.text ?? ""
            let artist = text("msr-listing-card-artist-row")
            let format = text("msr-listing-card-entity-type")
            func bullets(_ cls: String) -> [String] {
                text(cls).components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            // "1997 • US", "Capitol Records • CDP 7243 8 55229 2 5"
            let edition = ([text("msr-listing-card-catalog-description")] + bullets("msr-listing-card-year")
                           + [bullets("msr-listing-card-labels").joined(separator: " ")])
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let grades = doc.all("//span[contains(@class,'hifi-grade-chip-label')]").map(\.text)
            var condition = ""
            if let media = grades.first { condition = media }
            if grades.count > 1 { condition += " / sleeve \(grades[1])" }
            let shippingText = text("msr-listing-card-shipping")
            let shipping = Money.parse(shippingText)
            let total = doc.first("//span[contains(@class,'msr-listing-card-total-amount')]").flatMap { Money.parse($0.text) }
            let sellerLink = doc.first("//div[contains(@class,'msr-listing-card-seller')]/a")
            let image = doc.first("//a[contains(@class,'msr-listing-card-image')]//img")?.attr("src")
            return CDOffer(
                id: "discogs-\(id)", shop: .discogs, title: [artist, title].filter { !$0.isEmpty }.joined(separator: " – ") + (format.isEmpty ? "" : " (\(format))"),
                edition: edition, condition: grades.first.map { $0 == "Mint" ? .new : .used } ?? .unknown,
                conditionText: condition, notes: text("msr-listing-card-description"), price: price,
                shipping: shipping, shippingNote: shipping == nil ? (shippingText.isEmpty ? "" : shippingText) : "",
                quotedTotal: total, seller: sellerLink?.text ?? "", sellerRating: text("msr-listing-card-seller-rating"),
                shipsFrom: text("msr-listing-card-ships-from-country"), url: url,
                imageURL: link(image, shop: .discogs, base: base), match: match)
        }
    }

    // MARK: eBay

    static let eBayConditions = ["Brand New", "New (Other)", "New", "Pre-Owned", "Like New", "Very Good", "Good",
                                 "Acceptable", "Open Box", "Refurbished", "Used"]

    /// Search results: one `<li class="s-card…">` per listing (eBay repeats some, hidden, for its carousel).
    static func parseEBay(_ html: String, match: CDOffer.Match) -> [CDOffer] {
        // Results past "matching fewer words" don't have everything searched for.
        var page = html
        if let r = page.range(of: "Results matching fewer words") { page = String(page[..<r.lowerBound]) }
        var seen = Set<String>()
        return fragments(page, marker: "<li class=\"s-card", end: ["<footer"]).compactMap { fragment in
            let fragment = fragment.components(separatedBy: "</li>").first ?? fragment
            guard let doc = try? HTMLFragment(fragment) else { return nil }
            let base = "https://www.ebay.com/"
            guard let href = doc.first("//a[contains(@href,'/itm/')]")?.attr("href"),
                  let url = link(href, shop: .ebay, base: base),
                  let itemId = url.pathComponents.last(where: { Int($0) != nil }),
                  itemId != "123456", seen.insert(itemId).inserted,
                  let price = doc.first("//span[contains(@class,'s-card__price')]").flatMap({ Money.parse($0.text) }) else { return nil }
            var title = doc.first("//div[contains(@class,'s-card__title')]//span[contains(@class,'primary')]")?.text
                ?? doc.first("//div[contains(@class,'s-card__title')]")?.text ?? ""
            for prefix in ["New Listing", "NEW LISTING"] where title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !title.isEmpty, title != "Shop on eBay" else { return nil }
            let subtitles = doc.all("//div[contains(@class,'s-card__subtitle')]//span").map(\.text)
            let conditionText = subtitles.first { s in eBayConditions.contains { s.hasPrefix($0) } } ?? ""
            let condition: CDOffer.Condition = conditionText.isEmpty ? .unknown
                : (conditionText.hasPrefix("Brand New") || conditionText.hasPrefix("New") ? .new : .used)
            var shipping: Money?, shippingNote = "", shipsFrom = "", saleFormat: [String] = [], seller = "", rating = ""
            for row in doc.all("//div[contains(@class,'s-card__attribute-row')]").map(\.text) {
                let lower = row.lowercased()
                if lower.contains("delivery") || lower.contains("shipping") {
                    if lower.hasPrefix("free") {
                        shipping = Money(0, price.currency)
                    } else if let m = Money.parse(row) {
                        shipping = m
                        if lower.contains("estimate") { shippingNote = "estimate" }
                    }
                } else if row.hasPrefix("Located in ") {
                    shipsFrom = String(row.dropFirst("Located in ".count))
                } else if row == "Buy It Now" || row.hasPrefix("or Best Offer") || lower.contains(" bid") {
                    saleFormat.append(row.components(separatedBy: " · ").first ?? row)
                } else if let r = row.range(of: #"[\d.]+% positive.*$"#, options: .regularExpression) {
                    seller = row[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                    rating = String(row[r])
                }
            }
            let image = doc.first("//img[contains(@class,'s-card__image')]")
            let imageURL = link(image?.attr("src"), shop: .ebay, base: base).flatMap { $0.path.hasSuffix(".png") ? nil : $0 }
            return CDOffer(id: "ebay-\(itemId)", shop: .ebay, title: title, condition: condition, conditionText: conditionText,
                           price: price, shipping: shipping, shippingNote: shippingNote, seller: seller, sellerRating: rating,
                           shipsFrom: shipsFrom, saleFormat: saleFormat.joined(separator: " "),
                           url: URL(string: "https://www.ebay.com/itm/\(itemId)") ?? url, imageURL: imageURL, match: match)
        }
    }

    // MARK: CDandLP

    /// Search results: one `<div class="… div_item_listing …">` per item. Prices are in euros; shipping is worked
    /// out in the cart.
    static func parseCDandLP(_ html: String, match: CDOffer.Match) -> [CDOffer] {
        fragments(html, marker: "<div class=\"twelve large-20 columns div_item_listing", end: ["paginationBtm", "<footer"]).compactMap { fragment in
            guard let doc = try? HTMLFragment(fragment) else { return nil }
            let base = "https://www.cdandlp.com/"
            guard let titleLink = doc.first("//a[contains(@class,'listingTitle')]"),
                  let url = link(titleLink.attr("href"), shop: .cdandlp, base: base),
                  let id = url.pathComponents.last(where: { $0.hasPrefix("r") && Int($0.dropFirst()) != nil }),
                  let price = doc.first("//span[contains(@class,'listingPrice1')]").flatMap({ Money.parse($0.text, defaultCurrency: "EUR") }) else { return nil }
            let format = doc.first("//div[contains(@class,'listingMedia_responsive') and contains(@class,'show-for-medium-up')]")?.text ?? ""
            guard format.uppercased().hasPrefix("CD") else { return nil }
            let lines = titleLink.textLines
            let title = lines.count > 1 ? "\(lines[0]) – \(lines.dropFirst().joined(separator: " "))" : titleLink.text
            let grading = doc.first("//div[contains(@class,'listingGrading')]//span[@title]")?.attr("title") ?? ""
            let media = grading.components(separatedBy: "Media condition : ").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            let cover = grading.components(separatedBy: " / ").first?.replacingOccurrences(of: "Cover condition : ", with: "") ?? ""
            let seller = doc.first("//div[contains(@class,'listingSeller')]/a")
            let country = doc.first("//span[contains(@class,'paysseller')]")?.text.trimmingCharacters(in: CharacterSet(charactersIn: "() ")) ?? ""
            let image = doc.first("//div[contains(@class,'listingImg_responsive')]//img")?.attr("src")
            // "Parlophone - 7243 8 55229 2 5 - Europe - 1997", with "-" for what's unknown.
            let edition = (doc.first("//span[contains(@class,'listingCar')]")?.text ?? "")
                .components(separatedBy: " -").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let isNew = media.hasPrefix("M ") || media.hasPrefix("M (") || media == "M"
            return CDOffer(id: "cdandlp-\(id)", shop: .cdandlp, title: title.capitalizedWords + " (\(format))", edition: edition,
                           condition: media.isEmpty ? .unknown : (isNew ? .new : .used),
                           conditionText: [media, cover.isEmpty ? "" : "cover \(cover)"].filter { !$0.isEmpty }.joined(separator: " / "),
                           price: price, shippingNote: "+ shipping", seller: seller?.text ?? "", shipsFrom: country,
                           url: url, imageURL: image.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil },
                           match: match)
        }
    }

    // MARK: Alibris

    /// Music search results: one work per `<div class="work …">`, with its lowest used and new prices.
    static func parseAlibris(_ html: String, match: CDOffer.Match) -> [CDOffer] {
        fragments(html, marker: "<div class=\"work", end: ["class=\"pagination", "<footer", "id=\"footer"]).flatMap { fragment -> [CDOffer] in
            guard let doc = try? HTMLFragment(fragment) else { return [] }
            let base = "https://www.alibris.com/"
            guard let titleLink = doc.first("//h2//a"), let workURL = link(titleLink.attr("href"), shop: .alibris, base: base),
                  let workId = workURL.pathComponents.last, Int(workId) != nil else { return [] }
            let title = titleLink.text
            // "[LP]", "[Cassette]": not a CD. Alibris doesn't mark CDs, but says so for the recommended copy.
            if let r = title.range(of: #"\[[^\]]*\]"#, options: .regularExpression) {
                let tag = title[r].lowercased()
                if !tag.contains("cd") { return [] }
            }
            let artist = doc.first("//p/a[contains(@href,'/artist/')]")?.text ?? ""
            let image = doc.first("//img")?.attr("src")
            let recommended = doc.first("//div[contains(@class,'callout-inner')]/p")?.text ?? ""
            if !recommended.isEmpty, !recommended.contains("CD") { return [] }
            var offers: [CDOffer] = []
            func add(_ kind: String, condition: CDOffer.Condition, priceNode: HTMLNode?, href: String?) {
                guard let priceNode, let price = Money.parse(priceNode.text),
                      let url = link(href, shop: .alibris, base: base) else { return }
                offers.append(CDOffer(id: "alibris-\(workId)-\(kind)", shop: .alibris,
                                      title: [artist, title].filter { !$0.isEmpty }.joined(separator: " – "),
                                      condition: condition,
                                      conditionText: condition == .new ? "New" : "Used or new", notes: recommended.isEmpty ? "" : "Recommended copy: \(recommended)", price: price,
                                      shippingNote: "+ shipping", seller: "Several sellers", saleFormat: "from",
                                      url: url, imageURL: link(image, shop: .alibris, base: base), match: match))
            }
            let all = doc.first("//a[contains(@class,'button')]")
            add("all", condition: .unknown, priceNode: all?.first(".//span[@class='price']"), href: all?.attr("href"))
            let new = doc.first("//li[contains(@class,'price-row')]/a")
            if let new, new.text.hasPrefix("New") {
                add("new", condition: .new, priceNode: new.first(".//span[@class='price']"), href: new.attr("href"))
            }
            return offers
        }
    }
}

extension String {
    /// "radiohead – ok computer" → "Radiohead – Ok Computer" (CDandLP lowercases its titles).
    var capitalizedWords: String {
        split(separator: " ", omittingEmptySubsequences: false).map { w in
            guard let first = w.first, first.isLowercase else { return String(w) }
            return first.uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
#endif
