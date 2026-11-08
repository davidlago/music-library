import MusicLibraryCore
import SwiftUI

/// The Shop's price guide for an album, on both apps and under the DJ's words: a fair price to lead with, then what
/// Discogs (editions, suggestions by condition, the user's Discogs copies) and eBay (recent sales, copies for sale)
/// say, with links to each.
public struct PriceGuideView: View {
    let guide: PriceGuide
    /// Under a DJ line: the header is the album's name, without the thumbnail.
    let compact: Bool

    let lead: Lead

    /// The price at the top.
    public enum Lead: Hashable, Sendable {
        /// `PriceGuide.fairPrice`: eBay's sales first (the DJ, the Buy List).
        case fair
        /// The Shop: Discogs' estimate for the most common pressing, with US shipping on top when it's known
        /// (`PriceGuide.shopEstimate`).
        case shop(usShipping: Money?)
        /// A copy you own: Discogs' price for its pressing and grade (`PriceGuide.copyEstimate`).
        case copy(grade: CollectionGrade?)
    }

    public init(guide: PriceGuide, compact: Bool = false, lead: Lead = .fair) {
        self.guide = guide
        self.compact = compact
        self.lead = lead
    }

    private var estimate: PriceGuide.FairPrice? {
        switch lead {
        case .fair: guide.fairPrice
        case .shop(let shipping): guide.shopEstimate(shipping: shipping)
        case .copy(let grade): guide.copyEstimate(grade: grade)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !guide.hasPrices {
                Text("Nothing on Discogs\(guide.ebayForSale == nil ? "" : " or eBay") matches \(guide.request.album.isEmpty ? "this" : "“\(guide.request.album)”")\(guide.request.format == .any ? "" : " on \(guide.request.format.name)").")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let fair = estimate {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fair.text).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("\(lead == .fair ? "Fair price" : "Estimate"): \(fair.source)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let owned = guide.ownedOnDiscogs, !owned.isEmpty {
                Label {
                    Text(owned.contains(where: \.sameEdition) ? "This edition is in your Discogs collection"
                         : "In your Discogs collection: \(owned.count == 1 ? "another edition" : "\(owned.count) copies")")
                } icon: { Image(systemName: "checkmark.seal.fill") }
                .font(.subheadline.weight(.medium)).foregroundStyle(.green)
            }
            if !guide.editions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sourceTitle("Discogs", link: guide.marketURL, linkTitle: "For Sale")
                    ForEach(guide.editions) { EditionRow(edition: $0) }
                    if let lowest = guide.masterLowest, let count = guide.masterForSale, count > 0 {
                        Text("Any edition: \(count) for sale from \(PriceGuide.text(lowest))\(guide.versions > 0 ? " · \(guide.versions) versions" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let sold = guide.ebaySold { EbayRows(summary: sold) }
            if let forSale = guide.ebayForSale { EbayRows(summary: forSale) }
            ForEach(guide.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if !compact, let thumb = guide.thumbnail, DiscogsLink.isImageURL(thumb) {
                AsyncImage(url: thumb) { image in image.resizable().scaledToFill() } placeholder: { AppColor.fill }
                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(compact ? "Price guide: \(guide.title.isEmpty ? guide.request.album : guide.title)" : "Price Guide")
                    .font(.headline).lineLimit(2)
                let format = guide.request.format == .any ? "" : guide.request.format.name
                let who = guide.artist.isEmpty ? guide.request.artist : guide.artist
                Text([compact ? who : "", format].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceTitle(_ name: String, link: URL?, linkTitle: String) -> some View {
        HStack {
            Text(name).font(.subheadline.weight(.semibold))
            Spacer()
            if let link, link.isWebLink { Link(linkTitle, destination: link).font(.caption) }
        }
    }
}

private struct EditionRow: View {
    let edition: DiscogsPricedEdition

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(edition.roles.map(\.name).joined(separator: " · ")).font(.callout.weight(.medium))
                Spacer()
                Text(edition.forSale > 0 ? "\(edition.forSale) from \(edition.lowest.map(PriceGuide.text) ?? "?")" : "none for sale")
                    .font(.callout).monospacedDigit().foregroundStyle(edition.forSale > 0 ? .primary : .secondary)
            }
            if let url = edition.webURL, url.isWebLink {
                Link(destination: url) { Text(edition.details).lineLimit(2).multilineTextAlignment(.leading) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !edition.suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(edition.suggestions.prefix(6), id: \.condition) { s in
                        Text("\(s.short) \(PriceGuide.text(s.price))")
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(AppColor.fill))
                    }
                }
            }
            if let have = edition.have, let want = edition.want {
                Text("\(have.formatted()) have · \(want.formatted()) want").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EbayRows: View {
    let summary: EbayPriceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.kind == .sold ? "eBay · Sold Recently" : "eBay · For Sale Now").font(.subheadline.weight(.semibold))
                Spacer()
                if summary.searchURL.isWebLink { Link("Open", destination: summary.searchURL).font(.caption) }
            }
            if summary.isEmpty {
                Text(summary.kind == .sold ? "No recent sales of it." : "No copies listed.").font(.caption).foregroundStyle(.secondary)
            }
            if let used = summary.used { spread("Used", used) }
            if let new = summary.new { spread("New", new) }
            if let edition = summary.edition { spread("This edition", edition) }
            if summary.kind == .forSale, summary.auctions > 0 {
                Text("\(summary.auctions) auction\(summary.auctions == 1 ? "" : "s") running").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func spread(_ label: String, _ s: PriceSpread) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.typicalLow == s.typicalHigh ? PriceGuide.text(s.median) : "\(PriceGuide.text(s.typicalLow))–\(PriceGuide.text(s.typicalHigh))")
                    .font(.callout).monospacedDigit()
                Text("\(s.count) · median \(PriceGuide.text(s.median))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Where to look for a copy: each store's own search for the album (the Mac Shop also reads the first four itself).
public struct ShopStoreLinks: View {
    let target: CDShoppingTarget

    public init(target: CDShoppingTarget) { self.target = target }

    public var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(CDShop.allCases) { shop in
                if let url = CDShopURLs.browse(shop, for: target), url.isWebLink, shop.owns(url) {
                    Link(destination: url) {
                        Label(shop.name, systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(AppColor.fill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// What the listener already has of an album, for the Shop: copies on the shelf and albums in the digital library.
public struct ShopOwnershipView: View {
    let ownership: ShopOwnership
    let openItem: (CollectionItem) -> Void
    let openAlbum: (AlbumSummary) -> Void

    public init(ownership: ShopOwnership, openItem: @escaping (CollectionItem) -> Void, openAlbum: @escaping (AlbumSummary) -> Void) {
        self.ownership = ownership
        self.openItem = openItem
        self.openAlbum = openAlbum
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ownership.isEmpty {
                Label("Not in your collection", systemImage: "circle.dashed").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(ownership.copies, id: \.id) { item in
                Button { openItem(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(item.medium == .download ? "You bought it as a download" : "You own it on \(item.medium.name)")
                        if let sticker = item.sticker { StickerPill(sticker: sticker) }
                        Spacer(minLength: 0)
                        Text([item.year.map(String.init) ?? "", item.catalogNumber ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
            }
            ForEach(ownership.digitalAlbums) { album in
                Button { openAlbum(album) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list").foregroundStyle(AppColor.accent)
                        Text("In your digital library: \(album.trackCount) song\(album.trackCount == 1 ? "" : "s")")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.subheadline)
            }
        }
    }
}
