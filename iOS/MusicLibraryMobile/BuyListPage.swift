import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

/// The Buy List's pages: the list, and one album on it.
enum BuyListRoute: Hashable {
    case list
    case album(id: String)
}

struct BuyListRoutePage: View {
    let route: BuyListRoute

    var body: some View {
        switch route {
        case .list: BuyListPage()
        case .album(let id): WantedAlbumPage(id: id)
        }
    }
}

/// The albums you're looking for and what each goes for now (Discogs and eBay), deals first. Refresh prices every
/// album not checked in the last few hours; tap one for its price history, the full price guide and stores.
struct BuyListPage: View {
    @Environment(PhoneModel.self) private var model
    @State private var adding = false

    var body: some View {
        let market = model.market
        List {
            if !market.shown.isEmpty {
                Section {
                    summary(market)
                }
            }
            Section {
                ForEach(market.shown) { album in
                    NavigationLink(value: BuyListRoute.album(id: album.id)) {
                        WantedRow(album: album, checking: market.checking.contains(album.id))
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", systemImage: "trash", role: .destructive) { market.remove([album.id]) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Refresh", systemImage: "arrow.clockwise") { market.refresh(ids: [album.id]) }.tint(.blue)
                    }
                }
            } footer: {
                if !market.shown.isEmpty {
                    Text("The big price is the cheapest copy for sale on Discogs or eBay's typical asking price for a used copy; “fair” comes from recent eBay sales or Discogs' suggestions. Your Mac gets the list, and what you change here, at the next sync.")
                }
            }
        }
        .overlay {
            if market.shown.isEmpty {
                ContentUnavailableView {
                    Label("Nothing on Your Buy List", systemImage: "bag")
                } description: {
                    Text("Look an album up in the Shop (or scan its barcode) and tap Add to Buy List. Its prices are kept here, and you'll see when one is at or under the most you'd pay.")
                } actions: {
                    Button("Add an Album") { adding = true }
                }
            }
        }
        .navigationTitle("Buy List")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if market.progress != nil {
                    Button("Stop", systemImage: "stop.circle") { market.stopRefreshing() }
                } else {
                    Button("Refresh Prices", systemImage: "arrow.clockwise") { market.refresh() }
                        .disabled(market.shown.isEmpty)
                }
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .refreshable { market.refresh() }
        .sheet(isPresented: $adding) { WantedEditorSheet(album: nil) }
        .radioDJPage(.page("their Buy List, the albums they're looking for, with what each goes for now",
                           details: market.shown.prefix(40).map(\.radioDJLine)))
    }

    private func summary(_ market: PhoneMarket) -> some View {
        let totals = BuyList.totals(market.shown)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                figure("\(totals.count)", totals.count == 1 ? "album" : "albums")
                if let cost = totals.cost { figure("≈ \(PriceGuide.text(cost))", "at fair prices") }
                figure("\(totals.deals)", totals.deals == 1 ? "deal now" : "deals now", color: totals.deals > 0 ? .green : .primary)
            }
            if let progress = market.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Checking prices: \(progress.done) of \(progress.total)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WantedRow: View {
    let album: WantedAlbum
    let checking: Bool

    var body: some View {
        HStack(spacing: 12) {
            WantedThumb(album: album, side: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.album).lineLimit(1)
                Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text([album.format.name, album.editionDetails].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            WantedPriceSummary(album: album, checking: checking, compact: true)
        }
    }
}

struct WantedThumb: View {
    let album: WantedAlbum
    let side: CGFloat

    var body: some View {
        Group {
            if let url = album.thumbnail, DiscogsLink.isImageURL(url) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { AppColor.fill }
            } else {
                ZStack { AppColor.fill; Image(systemName: album.format == .vinyl ? "record.circle" : "opticaldisc").foregroundStyle(.secondary) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: One album

private struct WantedAlbumPage: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false

    var body: some View {
        if let album = model.market.album(id: id) {
            content(album)
        } else {
            ContentUnavailableView("Not on Your Buy List", systemImage: "bag", description: Text("It was removed from the list."))
        }
    }

    private func content(_ album: WantedAlbum) -> some View {
        let market = model.market
        let owned = ShopOwnership.find(album: album.album, artist: album.artist, collection: model.collection, tracks: [])
            .copies.filter { album.format == .any || $0.medium == album.format.medium }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    WantedThumb(album: album, side: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.album).font(.title2.bold())
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                        Text([album.format.name, album.editionDetails].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let copy = owned.first {
                    Button { openRoute(CollectionItemRoute(id: copy.id)) } label: {
                        Label("You own it now\(copy.sticker.map { " (\($0.text))" } ?? "")", systemImage: "checkmark.seal.fill")
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Now").font(.caption).foregroundStyle(.secondary)
                            WantedPriceSummary(album: album, checking: market.checking.contains(album.id))
                        }
                        Spacer()
                        if let max = album.maxMoney {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Your max").font(.caption).foregroundStyle(.secondary)
                                Text(PriceGuide.text(max)).font(.title3.weight(.semibold)).monospacedDigit()
                            }
                        }
                    }
                    WantedPriceHistory(album: album)
                    if let check = album.latest { breakdown(check) }
                }
                .padding(14)
                .card()
                if !album.notes.isEmpty {
                    Text(album.notes).font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                VStack(spacing: 10) {
                    Button { openRoute(ShopAlbumRoute(request: album.request)) } label: {
                        Label("Price Guide and Stores", systemImage: "cart").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button { market.refresh(ids: [album.id]) } label: {
                        Label("Refresh Price", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(market.checking.contains(album.id))
                    Button(role: .destructive) {
                        market.remove([album.id])
                        dismiss()
                    } label: {
                        Label(owned.isEmpty ? "Remove from Buy List" : "Got It: Remove from Buy List", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { editing = true }
        }
        .sheet(isPresented: $editing) { WantedEditorSheet(album: album) }
        .radioDJPage(.page("an album on their Buy List", details: [album.radioDJLine]))
    }

    private func breakdown(_ check: WantedPriceCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let d = check.discogsLowest {
                Text("Discogs from \(PriceGuide.text(d))\(check.discogsForSale.map { " · \($0) for sale" } ?? "")")
            }
            if let e = check.ebayAsking { Text("eBay asking about \(PriceGuide.text(e)) for a used copy") }
            if let s = check.ebaySoldMedian { Text("eBay sold for \(PriceGuide.text(s)) (median of \(check.ebaySoldCount ?? 0))") }
            if let fair = check.fairText, let source = check.fairSource { Text("Fair \(fair), from \(source)") }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

// MARK: Editing

/// Adds an album by name, or edits one: format, barcode, the most you'd pay and notes.
struct WantedEditorSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: WantedAlbum?
    @State private var title = ""
    @State private var artist = ""
    @State private var format = PriceGuideRequest.Format.vinyl
    @State private var barcode = ""
    @State private var maxPrice: Decimal?
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Album", text: $title)
                    TextField("Artist", text: $artist)
                    Picker("Format", selection: $format) {
                        ForEach(PriceGuideRequest.Format.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    TextField("Barcode (optional)", text: $barcode).keyboardType(.numberPad)
                }
                Section {
                    TextField("Most you'd pay", value: $maxPrice, format: .currency(code: album?.currency ?? currencyCode))
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                } footer: {
                    Text("You'll see when something's at or under the most you'd pay.")
                }
            }
            .navigationTitle(album == nil ? "Add to Buy List" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(album == nil ? "Add" : "Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let album else { return }
                title = album.album; artist = album.artist; format = album.format; barcode = album.barcode
                maxPrice = album.maxPrice; notes = album.notes
            }
        }
    }

    private func save() {
        let market = model.market
        let t = title.trimmingCharacters(in: .whitespaces), a = artist.trimmingCharacters(in: .whitespaces)
        if var album {
            let changed = album.album != t || album.artist != a || album.format != format || album.barcode != barcode
            album.album = t; album.artist = a; album.format = format; album.barcode = barcode
            album.maxPrice = maxPrice; album.notes = notes
            if changed {
                // Another album or edition: a new entry, priced afresh.
                market.remove([album.id])
                let fresh = market.add(artist: a, album: t, format: format, barcode: barcode, maxPrice: maxPrice, notes: notes)
                market.refresh(ids: [fresh.id])
            } else {
                market.update(album)
            }
        } else {
            let fresh = market.add(artist: a, album: t, format: format, barcode: barcode, maxPrice: maxPrice, notes: notes)
            market.refresh(ids: [fresh.id])
        }
        dismiss()
    }
}

/// "Add to Buy List" / "On Buy List" for a price guide (the Shop).
struct AddToBuyListButton: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    let guide: PriceGuide

    var body: some View {
        let title = guide.title.isEmpty ? guide.request.album : guide.title
        let artist = guide.artist.isEmpty ? guide.request.artist : guide.artist
        if let entry = model.market.entry(artist: artist, album: title, format: guide.request.format) {
            Button { openRoute(BuyListRoute.album(id: entry.id)) } label: {
                Label("On Your Buy List", systemImage: "bag.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        } else {
            Button { model.market.add(guide) } label: {
                Label("Add to Buy List", systemImage: "bag.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }
}
