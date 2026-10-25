import AppKit
import MusicLibraryCore
import SwiftUI

/// The Shop: find the CD or record on MusicBrainz (album, artist, barcode or catalog number), pick the edition, then
/// compare copies for sale on Discogs, eBay, CDandLP and Alibris.
struct CDShopView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let store = model.cdShop
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CDShopSearchBar(store: store)
                if let target = store.target {
                    CDShopOffersSection(store: store, target: target)
                } else {
                    CDShopEditionsSection(store: store)
                }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Shop")
        .navigationSubtitle(store.target.map { "\($0.artist) – \($0.album) (\($0.format.name))" } ?? "New and used CDs and records that ship to the US")
        .toolbar {
            ToolbarItem {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.target == nil)
                    .help("Look for copies again")
            }
        }
    }
}

// MARK: Search

private struct CDShopSearchBar: View {
    @Environment(\.theme) private var theme
    @Bindable var store: CDShopStore

    var body: some View {
        HStack(spacing: 8) {
            // Picking the other format shows the same search's editions in it (only when the user picks it: the DJ
            // sets the query's format with its own search).
            Picker("Format", selection: Binding(get: { store.query.format }, set: { format in
                guard format != store.query.format else { return }
                store.query.format = format
                if store.searchState != .idle, !store.query.isEmpty { store.unlock(); store.search() }
            })) {
                ForEach(ShopFormat.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shop for CDs or vinyl records")
            field("Album", text: $store.query.album, width: 240)
            field("Artist", text: $store.query.artist, width: 200)
            field("Barcode or catalog number", text: $store.query.code, width: 200)
            Button { store.unlock(); store.search() } label: {
                if store.searchState == .searching { ProgressView().controlSize(.small) } else { Text("Find") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(store.query.isEmpty || store.searchState == .searching)
            Spacer(minLength: 0)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
            .frame(maxWidth: width)
            .onSubmit { store.unlock(); store.search() }
    }
}

/// Step one: the albums MusicBrainz found and their editions in the format.
private struct CDShopEditionsSection: View {
    @Environment(\.theme) private var theme
    let store: CDShopStore

    var body: some View {
        let format = store.format
        switch store.searchState {
        case .idle:
            ContentUnavailableView {
                Label("Find a CD or Record", systemImage: "cart")
            } description: {
                Text("Pick CD or Vinyl, then search by album and artist, by artist alone to browse their albums, or by the barcode or catalog number on the case or sleeve. Pick the edition you want, then compare copies for sale on Discogs, eBay, CDandLP and Alibris. No accounts needed.")
            }
            .padding(.top, 40)
        case .searching where store.albums.isEmpty:
            ProgressView("Searching MusicBrainz…").frame(maxWidth: .infinity).padding(.top, 40)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.subtext)
        default:
            if store.albums.isEmpty {
                ContentUnavailableView {
                    Label("Not on MusicBrainz", systemImage: format.symbol)
                } description: {
                    Text(store.artist != nil ? "MusicBrainz lists no albums for \(store.artist!.name)."
                         : store.query.album.isEmpty && store.query.code.isEmpty ? "MusicBrainz has no artist by that name."
                         : "MusicBrainz has no \(format.name) editions matching that. New, local and rare releases are often missing there; the stores may still have it.")
                } actions: {
                    Button("Search the Stores by Name") { store.shopByName() }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if store.artists.count > 1 { artistChips }
                    Text((store.albums.count == 1 ? "1 album" : "\(store.albums.count) albums")
                         + (store.artist.map { " by \($0.name): open one to see its \(format.name) editions" } ?? ""))
                        .font(.caption).foregroundStyle(.subtext)
                    ForEach(store.albums) { album in
                        CDShopAlbumCard(store: store, album: album)
                    }
                    HStack(spacing: 6) {
                        Text("Not here?").foregroundStyle(.subtext)
                        Button("Search the stores by name") { store.shopByName() }.buttonStyle(.link)
                    }
                    .font(.callout).padding(.top, 4)
                }
            }
        }
    }
}

extension CDShopEditionsSection {
    /// The other artists an artist search matched ("Creedence Clearwater Revisited"…).
    var artistChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(store.artists) { artist in
                let selected = store.artist == artist
                Button { store.choose(artist: artist) } label: {
                    Text(artist.name + (artist.disambiguation.isEmpty ? "" : " (\(artist.disambiguation))"))
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(selected ? theme.accent.opacity(0.25) : theme.fill))
                }
                .buttonStyle(.plain)
                .help(selected ? "Showing \(artist.name)" : "Show \(artist.name)'s albums instead")
            }
        }
    }
}

private struct CDShopAlbumCard: View {
    @Environment(\.theme) private var theme
    let store: CDShopStore
    let album: CDAlbum

