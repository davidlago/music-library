import AppKit
import MusicLibraryCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var importer = model.importer
        HSplitView {
            List(selection: $importer.selection) {
                ForEach(importer.entries) { entry in
                    ImportRow(entry: entry).tag(entry.id)
                        .contextMenu { Button("Remove") { importer.remove(entry) } }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            .themedScrollBackground()
            .safeAreaInset(edge: .bottom) {
                if !importer.batch.isEmpty {
                    VStack(spacing: 0) {
                        ImportCollectionBar(importer: importer, model: model)
                        Divider()
                        ImportBatchPurchaseBar(importer: importer)
                    }
                }
            }
            .overlay {
                if importer.entries.isEmpty {
                    ContentUnavailableView("Nothing to Import", systemImage: "square.and.arrow.down",
                                           description: Text("Drop audio files or folders anywhere in the window, or press ⌘O."))
                        .allowsHitTesting(false)
                }
            }
            Group {
                if let entry = importer.selectedEntry {
                    ImportDetail(entry: entry).id(entry.id)
                } else {
                    ContentUnavailableView("Select an item", systemImage: "music.note")
                }
            }
            .frame(minWidth: 480)
        }
        .navigationTitle("Import")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Files…", systemImage: "plus") { model.chooseFilesToImport() }
                Button("Import All Ready (\(importer.readyCount))", systemImage: "square.and.arrow.down.on.square") {
                    Task { await importer.importAllReady() }
                }
                .disabled(importer.readyCount == 0)
                Button("Clear Finished", systemImage: "trash") { importer.clearFinished() }
            }
        }
    }
}

struct ImportRow: View {
    let entry: ImportEntry

    var color: Color {
        switch entry.status {
        case .ready, .done: return .green
        case .failed: return .red
        case .duplicate: return .orange
        case .needsReview: return .yellow
        default: return .secondary
        }
    }

    var body: some View {
        HStack {
            if case .matching = entry.status { ProgressView().controlSize(.small) }
            else if case .importing = entry.status { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle).lineLimit(1)
                Text(entry.metadata.artist.isEmpty ? entry.url.lastPathComponent : entry.metadata.artist)
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                Text(entry.status.label).font(.caption2).foregroundStyle(color).lineLimit(2)
            }
        }
    }
}

struct ImportDetail: View {
    @Environment(AppModel.self) private var model
    @Bindable var entry: ImportEntry
    @State private var pick: String?

