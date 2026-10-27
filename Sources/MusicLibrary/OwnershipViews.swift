import MusicLibraryCore
import SwiftUI

// MARK: Money

/// Prices are entered and shown in the currency of the user's locale.
let currencyCode = Locale.current.currency?.identifier ?? "USD"

func formatMoney(_ amount: Decimal, whole: Bool = false) -> String {
    amount.formatted(.currency(code: currencyCode).precision(.fractionLength(whole ? 0 : 2)))
}

// MARK: Fields

/// The purchase date: "Add Date" until one is set, then a date picker with a clear button.
struct PurchaseDateField: View {
    @Binding var day: PurchaseDay?

    var body: some View {
        HStack(spacing: 6) {
            if let day {
                DatePicker("Purchase date", selection: Binding(get: { day.date() }, set: { self.day = PurchaseDay($0) }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden().fixedSize()
                Button { self.day = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear the purchase date")
            } else {
                Button("Add Date") { self.day = PurchaseDay(Date()) }
                    .help("When you bought it")
            }
        }
    }
}

/// What you paid, in the locale's currency, saved as you type. Text that isn't an amount (or is negative) clears it.
struct PurchasePriceField: View {
    @Binding var price: Decimal?
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(Locale.current.currencySymbol ?? "$").foregroundStyle(.secondary)
            TextField("Price", text: $text, prompt: Text(Decimal(0).formatted(.number.precision(.fractionLength(2)))))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 90)
                .help("What you paid")
                .onSubmit { text = Self.format(price) }
        }
        .onAppear { text = Self.format(price) }
        .onChange(of: text) { let p = Self.parse(text); if p != price { price = p } }
        .onChange(of: price) { if Self.parse(text) != price { text = Self.format(price) } }
    }

    static func format(_ price: Decimal?) -> String {
        price.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
    }

    static func parse(_ text: String) -> Decimal? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if let symbol = Locale.current.currencySymbol { s = s.replacingOccurrences(of: symbol, with: "") }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let value = try? Decimal.FormatStyle.number.parseStrategy.parse(s) else { return nil }
        return AlbumPurchase.validPrice(value)
    }
}

// MARK: Album page

