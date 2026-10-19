import MusicLibraryCore
import SwiftUI

// MARK: Your Copy

/// Your copy's details on its page (medium, label, purchase, release), edited inline. Every change is saved on its
/// own through `AppModel.changeItem`, which applies it to the item as saved just then, so nothing else about it
/// changes. A download made of songs bought on their own is read-only (and can become an album download), as is an
/// item of a medium a newer version added.
struct CollectionItemEditor: View {
    @Environment(AppModel.self) private var model
    let item: CollectionItem
    /// The label each series had before the medium was switched away from it, given back on switching back (while
    /// it's still free), so trying another medium doesn't lose the number.
    @State private var earlier: [StickerSeries: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.origin == .songs {
                derived
            } else if !item.isEditable {
                Label("Added by a newer version of Music Library", systemImage: "shippingbox")
                    .font(.callout).foregroundStyle(.subtext)
                readOnlyDetails
            } else {
                editor
            }
            if let summary {
                Text(summary).font(.caption).foregroundStyle(.subtext)
            }
        }
    }

    // MARK: Editable

    private var editor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Medium").foregroundStyle(.subtext)
                Picker("Medium", selection: mediumBinding) {
                    ForEach(CollectionMedium.known, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Changing between CD and vinyl clears the label: each has its own numbers")
            }
            if let series = item.medium.series {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Label").foregroundStyle(.subtext)
                    StickerField(series: series, number: binding(\.stickerNumber), itemID: item.id)
                }
            }
            GridRow {
                Text("Bought").foregroundStyle(.subtext)
                PurchaseDateField(day: binding(\.purchasedOn))
            }
            GridRow {
                Text("Paid").foregroundStyle(.subtext)
                PurchasePriceField(price: binding(\.price))
            }
            GridRow(alignment: .firstTextBaseline) {
                Text("Notes").foregroundStyle(.subtext)
                CommitTextField(title: "Notes", value: item.notes, prompt: "Where you got it, its condition…", axis: .vertical) { v in
                    model.changeItem(id: item.id) { $0.notes = v }
                }
                .frame(maxWidth: 360)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            textRow("Record label", \.recordLabel, prompt: "Columbia")
            textRow("Cat. No.", \.catalogNumber, prompt: "CL 1355")
            textRow("Barcode", \.barcode, prompt: "Digits only", help: "6 to 20 digits, from under the barcode")
            textRow("Country", \.country, prompt: "US")
            textRow("Media", \.formatDetail, prompt: item.medium == .vinyl ? "12\" Vinyl" : "CD")
            GridRow {
                Text("Discs").foregroundStyle(.subtext)
                CommitTextField(title: "Discs", value: item.discCount.map(String.init), prompt: "1", width: 60) { v in
                    model.changeItem(id: item.id) { $0.discCount = v.flatMap { Int($0) }.flatMap { (1...99).contains($0) ? $0 : nil } }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Button("Change Edition…") { model.collectionSheet = .changeEdition(itemID: item.id) }
                    .help("Pick the edition you own on MusicBrainz: its record label, catalog number, barcode and media replace these")
            }
        }
        .font(.callout)
    }

    private func textRow(_ title: String, _ path: WritableKeyPath<CollectionItem, String?>, prompt: String, help: String? = nil) -> some View {
        GridRow {
            Text(title).foregroundStyle(.subtext)
            CommitTextField(title: title, value: item[keyPath: path], prompt: prompt, width: 240) { v in
                let value = path == \CollectionItem.barcode ? v?.filter(\.isNumber) : v
                model.changeItem(id: item.id) { $0[keyPath: path] = value }
            }
            .help(help ?? "")
        }
    }

    /// The medium; switching between CD and vinyl clears the label (each has its own numbers) and brings back the one
    /// it had in the other series earlier on this page.
    private var mediumBinding: Binding<CollectionMedium> {
        Binding(get: { (model.item(id: item.id) ?? item).medium },
                set: { medium in
                    let current = model.item(id: item.id) ?? item
                    if let s = current.sticker { earlier[s.series] = s.number }
                    let restore = medium.series.flatMap { series in
                        earlier[series].flatMap { n in
                            Sticker(series: series, number: n).flatMap { model.itemLabeled($0, excluding: item.id) == nil ? n : nil }
                        }
                    }
                    model.changeItem(id: item.id) {
                        $0.medium = medium
                        if let restore, $0.stickerNumber == nil { $0.stickerNumber = restore }
                    }
                })
    }

    /// A field of the item; every change is saved at once.
    private func binding<T: Equatable>(_ path: WritableKeyPath<CollectionItem, T>) -> Binding<T> {
        Binding(get: { (model.item(id: item.id) ?? item)[keyPath: path] },
                set: { value in model.changeItem(id: item.id) { $0[keyPath: path] = value } })
    }

    // MARK: Read-only

    /// A download made of songs bought on their own (entered on the Import page).
    private var derived: some View {
        VStack(alignment: .leading, spacing: 8) {
            let state = model.collection.digitalState(item)
            if case .partial(let have, let of) = state {
                Text("Made of the \(have) of \(of) songs you bought as downloads.").font(.callout)
            } else {
                Text("Made of the songs you bought as downloads.").font(.callout)
            }
            readOnlyDetails
            Button("Make It an Album Download") { makeAlbumDownload() }
                .help("Save it as an album you bought as a download, with its own date and price. The songs' purchases stay as they are.")
        }
    }

    private var readOnlyDetails: some View {
        let rows: [(String, String)] = [
            ("Medium", item.formatDetail ?? item.medium.name),
            ("Label", item.sticker?.text), ("Bought", item.purchasedOn.map { $0.date().formatted(date: .long, time: .omitted) }),
            ("Paid", item.price.map { formatMoney($0) }), ("Record label", item.recordLabel), ("Cat. No.", item.catalogNumber),
            ("Barcode", item.barcode), ("Country", item.country), ("Notes", item.notes),
        ].compactMap { k, v in v.map { (k, $0) } }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { k, v in
                GridRow {
                    Text(k).foregroundStyle(.subtext)
                    Text(v).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }

    private func makeAlbumDownload() {
        var album = CollectionItem(medium: .download, album: item.album, artist: item.artist, albumKey: item.albumKey)
        album.year = item.year
        album.releaseID = item.releaseID
        album.trackCount = item.trackCount
        album.purchasedOn = item.purchasedOn
        album.price = item.price
        album.digitalSource = .download
        guard let saved = model.saveItem(album) else { return }
        if !model.navigationPath.isEmpty { model.navigationPath.removeLast() }
        model.navigationPath.append(CollectionItemRoute(id: saved.id))
    }

    /// "Yours since 2009 · 34 plays · $0.41 a play".
    private var summary: String? {
        var parts: [String] = []
        if let day = item.purchasedOn { parts.append("Yours since \(day.date().formatted(.relative(presentation: .named)))") }
        let songs = model.collection.libraryTracks(item)
        let plays = songs.reduce(0) { $0 + (model.playTotals[$1.id]?.plays ?? 0) }
        if model.collection.digitalState(item).hasMusic, plays > 0 {
            parts.append(plays == 1 ? "1 play" : "\(plays.formatted()) plays")
            if let price = item.price, price > 0 { parts.append("\(formatMoney(price / Decimal(plays))) a play") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A text field saved when you press Return or leave it (not on every keystroke), with empty text as none. It
/// follows the saved value while not being edited.
struct CommitTextField: View {
    let title: String
    let value: String?
    var prompt = ""
    var width: CGFloat?
    var axis: Axis = .horizontal
    let commit: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt), axis: axis)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .lineLimit(axis == .vertical ? 1...6 : 1...1)
            .frame(width: width)
            .focused($focused)
            .onSubmit(save)
            .onAppear { text = value ?? "" }
            .onChange(of: value) { if !focused { text = value ?? "" } }
            .onChange(of: focused) { if !focused { save() } }
            .onDisappear(perform: save)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = t.isEmpty ? nil : t
        if new != value { commit(new) }
    }
}

// MARK: Label number

/// A label number in one series. Empty, it offers the next number; a number another item in the series already has
/// is refused (D7), with the next and the first free number offered instead. A duplicate saved before (by an older
/// version) is pointed out but kept.
///
/// By default the number is set when you press Return or leave the field (each change saves an item's page). `live`
/// sets it as you type, for a form saved by a button: a taken number is set too, and refused again when saving.
struct StickerField: View {
    @Environment(AppModel.self) private var model
    let series: StickerSeries
    @Binding var number: Int?
    /// The item being edited, which doesn't count as taking its own number.
    var itemID: String?
    var live = false
    @State private var text = ""
    @State private var refused: (number: Int, by: CollectionItem)?
    @FocusState private var focused: Bool

    var body: some View {
        let next = model.nextNumber(in: series)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(series == .cd ? "CD #" : "Vinyl #").foregroundStyle(.subtext)
                TextField("Label number", text: $text, prompt: Text(String(next)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .monospacedDigit()
                    .frame(width: 90)
                    .focused($focused)
                    .onSubmit(commit)
                    .help("The number on the label you put on this \(series == .cd ? "CD's case" : "record's sleeve")")
                if refused == nil {
                    if number == nil {
                        Button("Use #\(next)") { set(next) }.help("The next number in your \(series.name) labels")
                    } else if let n = number, let sticker = Sticker(series: series, number: n),
                              let other = model.itemLabeled(sticker, excluding: itemID) {
                        Label("Also on \(other.album)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(1)
                            .help("\(sticker.text) is on “\(other.album)” by \(other.artist) too. Give one of them another number.")
                    }
                }
            }
            if let refused {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(series.name) #\(refused.number) is taken by “\(refused.by.album)”\(refused.by.artist.isEmpty ? "" : " · \(refused.by.artist)")",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Use #\(next) (next)") { set(next) }
                        if let gap = firstFree(), gap != next { Button("Use #\(gap) (first free)") { set(gap) } }
                        if !live {
                            Button("Cancel") { self.refused = nil; text = Self.format(number) }.buttonStyle(.link)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { text = Self.format(number) }
        .onChange(of: number) { if !focused, Self.parse(text) != number { text = Self.format(number) } }
        .onChange(of: text) { if live { commit() } }
        .onChange(of: focused) { if !focused, refused == nil { commit() } }
        .onChange(of: series) { refused = nil; text = Self.format(number) }
        .onDisappear { if !live, refused == nil, Self.parse(text) != number, !text.isEmpty || number != nil { commit() } }
    }

    private func commit() {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            refused = nil
            if number != nil { number = nil }
            return
        }
        guard let n = Self.parse(s), let sticker = Sticker(series: series, number: n) else {
            if !live { text = Self.format(number) }
            return
        }
        if let other = model.itemLabeled(sticker, excluding: itemID) {
            // Unchanged, an old duplicate stays as it was; a new one is refused.
            guard n != number || live else { refused = nil; return }
            refused = (n, other)
            if live, number != n { number = n }
            return
        }
        refused = nil
        if number != n { number = n }
    }

    private func set(_ n: Int) {
        refused = nil
        text = String(n)
        number = n
    }

    /// The lowest number below the highest one that nothing has.
    private func firstFree() -> Int? {
        for gap in model.collection.gaps(in: series) {
            for n in gap {
                guard let sticker = Sticker(series: series, number: n) else { continue }
                if model.itemLabeled(sticker, excluding: itemID) == nil { return n }
            }
        }
        return nil
    }

    static func format(_ n: Int?) -> String { n.map(String.init) ?? "" }

    /// "12", "#12".
    static func parse(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")))
    }
}

// MARK: Linking

/// Link to Library Album…: which album in the library is this item's digital copy. `CollectionLinker.suggestions`
/// (the same release, its release group, then the same title by a compatible artist) come first, then a search of
/// every album; and how the music relates to your copy (ripped from it, came with it, or the same music from
/// elsewhere). Only ever what the user picks: suggestions aren't applied on their own.
struct LinkAlbumPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @State private var query = ""
    @State private var suggestions: [AlbumSummary] = []
    @State private var selection: AlbumSummary.ID?
    @State private var source: DigitalSource = .rip

    var body: some View {
        if let item = model.item(id: itemID) {
            content(item)
        } else {
            VStack {
                ContentUnavailableView("Not in your collection", systemImage: "books.vertical")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20).frame(width: 480, height: 300)
        }
    }

    private func content(_ item: CollectionItem) -> some View {
        let matching = matches
        return VStack(alignment: .leading, spacing: 12) {
            Text("Link to a Library Album").font(.title2.bold())
            HStack(spacing: 6) {
                Text("Which album in your library is the digital copy of").foregroundStyle(.subtext)
                if let s = item.sticker { StickerPill(sticker: s, size: 10) }
                Text("“\(item.album)”?").lineLimit(1)
            }
            .font(.callout)
            TextField("Search your albums", text: $query, prompt: Text("Search your albums"))
                .textFieldStyle(.roundedBorder)
            List(selection: $selection) {
                if query.isEmpty, !suggestions.isEmpty {
                    Section("Suggestions") { ForEach(suggestions) { row($0, item: item) } }
                }
                Section(query.isEmpty ? "All Albums" : "Matching “\(query)”") {
                    ForEach(matching) { row($0, item: item) }
                }
            }
            .frame(minHeight: 260)
            Picker("This album is", selection: $source) {
                ForEach(Self.sources(for: item.medium), id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Button("Unlink") {
                    model.unlink(itemID: item.id)
                    dismiss()
                }
                .disabled(!model.canUnlink(item))
                .help(model.canUnlink(item) || model.collection.libraryTracks(item).isEmpty
                      ? "No longer link it to a library album" : "Songs titled like it are in your library: link it to another album instead")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { link(item) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedAlbum == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear {
            source = item.digitalSource ?? Self.defaultSource(item.medium)
            suggestions = Array(CollectionLinker.suggestions(for: item, albums: model.albums, tracks: model.tracks).prefix(8))
            if let linked = model.linkedAlbum(for: item) { selection = linked.id }
            else { selection = suggestions.first?.id }
        }
    }

    private var matches: [AlbumSummary] {
        let q = TextNormalizer.normalize(query)
        guard !q.isEmpty else { return model.albums }
        return model.albums.filter { TextNormalizer.normalize("\($0.album) \($0.artist)").contains(q) }
    }

    private var selectedAlbum: AlbumSummary? {
        guard let selection else { return nil }
        return model.albums.first { $0.id == selection }
    }

    private func row(_ album: AlbumSummary, item: CollectionItem) -> some View {
        HStack(spacing: 10) {
            CoverThumb(url: model.coverURL(forAlbum: album), size: 36, revision: model.coverRevision, cornerRadius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.album.isEmpty ? "Unknown Album" : album.album).lineLimit(1)
                Text([album.artist, album.year.map(String.init), songCount(album.trackCount)].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
            Spacer()
            if AlbumInfoStore.key(album) == item.albumKey, !model.collection.libraryTracks(item).isEmpty {
                Text("Linked").font(.caption).foregroundStyle(.subtext)
            } else if let other = model.collection.copies(albumKey: AlbumInfoStore.key(album)).first {
                Text(other.sticker?.text ?? "Your \(other.medium.name.lowercased())").font(.caption).foregroundStyle(.subtext)
            }
        }
        .tag(album.id)
    }

    private func link(_ item: CollectionItem) {
        guard let album = selectedAlbum else { return }
        let key = AlbumInfoStore.key(album)
        let source = self.source
        model.changeItem(id: item.id) {
            $0.albumKey = key
            $0.digitalSource = source
        }
        dismiss()
    }

    /// What a library album linked to an item usually is: a CD's rip, a download's files, the same music as a record.
    static func defaultSource(_ medium: CollectionMedium) -> DigitalSource {
        switch medium {
        case .cd: .rip
        case .download: .download
        case .vinyl, .other: .same
        }
    }

    /// The choices for how the music relates to the copy, in the medium's words.
    static func sources(for medium: CollectionMedium) -> [(DigitalSource, String)] {
        switch medium {
        case .cd: [(.rip, "Ripped from this CD"), (.download, "Came with it as a download"), (.same, "The same music from elsewhere")]
        case .vinyl, .other: [(.rip, "Digitized from this record"), (.download, "Came with it as a download"),
                              (.same, "The same music from elsewhere")]
        case .download: [(.download, "This download"), (.same, "The same music from elsewhere")]
        }
    }
}

// MARK: Bulk

/// Add Library Albums…: the library albums with no copy in your collection, to check off the ones you own, each as a
/// CD, a record or a download, numbered in the order shown, and added in one go (all or none).
struct BulkAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Row {
        var checked = false
        var medium: CollectionMedium = .cd
        var number: Int?
    }

    @State private var rows: [AlbumSummary.ID: Row] = [:]
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\AlbumSummary.artist), KeyPathComparator(\AlbumSummary.album)]
    @State private var message: String?
    /// The albums offered, fixed when the sheet opens (adding some doesn't make rows vanish).
    @State private var albums: [AlbumSummary] = []

    private var shown: [AlbumSummary] {
        let q = TextNormalizer.normalize(filter)
        let list = q.isEmpty ? albums : albums.filter { TextNormalizer.normalize("\($0.album) \($0.artist)").contains(q) }
        return list.sorted(using: sortOrder)
    }

    private var checked: [AlbumSummary] { shown.filter { rows[$0.id]?.checked == true } }

    var body: some View {
        let next = (cd: model.nextNumber(in: .cd), vinyl: model.nextNumber(in: .vinyl))
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Library Albums").font(.title2.bold())
            Text("Check the albums in your library that you own, and say how. Albums already in your collection aren't listed.")
                .font(.callout).foregroundStyle(.subtext)
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter albums"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Check All") { setChecked(true) }
                Button("Check None") { setChecked(false) }
                Spacer()
                Button("Number Them in This Order") { number() }
                    .disabled(checked.isEmpty)
                    .help("Gives the checked albums labels in the order shown: from CD #\(next.cd) and Vinyl #\(next.vinyl)")
            }
            .controlSize(.small)
            Table(shown, sortOrder: $sortOrder) {
                TableColumn("") { a in
                    Toggle("Add", isOn: rowBinding(a, \.checked)).labelsHidden().toggleStyle(.checkbox)
                }
                .width(22)
                TableColumn("") { a in
                    CoverThumb(url: model.coverURL(forAlbum: a), size: 28, revision: model.coverRevision, cornerRadius: 3)
                }
                .width(32)
                TableColumn("Album", value: \.album) { Text($0.album.isEmpty ? "Unknown Album" : $0.album) }
                TableColumn("Artist", value: \.artist)
                TableColumn("Year", value: \.yearValue) { Text($0.year.map(String.init) ?? "") }.width(46)
                TableColumn("Medium") { a in
                    Picker("Medium", selection: mediumBinding(a)) {
                        ForEach(CollectionMedium.known, id: \.self) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 90, ideal: 100)
                TableColumn("Label") { a in
                    if let series = (rows[a.id] ?? Row()).medium.series {
                        HStack(spacing: 2) {
                            Text(series == .cd ? "CD #" : "Vinyl #").font(.caption).foregroundStyle(.subtext)
                            // Set as typed (a number field only takes it on Return), and checked when adding.
                            TextField("Label", text: Binding(get: { StickerField.format(rows[a.id]?.number) },
                                                             set: { rows[a.id, default: Row()].number = StickerField.parse($0); message = nil }))
                                .textFieldStyle(.roundedBorder).labelsHidden().monospacedDigit()
                        }
                    }
                }
                .width(min: 90, ideal: 110)
            }
            .frame(minHeight: 320)
            HStack {
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).lineLimit(2)
                } else {
                    Text("\(checked.count) checked").font(.callout).foregroundStyle(.subtext)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(checked.count == 1 ? "Add 1 Item" : "Add \(checked.count) Items") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 820, height: 620)
        .onAppear {
            albums = model.albums.filter { a in
                !a.album.isEmpty && model.collection.copies(albumKey: AlbumInfoStore.key(a)).allSatisfy { $0.origin == .songs }
            }
        }
    }

    private func rowBinding<T>(_ a: AlbumSummary, _ path: WritableKeyPath<Row, T>) -> Binding<T> {
        Binding(get: { (rows[a.id] ?? Row())[keyPath: path] },
                set: { rows[a.id, default: Row()][keyPath: path] = $0; message = nil })
    }

    /// Changing between CD and vinyl drops the number: each has its own.
    private func mediumBinding(_ a: AlbumSummary) -> Binding<CollectionMedium> {
        Binding(get: { (rows[a.id] ?? Row()).medium },
                set: { medium in
                    var row = rows[a.id] ?? Row()
                    if row.medium.series != medium.series { row.number = nil }
                    row.medium = medium
                    row.checked = true
                    rows[a.id] = row
                    message = nil
                })
    }

    private func setChecked(_ on: Bool) {
        for a in shown { rows[a.id, default: Row()].checked = on }
    }

    /// Labels for the checked albums, in the order shown, from the next number of each series.
    private func number() {
        var next: [StickerSeries: Int] = [.cd: model.nextNumber(in: .cd), .vinyl: model.nextNumber(in: .vinyl)]
        for a in checked {
            guard let series = rows[a.id]?.medium.series, let n = next[series] else { continue }
            rows[a.id]?.number = n
            next[series] = n + 1
        }
        message = nil
    }

    private func add() {
        let chosen = checked
        // Every number once per series, and none another item already has (D7).
        var used: [Sticker: AlbumSummary] = [:]
        var items: [CollectionItem] = []
        for a in chosen {
            let row = rows[a.id] ?? Row()
            let number = row.medium.series == nil ? nil : row.number
            if let series = row.medium.series, let n = number {
                guard let sticker = Sticker(series: series, number: n) else {
                    message = "\(series.name) #\(n) isn't a label number."
                    return
                }
                if let other = used[sticker] {
                    message = "\(sticker.text) is given to both “\(other.album)” and “\(a.album)”."
                    return
                }
                if let other = model.itemLabeled(sticker, excluding: nil) {
                    message = "\(sticker.text) is taken by “\(other.album)”. Use #\(model.nextNumber(in: series, pending: Array(used.keys.filter { $0.series == series }.map(\.number)))) or later."
                    return
                }
                used[sticker] = a
            }
            items.append(CollectionDraft.item(album: a, tracks: model.tracks(of: a), medium: row.medium, sticker: number))
        }
        guard model.saveItems(items) else { return }
        dismiss()
    }
}

private extension AlbumSummary {
    var yearValue: Int { year ?? 0 }
}
