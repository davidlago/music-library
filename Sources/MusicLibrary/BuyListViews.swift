import AppKit
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

/// The Buy List page (Acquire ▸ Buy List): the albums you're looking for, what each goes for now (Discogs and eBay,
/// with what changed since the check before), and which are at or under the most you'd pay. Rows open into their
/// price history, notes and actions: Shop, Refresh, Edit, I Got It… and Remove.
struct BuyListView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: String?
    @State private var editing: WantedEditorRequest?
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "All", deals = "Deals", cd = "CDs", vinyl = "Vinyl"
    }

    var body: some View {
        let store = model.buyList
        let rows = filtered(store.shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !store.shown.isEmpty {
                    summary(store)
                    Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(rows) { album in
                        BuyListRow(album: album, expanded: expanded == album.id, edit: { editing = .edit(album) }) {
                            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == album.id ? nil : album.id }
                        }
                        if album.id != rows.last?.id { Divider().opacity(0.5) }
                    }
                }
                .card()
                if !store.shown.isEmpty {
                    Text("Prices are the cheapest copy for sale on Discogs or eBay's typical asking price for a used copy, and the fair price from recent eBay sales or Discogs' suggestions. Refresh Prices checks every album not checked in the last six hours, one at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
            .playerClearance()
        }
        .overlay {
            if store.shown.isEmpty {
                ContentUnavailableView {
                    Label("Nothing on Your Buy List", systemImage: "bag")
                } description: {
                    Text("Price an album in the Shop and choose Add to Buy List, or add one by name. Its prices are kept here, and you'll see when one is at or under the most you'd pay.")
                } actions: {
                    Button("Add an Album…") { editing = .add }
                    Button("Open the Shop") { model.sidebar = .cdShop }
                }
            } else if rows.isEmpty {
                ContentUnavailableView("Nothing Here", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(filter == .deals ? "Nothing is at or under the most you'd pay right now." : "No albums in this format."))
            }
        }
        .navigationTitle("Buy List")
        .navigationSubtitle(store.shown.isEmpty ? "" : CollectionInsightText.albumCount(store.shown.count))
        .toolbar {
            ToolbarItemGroup {
                if store.progress != nil {
                    Button { store.stopRefreshing() } label: { Label("Stop", systemImage: "stop.circle") }
                        .help("Stop checking prices")
                } else {
                    Button { store.refresh() } label: { Label("Refresh Prices", systemImage: "arrow.clockwise") }
                        .disabled(store.shown.isEmpty)
                        .help("Check what every album goes for now")
                }
                Button { editing = .add } label: { Label("Add an Album", systemImage: "plus") }
                    .help("Add an album by name")
            }
        }
        .sheet(item: $editing) { WantedEditor(request: $0) }
        .onAppear {
            if let focus = model.buyListFocus { expanded = focus; model.buyListFocus = nil }
        }
        .onChange(of: model.buyListFocus) { _, focus in
            if let focus { expanded = focus; model.buyListFocus = nil }
        }
    }

    private func filtered(_ all: [WantedAlbum]) -> [WantedAlbum] {
        switch filter {
        case .all: all
        case .deals: all.filter(\.isDeal)
        case .cd: all.filter { $0.format != .vinyl }
        case .vinyl: all.filter { $0.format != .cd }
        }
    }

    private func summary(_ store: BuyListStore) -> some View {
        let totals = store.totals
        return HStack(alignment: .firstTextBaseline, spacing: 28) {
            figure(CollectionInsightText.albumCount(totals.count), "wanted")
            if let cost = totals.cost {
                figure("≈ \(PriceGuide.text(cost))", "to get them all at fair prices")
            }
            figure("\(totals.deals)", totals.deals == 1 ? "at or under your max" : "at or under your max", color: totals.deals > 0 ? .green : .primary)
            Spacer()
            if let progress = store.progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 140)
                    Text("Checking \(progress.done + 1 > progress.total ? progress.total : progress.done + 1) of \(progress.total)…")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func figure(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BuyListRow: View {
    @Environment(AppModel.self) private var model
    let album: WantedAlbum
    let expanded: Bool
    let edit: () -> Void
    let toggle: () -> Void

    var body: some View {
        let store = model.buyList
        let owned = ShopOwnership.find(album: album.album, artist: album.artist, collection: model.collection, tracks: [])
            .copies.filter { album.format == .any || $0.medium == album.format.medium }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                DiscogsThumbnail(url: album.thumbnail, side: 52, symbol: album.format == .vinyl ? "record.circle" : "opticaldisc")
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.album).font(.headline).lineLimit(1)
                    Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(album.format.name)
                        if !album.editionDetails.isEmpty { Text("· \(album.editionDetails)") }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let copy = owned.first {
                        Label("You own it now\(copy.sticker.map { " (\($0.text))" } ?? "")", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 12)
                WantedPriceSummary(album: album, checking: store.checking.contains(album.id))
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if expanded { details(owned: owned) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contextMenu { menu(owned: owned) }
    }

    @ViewBuilder
    private func details(owned: [CollectionItem]) -> some View {
        let store = model.buyList
        VStack(alignment: .leading, spacing: 10) {
            WantedPriceHistory(album: album)
            if let check = album.latest {
                let parts = [
                    check.discogsLowest.map { "Discogs from \(PriceGuide.text($0))\(check.discogsForSale.map { " (\($0) for sale)" } ?? "")" },
                    check.ebayAsking.map { "eBay asking about \(PriceGuide.text($0))" },
                    check.ebaySoldMedian.map { "eBay sold for \(PriceGuide.text($0)) (median of \(check.ebaySoldCount ?? 0))" },
                    check.fairSource.map { "Fair price from \($0)" },
                ].compactMap { $0 }
                Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if !album.notes.isEmpty { Text(album.notes).font(.callout) }
            HStack(spacing: 8) {
                Button { shop() } label: { Label("Shop", systemImage: "cart") }
                Button { store.refresh(ids: [album.id]) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.checking.contains(album.id))
                Button("Edit…", action: edit)
                if let copy = owned.first {
                    Button("Show Your Copy") { model.showItem(id: copy.id) }
                } else {
                    Button("I Got It…") { gotIt() }
                        .help("Add it to your physical collection; then remove it from the list")
                }
                if let url = discogsURL, url.isWebLink { Link("Discogs", destination: url) }
                Spacer()
                Button("Remove", role: .destructive) { store.remove([album.id]) }
            }
            .controlSize(.small)
        }
        .padding(.leading, 64)
    }

    @ViewBuilder
    private func menu(owned: [CollectionItem]) -> some View {
        Button("Shop") { shop() }
        Button("Refresh Price") { model.buyList.refresh(ids: [album.id]) }
        Button("Edit…", action: edit)
        if owned.isEmpty { Button("I Got It…") { gotIt() } }
        if model.radioDJ.isEnabled {
            Button("Ask \(model.radioDJ.displayName)") { model.askRadioDJ(about: album) }
        }
        Divider()
        Button("Remove from Buy List", role: .destructive) { model.buyList.remove([album.id]) }
    }

    private var discogsURL: URL? {
        if let release = album.discogsReleaseID { return DiscogsLink.releaseURL(release) }
        return album.discogsMasterID.flatMap { URL(string: "https://www.discogs.com/master/\($0)") }
    }

    private func shop() {
        model.cdShop.shop(album)
        model.sidebar = .cdShop
    }

    private func gotIt() {
        model.addToCollection(medium: album.format.medium,
                              prefill: CollectionPrefill(album: album.album, artist: album.artist,
                                                         barcode: album.barcode.isEmpty ? nil : album.barcode,
                                                         catalogNumber: album.catalogNumber.isEmpty ? nil : album.catalogNumber))
    }
}

/// A Discogs picture (only Discogs' image hosts are loaded), else the format's symbol.
struct DiscogsThumbnail: View {
    let url: URL?
    let side: CGFloat
    var symbol = "opticaldisc"

    var body: some View {
        Group {
            if let url, DiscogsLink.isImageURL(url) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { AppColor.fill }
            } else {
                ZStack { AppColor.fill; Image(systemName: symbol).foregroundStyle(.secondary) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: Editing

enum WantedEditorRequest: Identifiable {
    case add
    case edit(WantedAlbum)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let w): w.id
        }
    }
}

/// Adds an album by name, or edits one: the format, the edition (barcode, catalog number), the most you'd pay, notes.
struct WantedEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: WantedEditorRequest
    @State private var album = ""
    @State private var artist = ""
    @State private var format = PriceGuideRequest.Format.vinyl
    @State private var barcode = ""
    @State private var catalogNumber = ""
    @State private var maxPrice: Decimal?
    @State private var notes = ""

    private var currency: String {
        if case .edit(let w) = request { return w.currency }
        return Locale.current.currency?.identifier ?? "USD"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text({ if case .add = request { "Add to Buy List" } else { "Edit" } }()).font(.title2.bold())
            Form {
                TextField("Album", text: $album)
                TextField("Artist", text: $artist)
                Picker("Format", selection: $format) {
                    ForEach(PriceGuideRequest.Format.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                TextField("Barcode (optional)", text: $barcode)
                TextField("Catalog number (optional)", text: $catalogNumber)
                TextField("Most you'd pay", value: $maxPrice, format: .currency(code: currency))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            .formStyle(.grouped)
            Text("With a barcode or catalog number, that edition is priced; without, the cheapest copy of any edition in the format.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button({ if case .add = request { "Add" } else { "Save" } }()) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(album.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard case .edit(let w) = request else { return }
            album = w.album; artist = w.artist; format = w.format; barcode = w.barcode; catalogNumber = w.catalogNumber
            maxPrice = w.maxPrice; notes = w.notes
        }
    }

    private func save() {
        let album = album.trimmingCharacters(in: .whitespaces), artist = artist.trimmingCharacters(in: .whitespaces)
        switch request {
        case .add:
            var w = model.buyList.add(artist: artist, album: album, format: format, barcode: barcode, maxPrice: maxPrice, notes: notes)
            if !catalogNumber.isEmpty, w.catalogNumber != catalogNumber {
                w.catalogNumber = catalogNumber
                model.buyList.update(w)
            }
        case .edit(var w):
            let editionChanged = w.barcode != barcode || w.catalogNumber != catalogNumber || w.format != format
                || w.album != album || w.artist != artist
            w.album = album; w.artist = artist; w.format = format; w.barcode = barcode; w.catalogNumber = catalogNumber
            w.maxPrice = maxPrice; w.notes = notes
            if editionChanged {
                // Another edition (or album) starts a new entry, priced afresh.
                model.buyList.replace(w)
            } else {
                model.buyList.update(w)
            }
        }
        dismiss()
    }
}

/// "Add to Buy List" / "On Buy List" for a price guide (the Shop).
struct AddToBuyListButton: View {
    @Environment(AppModel.self) private var model
    let guide: PriceGuide

    var body: some View {
        let title = guide.title.isEmpty ? guide.request.album : guide.title
        let artist = guide.artist.isEmpty ? guide.request.artist : guide.artist
        if let entry = model.buyList.entry(artist: artist, album: title, format: guide.request.format) {
            Button { model.showBuyList(entry.id) } label: { Label("On Buy List", systemImage: "bag.fill") }
                .help("Show it on your Buy List")
        } else {
            Button { model.buyList.add(guide) } label: { Label("Add to Buy List", systemImage: "bag.badge.plus") }
                .help("Keep it on your Buy List with what it goes for now")
        }
    }
}