    private var importer: ImportController { model.importer }
    private var editable: Bool { entry.status != .importing && entry.status != .done && entry.status != .duplicate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        form.disabled(!editable)
                        purchase
                    }
                    coverColumn.disabled(!editable)
                }
                candidatesSection.disabled(!editable)
                actions
            }
            .padding(20)
        }
        .onAppear { pick = entry.selectedCandidateID }
    }

    /// What you paid for the song and when; editable after it's imported too, and for a duplicate of a song in the
    /// library (saved at once to the library's copy).
    @ViewBuilder
    private var purchase: some View {
        // An imported song's price is elsewhere only when it went to an item; one still waiting follows its batch.
        if entry.status == .done ? entry.pricedOnItem : importer.songsPricedElsewhere && entry.status != .duplicate {
            Text(importer.boughtAsAlbum && importer.effectiveLinkItem == nil
                 ? "Bought as a whole album: what you paid is below the list." : "What you paid is on your copy in the collection.")
                .font(.caption).foregroundStyle(.subtext)
        } else {
            songPurchase
        }
    }

    private var songPurchase: some View {
        Form {
            LabeledContent("Paid") {
                PurchasePriceField(price: Binding(get: { entry.price }, set: { price in
                    // A price usually means you just bought it.
                    let day = entry.purchasedOn ?? (entry.price == nil && price != nil ? PurchaseDay(Date()) : nil)
                    importer.setPurchase(entry, price: price, day: day)
                }))
            }
            .help("What you paid for this song, if you bought it")
            LabeledContent("Bought") {
                PurchaseDateField(day: Binding(get: { entry.purchasedOn }, set: { importer.setPurchase(entry, price: entry.price, day: $0) }))
            }
        }
        .disabled(entry.status == .importing || (entry.status == .duplicate && entry.trackID == nil))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.url.lastPathComponent).font(.title3.bold()).lineLimit(1)
            Text(entry.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            HStack {
                Text(entry.status.label).foregroundStyle(.subtext)
                if let note = entry.note { Text("· \(note)").foregroundStyle(.subtext) }
            }
            .font(.callout)
        }
    }

    private var form: some View {
        Form {
            TextField("Title", text: $entry.metadata.title)
            TextField("Artist", text: $entry.metadata.artist)
            TextField("Album", text: $entry.metadata.album)
            TextField("Album Artist", text: $entry.metadata.albumArtist)
            TextField("Year", value: $entry.metadata.year, format: .number.grouping(.never))
            HStack {
                TextField("Track", value: $entry.metadata.trackNo, format: .number.grouping(.never))
                TextField("of", value: $entry.metadata.trackTotal, format: .number.grouping(.never))
            }
            HStack {
                TextField("Disc", value: $entry.metadata.discNo, format: .number.grouping(.never))
                TextField("of", value: $entry.metadata.discTotal, format: .number.grouping(.never))
            }
            TextField("Genre", text: $entry.metadata.genre)
            TextField("Composer", text: $entry.metadata.composer)
            TextField("Lyricist", text: $entry.metadata.extended.lyricist)
            TextField("Record label", text: $entry.metadata.extended.label)
            TextField("Catalog #", text: $entry.metadata.extended.catalogNumber)
            DisclosureGroup("More details & credits") {
                MetadataDetailsView(metadata: entry.metadata) { model.showMusicDNA($0) }.padding(.top, 4)
            }
        }
        .frame(minWidth: 280)
    }

    private var coverColumn: some View {
        VStack(spacing: 8) {
            DataImage(data: entry.previewCover, size: 170)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    importer.setCover(entry, from: u)
                    return true
                }
            Text(entry.cover != nil ? "New cover" : (entry.item?.embeddedCover != nil ? "Embedded cover" : "No cover"))
                .font(.caption).foregroundStyle(.subtext)
            HStack {
                Button("Choose Image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let u = panel.url { importer.setCover(entry, from: u) }
                }
                if entry.cover != nil { Button("Reset") { entry.cover = nil } }
            }
            .controlSize(.small)
        }
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matches").font(.headline)
            HStack {
                TextField("Title", text: $entry.searchTitle)
                TextField("Artist", text: $entry.searchArtist)
                TextField("Album", text: $entry.searchAlbum)
                Button("Search") { Task { await importer.search(entry) } }
                    .disabled(entry.status == .matching)
                if model.acoustID != nil {
                    Button("Fingerprint") { Task { await importer.fingerprint(entry) } }
                        .disabled(entry.status == .matching)
                        .help("Identify this file with AcoustID")
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await importer.search(entry) } }

            Table(entry.candidates, selection: $pick) {
                TableColumn("") { c in CandidateThumb(candidate: c, importer: importer) }.width(40)
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("Year") { Text($0.year.map(String.init) ?? "") }.width(45)
                TableColumn("Type") { Text(([$0.releaseType, $0.releaseStatus].compactMap { $0 } + $0.secondaryTypes).joined(separator: " · ")) }.width(150)
                TableColumn("Score") { Text("\($0.score)").monospacedDigit() }.width(45)
            }
            .frame(height: 260)
            .themedScrollBackground()
            .onChange(of: pick) {
                if let id = pick, let c = entry.candidates.first(where: { $0.id == id }), id != entry.selectedCandidateID {
                    Task { await importer.choose(entry, candidate: c) }
                }
            }
            .overlay {
                if entry.candidates.isEmpty && entry.status != .matching {
                    Text("No matches. Edit the search fields and press Search.").foregroundStyle(.subtext).allowsHitTesting(false)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            if let release = entry.appliedRelease {
                Button("Apply “\(release.album)” to other queued items") { importer.applyRelease(of: entry) }
            }
            Spacer()
            Button("Remove", role: .destructive) { importer.remove(entry) }
            // ⌘Return, so Return in a text field (a price, say) doesn't import the song.
            Button("Import") { Task { await importer.importEntry(entry) } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!entry.canImport || entry.metadata.title.isEmpty)
        }
    }
}

/// Below the import list: what you paid for all its songs (bought together, like a whole album), split evenly across
/// them as you type, and when. Changing a song's own price changes the total. Bought as a whole album, it's the
/// price of one album download in your collection instead. Not shown when the files are the digital copy of an item
/// in your collection: what you paid is on it.
struct ImportBatchPurchaseBar: View {
    let importer: ImportController