    var body: some View {
        let expanded = store.expandedAlbum == album.id
        let format = store.format
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { store.toggle(album) }
            } label: {
                HStack(spacing: 12) {
                    CDShopCover(releaseId: nil, releaseGroupId: album.releaseGroupId, side: 56, format: format)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.title).font(.headline)
                        Text(album.artist).foregroundStyle(.subtext)
                        Text([album.kind, album.year.map(String.init),
                              !album.editionsLoaded ? nil : album.editions.count == 1 ? "1 \(format.name) edition" : "\(album.editions.count) \(format.name) editions"]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.subtext)
                    }
                    Spacer()
                    Button("Any \(format.name) Edition") { store.lock(edition: nil, album: album) }
                        .help("Shop for this album on \(format == .cd ? "CD" : "vinyl"), whichever edition")
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.subtext)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().opacity(0.5)
                if store.loadingEditions.contains(album.id) {
                    ProgressView("Finding \(format.name) editions…").controlSize(.small).frame(maxWidth: .infinity).padding(12)
                } else if let error = store.editionErrors[album.id] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.subtext).padding(12)
                } else if album.editionsLoaded, album.editions.isEmpty {
                    Text("MusicBrainz lists no \(format.name) editions of this album. “Any \(format.name) Edition” still searches the stores for it.")
                        .font(.caption).foregroundStyle(.subtext).padding(12)
                }
                ForEach(Array(album.editions.enumerated()), id: \.element.id) { i, edition in
                    CDShopEditionRow(edition: edition, format: format) { store.lock(edition: edition, album: album) }
                    if i < album.editions.count - 1 { Divider().opacity(0.4).padding(.leading, 12) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private struct CDShopEditionRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let edition: CDEdition
    let format: ShopFormat
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CDShopCover(releaseId: edition.id, releaseGroupId: nil, side: 40, format: format)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text([edition.date.isEmpty ? "Undated" : edition.date, edition.country].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout.weight(.semibold))
                    if !edition.status.isEmpty, edition.status != "Official" {
                        Text(edition.status).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(theme.fill))
                    }
                }
                Text([edition.label, edition.catalogNumber].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                CDShopOwnedNote(edition: edition, releaseGroupId: edition.releaseGroupId, album: edition.title, artist: edition.artist,
                                format: format)
            }
            Spacer()
            Button("I Own This…") { model.addToCollection(medium: format.medium, prefill: CDShopOwnedNote.prefill(edition)) }
                .help("Add this edition to your physical collection, with your label number and what you paid")
            Button("Shop This Edition", action: choose).buttonStyle(.bordered)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? theme.fill.opacity(0.5) : Color.clear)
        .onHover { hovering = $0 }
        .textSelection(.enabled)
    }

    private var details: String {
        [edition.format, edition.trackCount > 0 ? "\(edition.trackCount) tracks" : nil, edition.packaging.isEmpty ? nil : edition.packaging,
         edition.barcode.isEmpty ? nil : "Barcode \(edition.barcode)", edition.disambiguation.isEmpty ? nil : edition.disambiguation]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: Offers

/// Step two: copies for sale.
private struct CDShopOffersSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    @Bindable var store: CDShopStore
    let target: CDShoppingTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            shopChips
            filters
            if let error = store.resolveError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.subtext)
            }
            let shown = store.shownOffers
            if shown.isEmpty {
                if isLoading {
                    ProgressView("Looking for copies…").frame(maxWidth: .infinity).padding(.vertical, 30)
                } else {
                    Text(store.offers.isEmpty ? "No copies found on these stores." : "No copies match these filters.")
                        .foregroundStyle(.subtext).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            }
            ForEach(sections(shown), id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title).font(.title3.bold())
                        Text(section.subtitle).font(.caption).foregroundStyle(.subtext)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(section.offers.enumerated()), id: \.element.id) { i, offer in
                            CDOfferRow(offer: offer, dollars: store.dollars(offer), format: target.format)
                            if i < section.offers.count - 1 { Divider().opacity(0.5) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
                }
            }
            alsoSearch
            Text("Prices in other currencies are converted to dollars at the European Central Bank's rates and are approximate; shipping is shown when the store lists it. Listings open on the store's site, where you buy as usual.")
                .font(.caption).foregroundStyle(.subtext)
        }
    }

    private var isLoading: Bool {
        store.isResolving || store.shopStates.values.contains { $0 == .loading || $0 == .waiting }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CDShopCover(releaseId: target.edition?.id, releaseGroupId: target.releaseGroupId, side: 84, format: target.format)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.isByName ? "\(target.format.name.uppercased()) BY NAME"
                     : target.edition == nil ? "ANY \(target.format.name.uppercased()) EDITION" : "THIS \(target.format.name.uppercased()) EDITION")
                    .font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.subtext)
                Text(target.album).font(.title2.bold())
                Text(target.artist).foregroundStyle(.subtext)
                if target.isByName {
                    Text("Not on MusicBrainz, so these are the stores' own search results: check each listing is the \(target.format.noun) you want.")
                        .font(.caption).foregroundStyle(.subtext)
                }
                if let e = target.edition {
                    Text([e.date, e.country, e.label, e.catalogNumber, e.format].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.subtext).textSelection(.enabled)
                    if !e.barcode.isEmpty { Text("Barcode \(e.barcode)").font(.caption).foregroundStyle(.subtext).textSelection(.enabled) }
                }
                if let stats = store.discogsStats, stats.forSale > 0, let lowest = stats.lowest {
                    Text("Discogs: \(stats.forSale) for sale from \(lowest.formatted()) before shipping")
                        .font(.caption).foregroundStyle(.subtext)
                }
                CDShopOwnedNote(edition: target.edition, releaseGroupId: target.releaseGroupId, album: target.album, artist: target.artist,
                                format: target.format)
            }
            Spacer()
            Button("I Own This…") {
                model.addToCollection(medium: target.format.medium, prefill: target.edition.map(CDShopOwnedNote.prefill)
                                      ?? CollectionPrefill(album: target.album, artist: target.artist, releaseGroupID: target.releaseGroupId,
                                                           barcode: target.typedBarcode))
            }
            .help("Add this \(target.format.noun) to your physical collection, with your label number and what you paid")
            Button { store.unlock() } label: { Label("Choose Another", systemImage: "chevron.backward") }
                .help("Back to the editions")
        }
    }

    private var shopChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(CDShop.searched) { shop in
                let hidden = store.hiddenShops.contains(shop)
                Button {
                    if hidden { store.hiddenShops.remove(shop) } else { store.hiddenShops.insert(shop) }
                } label: {
                    HStack(spacing: 5) {
                        status(store.shopStates[shop] ?? .waiting)
                        Text(shop.name)
                        if case .done(let n) = store.shopStates[shop] { Text("\(n)").foregroundStyle(.subtext).monospacedDigit() }
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(hidden ? Color.clear : theme.fill))
                    .overlay(Capsule().strokeBorder(theme.separator.opacity(hidden ? 0.8 : 0), lineWidth: 0.5))
                    .opacity(hidden ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .help(help(shop))
            }
        }
    }

    @ViewBuilder
    private func status(_ state: CDShopStore.ShopState) -> some View {
        switch state {
        case .waiting, .loading: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notLinked: Image(systemName: "minus.circle").foregroundStyle(.subtext)
        }
    }

    private func help(_ shop: CDShop) -> String {
        switch store.shopStates[shop] ?? .waiting {
        case .failed(let message): "\(shop.name): \(message)"
        case .notLinked: target.isByName ? "Discogs is searched by its MusicBrainz link; use “Search on Discogs” below."
            : "MusicBrainz doesn't link this \(target.format.noun) to \(shop.name); use “Search on \(shop.name)” below."
        default: store.hiddenShops.contains(shop) ? "Show \(shop.name)" : "Hide \(shop.name)"
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Condition", selection: $store.condition) {
                ForEach(CDShopStore.ConditionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            Toggle("Possible matches", isOn: $store.showsPossible)
                .help("Listings found by name, whose edition isn't known")
            Spacer()
        }
    }

    private struct Section {
        var title: String
        var subtitle: String
        var offers: [CDOffer]
    }

    private func sections(_ offers: [CDOffer]) -> [Section] {
        let groups: [(CDOffer.Match, String, String)] = [
            (.edition, "This Edition", "Listed as this \(target.format.noun) (Discogs release, barcode or catalog number)"),
            (.album, target.edition == nil ? "This Album on \(target.format.name)" : "Other Editions", "The album on \(target.format.name), edition as listed"),
            (.possible, "Possible Matches", "Found by name; check the listing for the edition"),
        ]
        return groups.compactMap { match, title, subtitle in
            let list = offers.filter { $0.match == match }
            return list.isEmpty ? nil : Section(title: title, subtitle: subtitle, offers: list)
        }
    }

    private var alsoSearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Search on").font(.caption.weight(.semibold)).foregroundStyle(.subtext)
            FlowLayout(spacing: 6) {
                ForEach(CDShop.searched + CDShop.linked) { shop in
                    if let url = CDShopURLs.browse(shop, for: target)?.webLink {
                        Link(destination: url) { Label(shop.name, systemImage: "arrow.up.right.square") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct CDOfferRow: View {
    @Environment(\.theme) private var theme
    let offer: CDOffer
    let dollars: Decimal?
    let format: ShopFormat
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AsyncImage(url: offer.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack { Rectangle().fill(theme.fill); Image(systemName: format.symbol).foregroundStyle(.subtext) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.title).font(.callout.weight(.medium)).lineLimit(2)
                if !offer.edition.isEmpty { Text(offer.edition).font(.caption).foregroundStyle(.subtext).lineLimit(1) }
                Text(details).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                if !offer.notes.isEmpty { Text(offer.notes).font(.caption2).foregroundStyle(.subtext).lineLimit(1).italic() }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(totalText).font(.headline).monospacedDigit()
                Text(breakdown).font(.caption2).foregroundStyle(.subtext).monospacedDigit()
            }
            .frame(minWidth: 110, alignment: .trailing)
            if let url = offer.url.webLink {
                Link(destination: url) { Text(offer.shop.name).frame(minWidth: 64) }
                    .buttonStyle(.bordered)
                    .help("Open this listing on \(offer.shop.name)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? theme.fill.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = offer.url.webLink {
                Link("Open on \(offer.shop.name)", destination: url)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
    }

    /// "Pre-Owned · second.sale 99.6% positive · from United States · Buy It Now"
    private var details: String {
        let condition: String = offer.conditionText.isEmpty
            ? (offer.condition == .new ? "New" : offer.condition == .used ? "Used" : "")
            : offer.conditionText
        return [condition, [offer.seller, offer.sellerRating].filter { !$0.isEmpty }.joined(separator: " "),
                offer.shipsFrom.isEmpty ? "" : "from \(offer.shipsFrom)", offer.saleFormat == "from" ? "" : offer.saleFormat]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var totalText: String {
        let prefix = offer.saleFormat == "from" ? "from " : ""
        guard let dollars else { return prefix + offer.price.formatted() }
        let approx = offer.price.currency == "USD" && (offer.shipping?.currency ?? "USD") == "USD" && offer.quotedTotal == nil ? "" : "≈ "
        return prefix + approx + Money(dollars, "USD").formatted()
    }

    /// "€3.00 + €16.00 shipping", "$11.88 + free shipping", "€2.55 + shipping".
    private var breakdown: String {
        let shipping: String
        if let s = offer.shipping {
            shipping = s.amount == 0 ? "free shipping" : "\(s.formatted()) shipping" + (offer.shippingNote == "estimate" ? " (est.)" : "")
        } else {
            shipping = "shipping not listed"
        }
        return "\(offer.price.formatted()) + \(shipping)"
    }
}

// MARK: Covers

/// A release's (or, failing that, its album's) front cover from the Cover Art Archive.
struct CDShopCover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let releaseId: String?
    let releaseGroupId: String?
    let side: CGFloat
    var format: ShopFormat = .cd
    @State private var image: NSImage?

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(theme.fill)
                Image(systemName: format.symbol).foregroundStyle(.subtext)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(releaseId ?? "")|\(releaseGroupId ?? "")") {
            let key = "\(releaseId ?? "")|\(releaseGroupId ?? "")"
            if let hit = Self.cache[key] { image = hit; return }
            guard let data = try? await model.coverArt.fetchFront(releaseId: releaseId ?? "", releaseGroupId: releaseGroupId, size: 250),
                  let loaded = NSImage(data: data) else { return }
            Self.cache[key] = loaded
            image = loaded
        }
    }
}

/// Whether you own a CD or record the shop lists: "You own this edition (CD #142)", "You own another edition (CD #57)",
/// or for a copy in another format, what you have. This is only a reminder.
private struct CDShopOwnedNote: View {
    @Environment(AppModel.self) private var model
    /// Nil: any CD edition of the album.
    let edition: CDEdition?
    let releaseGroupId: String?
    let album: String
    let artist: String
    let format: ShopFormat

    var body: some View {
        let copies = model.catalog.collectionMatcher.items(releaseID: edition?.id, releaseGroupID: releaseGroupId, title: album,
                                                           artists: [artist])
        let cds = copies.filter { $0.medium == format.medium }
        if let edition, !cds.isEmpty {
            let same = cds.filter { $0.releaseID == edition.id }
            CollectionCopyNote(copies: same.isEmpty ? cds : same, edition: !same.isEmpty)
        } else if !copies.isEmpty {
            CollectionCopyNote(copies: copies)
        }
    }

    /// Add to Collection… for an edition: found by its barcode, else by its title and artist, and picked.
    static func prefill(_ e: CDEdition) -> CollectionPrefill {
        CollectionPrefill(album: e.title, artist: e.artist, releaseID: e.id, releaseGroupID: e.releaseGroupId,
                          barcode: e.barcode.isEmpty ? nil : e.barcode, catalogNumber: e.catalogNumber.isEmpty ? nil : e.catalogNumber)
    }
}

extension ShopFormat {
    /// The placeholder for a cover not loaded yet.
    var symbol: String { self == .cd ? "opticaldisc" : "record.circle" }
}