/// "Your Copies" on the album page: each copy of the album you own (its case or sleeve, label, medium, purchase and
/// digital copy; clicking one opens its page), Add a Copy (a CD or record with the next label in its series, or a
/// download, linked to this album; its date and price then show inline), Add Existing Item… (link a copy with no
/// music, like the record you bought before the download), and what the album has cost you per play.
struct YourCopiesSection: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    /// All-time plays of the album's tracks.
    let plays: Int
    /// The copy just added here, whose date and price show inline.
    @State private var added: String?
    @State private var linkingExisting = false

    var body: some View {
        let copies = self.copies
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: copies.count == 1 ? "Your Copy" : "Your Copies")
                Spacer()
                addMenu
            }
            if copies.isEmpty {
                Label("You don't own a copy", systemImage: "arrow.left.arrow.right")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Borrowed, or not added yet: add the copy you own")
            } else {
                VStack(spacing: 0) {
                    ForEach(copies) { item in
                        Button { model.showItem(id: item.id) } label: { CopyRow(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu { CollectionItemMenu(model: model, item: item) }
                        if item.id == added, item.isEditable { addedFields(item) }
                    }
                }
                if let summary = summary(copies) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: album.id) { added = nil }
        .sheet(isPresented: $linkingExisting) { AddExistingItemSheet(album: album) }
    }

    /// The album's copies as saved now, including one added a moment ago.
    private var copies: [CollectionItem] {
        let key = AlbumInfoStore.key(album)
        var list = model.collection.copies(albumKey: key).compactMap { model.item(id: $0.id) }.filter { $0.albumKey == key }
        if let added, !list.contains(where: { $0.id == added }), let item = model.item(id: added), item.albumKey == key { list.append(item) }
        return list
    }

    private var addMenu: some View {
        HStack(spacing: 8) {
            Menu("Add a Copy") {
                Button("CD (next CD #\(model.nextNumber(in: .cd)))") { add(.cd) }
                Button("Vinyl (next Vinyl #\(model.nextNumber(in: .vinyl)))") { add(.vinyl) }
                Button("Download") { add(.download) }
            }
            .fixedSize()
            .help("Add the copy you own (a CD, a record or a download), linked to this album")
            Button("Add Existing Item…") { linkingExisting = true }
                .help("Link an item you own that has no music yet to this album")
        }
        .controlSize(.small)
    }

    private func add(_ medium: CollectionMedium) {
        if let saved = model.addCopy(of: album, medium: medium) { added = saved.id }
    }

    /// Bought and Paid for the copy just added, saved as they change.
    private func addedFields(_ item: CollectionItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Bought").foregroundStyle(.secondary)
                PurchaseDateField(day: field(item, \.purchasedOn))
            }
            GridRow {
                Text("Paid").foregroundStyle(.secondary)
                PurchasePriceField(price: field(item, \.price))
            }
        }
        .font(.callout)
        .padding(.leading, 80).padding(.vertical, 6)
    }

    private func field<T: Equatable>(_ item: CollectionItem, _ path: WritableKeyPath<CollectionItem, T>) -> Binding<T> {
        Binding(get: { (model.item(id: item.id) ?? item)[keyPath: path] },
                set: { value in model.changeItem(id: item.id) { $0[keyPath: path] = value } })
    }

    /// "Yours since 2009 · 34 plays · $0.41 a play" (what every copy cost, over the album's plays).
    private func summary(_ copies: [CollectionItem]) -> String? {
        var parts: [String] = []
        if let first = copies.compactMap(\.purchasedOn).min() {
            parts.append("Yours since \(first.date().formatted(.relative(presentation: .named)))")
        }
        if plays > 0 { parts.append(plays == 1 ? "1 play" : "\(plays.formatted()) plays") }
        let spent = copies.compactMap(\.price).reduce(Decimal(0), +)
        if spent > 0, plays > 0 { parts.append("\(formatMoney(spent / Decimal(plays))) a play") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Add Existing Item… on an album page: an item in your collection with no music in the library yet (an unripped
/// CD, a record, a download not imported), to link to this album, with how the music relates to it. Items titled
/// like the album come first. Only what the user picks is changed: the item's album key and digital source.
struct AddExistingItemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: AlbumSummary
    @State private var query = ""
    @State private var selection: String?
    @State private var source: DigitalSource = .same

    var body: some View {
        let (suggested, others) = candidates
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Existing Item").font(.title2.bold())
            Text("Which item you own is a copy of “\(album.album)”? Items with music of their own aren't listed.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search what you own", text: $query, prompt: Text("Search what you own"))
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                if !suggested.isEmpty { Section("Suggestions") { ForEach(suggested) { row($0) } } }
                Section(query.isEmpty ? "Without Music" : "Matching “\(query)”") { ForEach(others) { row($0) } }
            }
            .frame(minHeight: 260)
            .overlay {
                if suggested.isEmpty && others.isEmpty {
                    Text("Everything you own has music in your digital collection.").foregroundStyle(.secondary)
                }
            }
            if let item = selectedItem {
                Picker("This album is", selection: $source) {
                    ForEach(LinkAlbumPicker.sources(for: item.medium), id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.radioGroup)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedItem == nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
        .onAppear { selection = suggested.first?.id }
        .onChange(of: selection) {
            if let item = selectedItem { source = item.digitalSource ?? LinkAlbumPicker.defaultSource(item.medium) }
        }
    }

    private var selectedItem: CollectionItem? { selection.flatMap { model.item(id: $0) } }

    /// Items with no music, those titled like the album (by a compatible artist) first, then the rest matching the
    /// search.
    private var candidates: (suggested: [CollectionItem], others: [CollectionItem]) {
        let key = AlbumInfoStore.key(album)
        let open = model.collection.items.filter { item in
            item.isEditable && item.albumKey != key && model.collection.libraryTracks(item).isEmpty
        }
        let title = TextNormalizer.normalize(album.album), artist = TextNormalizer.normalize(album.artist)
        func alike(_ item: CollectionItem) -> Bool {
            let a = TextNormalizer.normalize(item.artist)
            return TextNormalizer.normalize(item.album) == title && (artist.isEmpty || a.isEmpty || a.contains(artist) || artist.contains(a))
        }
        let q = TextNormalizer.normalize(query)
        let suggested = q.isEmpty ? open.filter(alike) : []
        let rest = open.filter { item in
            !suggested.contains(where: { $0.id == item.id })
                && (q.isEmpty || TextNormalizer.normalize("\(item.album) \(item.artist) \(item.sticker?.text ?? "")").contains(q))
        }
        return (suggested, rest)
    }

    private func row(_ item: CollectionItem) -> some View {
        HStack(spacing: 10) {
            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 40, revision: model.coverRevision,
                    title: item.album)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                Text([item.artist, item.year.map(String.init), item.formatDetail ?? item.medium.name].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let s = item.sticker { StickerPill(sticker: s, size: 10) }
        }
        .tag(item.id)
    }

    private func link() {
        guard let item = selectedItem else { return }
        let key = AlbumInfoStore.key(album), source = self.source
        model.changeItem(id: item.id) {
            $0.albumKey = key
            $0.digitalSource = source
        }
        dismiss()
    }
}