    var body: some View {
        @Bindable var importer = importer
        let count = importer.batch.count
        VStack(alignment: .leading, spacing: 8) {
            if importer.songsPricedElsewhere, let item = importer.effectiveLinkItem {
                Text("What you paid is on \(item.sticker?.text ?? "your \(item.medium.name.lowercased())")'s page in your collection.")
                    .font(.caption).foregroundStyle(.subtext)
            } else {
                if importer.canBuyAsAlbum {
                    HStack {
                        Text("Bought as").font(.callout.weight(.semibold))
                        Picker("Bought as", selection: $importer.boughtAsAlbum) {
                            Text("Songs").tag(false)
                            Text("Whole album").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("A whole album is saved as one download in your collection, with its date and price")
                    }
                }
                if importer.boughtAsAlbum && importer.canBuyAsAlbum {
                    HStack(spacing: 8) {
                        PurchasePriceField(price: Binding(get: { importer.albumPurchase.price },
                                                          set: { importer.setAlbumPurchase(price: $0, day: importer.albumPurchase.day) }))
                        PurchaseDateField(day: Binding(get: { importer.albumPurchase.day },
                                                       set: { importer.setAlbumPurchase(price: importer.albumPurchase.price, day: $0) }))
                    }
                    .help("What the album cost and when you bought it")
                } else {
                    Text(count == 1 ? "Paid for this song" : "Paid for all \(count) songs").font(.caption).foregroundStyle(.subtext)
                    HStack(spacing: 8) {
                        PurchasePriceField(price: Binding(get: { importer.batchTotal }, set: { importer.setBatchTotal($0, day: importer.batchDay ?? PurchaseDay(Date())) }))
                        PurchaseDateField(day: Binding(get: { importer.batchDay }, set: { importer.setBatchDay($0) }))
                    }
                    .help("Split evenly across the songs; each song's own price can still be changed")
                    if let note = note(), count > 1 {
                        Text(note).font(.caption).foregroundStyle(.subtext)
                    }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }

    /// "$0.79 each" for an even split, else how many songs have a price.
    private func note() -> String? {
        let prices = importer.batch.map(\.price)
        let known = prices.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        if known.count < prices.count { return "\(known.count) of \(prices.count) songs have a price" }
        guard let low = known.min(), let high = known.max() else { return nil }
        if low == high { return "\(formatMoney(low)) each" }
        return high - low <= Decimal(string: "0.01")! ? "About \(formatMoney(high)) each" : nil
    }
}

/// Shown in a `Table` cell, so it gets the importer from its parent rather than the environment (see `PersonLink`).
struct CandidateThumb: View {
    let candidate: MatchCandidate
    let importer: ImportController
    @State private var data: Data?

    var body: some View {
        DataImage(data: data, size: 32)
            .task(id: candidate.id) { data = await importer.thumbnail(for: candidate) }
    }
}

/// Above the batch's purchase: "These files are the digital copy of: [None ▾]", a CD or record in your collection
/// that isn't digitized yet (the ones that are this release or album first, picked until you choose), and whether
/// they were digitized from it or came with it as a download. Once a song is imported, the item is linked to its
/// album. Hidden while nothing in the collection waits to be digitized.
struct ImportCollectionBar: View {
    let importer: ImportController
    /// Passed in, like the importer: the bar sits over a `List`.
    let model: AppModel
    @State private var picking = false

    var body: some View {
        @Bindable var importer = importer
        let linked = importer.effectiveLinkItem
        let candidates = importer.linkCandidates
        if linked != nil || !candidates.matching.isEmpty || !candidates.others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(importer.hasSeveralBatches ? "The selected song's batch is the digital copy of" : "These files are the digital copy of")
                    .font(.callout.weight(.semibold))
                Button { picking = true } label: {
                    HStack(spacing: 6) {
                        if let linked {
                            if let s = linked.sticker { StickerPill(sticker: s, size: 9) }
                            Text(linked.album.isEmpty ? "Unknown Album" : linked.album).lineLimit(1)
                        } else {
                            Text("None")
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.subtext)
                    }
                }
                .help(linked.map { "\($0.album) — \($0.artist)" } ?? "Pick the CD or record these files were digitized from")
                .popover(isPresented: $picking, arrowEdge: .trailing) {
                    ImportLinkPicker(importer: importer, model: model) { picking = false }
                }
                if let linked {
                    Picker("Source", selection: $importer.linkSource) {
                        Text(linked.medium == .cd ? "Ripped from this CD" : "Digitized from this record").tag(DigitalSource.rip)
                        Text("Came with it as a download").tag(DigitalSource.download)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    .font(.caption)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.bar)
        }
    }
}

/// The items the batch can be the digital copy of: matches first, then a search of the rest, and None.
struct ImportLinkPicker: View {
    let importer: ImportController
    let model: AppModel
    let done: () -> Void
    @State private var query = ""

    var body: some View {
        let candidates = importer.linkCandidates
        let q = TextNormalizer.normalize(query)
        let others = q.isEmpty ? candidates.others : candidates.others.filter {
            TextNormalizer.normalize("\($0.album) \($0.artist) \($0.sticker?.text ?? "")").contains(q)
        }
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search your collection", text: $query, prompt: Text("Search CDs and records not digitized"))
                .textFieldStyle(.roundedBorder)
            List {
                Button("None") { importer.chooseLink(nil); done() }.buttonStyle(.plain)
                if !candidates.matching.isEmpty {
                    Section("This Album") { ForEach(candidates.matching) { row($0) } }
                }
                Section("Not Digitized Yet") { ForEach(others.prefix(200)) { row($0) } }
            }
            .frame(width: 380, height: 360)
        }
        .padding(10)
    }

    private func row(_ item: CollectionItem) -> some View {
        Button {
            importer.chooseLink(item)
            done()
        } label: {
            HStack(spacing: 8) {
                CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 34, revision: model.coverRevision,
                        title: item.album)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                    Text([item.artist, item.formatDetail ?? item.medium.name].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                }
                Spacer()
                if let s = item.sticker { StickerPill(sticker: s, size: 9) }
                if importer.effectiveLinkItem?.id == item.id { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
