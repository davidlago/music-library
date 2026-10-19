import MusicLibraryCore
import SwiftUI

/// How the Shelf lays out its items.
enum CollectionLayout: String, CaseIterable {
    case grid, list
}

/// The Shelf's Show filter, on top of the scope and the query.
enum CollectionShow: String, CaseIterable, Identifiable {
    case any, digitized, notDigitized, unlabeled, needsDetails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any"
        case .digitized: "Digitized"
        case .notDigitized: "Not Digitized"
        case .unlabeled: "Unlabeled"
        case .needsDetails: "Needs Details"
        }
    }

    /// As the Collection pane's lists count them: needing details is no purchase day or price, or a physical copy
    /// without its label.
    func includes(_ item: CollectionItem, state: DigitalState) -> Bool {
        switch self {
        case .any: true
        case .digitized: state.hasMusic
        case .notDigitized: item.medium.isPhysical && state.needsDigitizing
        case .unlabeled: item.medium.series != nil && item.stickerNumber == nil
        case .needsDetails:
            (item.isEditable && (item.purchasedOn == nil || item.price == nil))
                || (item.medium.series != nil && item.stickerNumber == nil)
        }
    }
}

/// The Shelf (or one of its scopes: CDs, Vinyl, Downloads, To Digitize): everything you own, with or without songs
/// in the library, filtered by `AppModel.shelfQuery` in the collection query language. A header counts the shelf,
/// finds a label (Go to) and points out free and duplicate labels; the items show as a grid of cases and sleeves
/// (in sections of a hundred labels when sorted by label) or as a table.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let scope: CollectionScope
    @AppStorage("collectionLayout") private var layout = CollectionLayout.grid
    @AppStorage private var sort: CollectionSort
    @AppStorage("collectionShow") private var show = CollectionShow.any
    @AppStorage("collectionGoToSeries") private var goToSeries = StickerSeries.cd
    @State private var goToText = ""
    /// The label Go to found, shown as a card under the header.
    @State private var found: Sticker?
    /// The item Go to scrolled to, outlined for a moment.
    @State private var highlighted: String?
    @State private var selection = Set<CollectionItem.ID>()
    @State private var scrollTarget: String?

    init(scope: CollectionScope) {
        self.scope = scope
        // By label where the labels are the point (a medium, the pile to digitize); newest first for everything.
        let fallback: CollectionSort = scope == .all || scope == .downloads ? .added : .sticker
        _sort = AppStorage(wrappedValue: fallback, "collectionSort.\(scope.rawValue)")
    }

    var body: some View {
        let items = shown
        VStack(spacing: 0) {
            if model.collection.items.isEmpty {
                emptyShelf
            } else {
                header.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
                if let found {
                    LabelLookupCard(sticker: found, coverWidth: 110, open: { model.showItem(id: $0.id) },
                                    step: { self.found = $0; jump(to: $0) })
                        .overlay(alignment: .topTrailing) {
                            Button { self.found = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.subtext).padding(10)
                                .help("Close")
                        }
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                Divider().opacity(0.5)
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here", systemImage: scope.symbol)
                    } description: {
                        Text(model.shelfQuery.isEmpty && show == .any ? "No items in \(scope.title)." : "No items match the filter.")
                    } actions: {
                        if !model.shelfQuery.isEmpty || show != .any {
                            Button("Clear Filter") { model.shelfQuery = ""; show = .any }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else if layout == .list {
                    CollectionTable(model: model, items: items, selection: $selection)
                } else {
                    grid(items)
                }
            }
        }
        .background(theme.isThemed ? theme.background : Color.clear)
        .navigationTitle(scope.title)
        .navigationSubtitle(subtitle(items.count))
        .toolbar { toolbar }
    }

    private func subtitle(_ shown: Int) -> String {
        let total = model.collection.count(scope)
        let noun = total == 1 ? "item" : "items"
        return shown == total ? "\(total.formatted()) \(noun)" : "\(shown.formatted()) of \(total.formatted()) \(noun)"
    }

    /// The scope's items matching the filter and Show, in the chosen order.
    private var shown: [CollectionItem] {
        let query = model.shelfQuery.trimmingCharacters(in: .whitespaces)
        var list = model.collection.items(in: scope)
        if !query.isEmpty {
            let ids = Set(model.collectionIndex.search(query).map(\.id))
            list = list.filter { ids.contains($0.id) }
        }
        if show != .any {
            list = list.filter { show.includes($0, state: model.collection.digitalState($0)) }
        }
        return sort.sorted(list)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                counts
                Spacer(minLength: 12)
                labelCheckLink
            }
            HStack(spacing: 12) {
                filterField
                goTo
            }
        }
    }

    /// "312 CDs · 48 vinyl · 97 downloads · 9 to digitize", each opening its scope.
    private var counts: some View {
        let c = model.collection
        let parts: [(CollectionScope, String)] = [
            (.cds, c.count(.cds) == 1 ? "1 CD" : "\(c.count(.cds).formatted()) CDs"),
            (.vinyl, "\(c.count(.vinyl).formatted()) vinyl"),
            (.downloads, c.count(.downloads) == 1 ? "1 download" : "\(c.count(.downloads).formatted()) downloads"),
            (.toDigitize, "\(c.count(.toDigitize).formatted()) to digitize"),
        ]
        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("·").foregroundStyle(.subtext) }
                Button(part.1) { model.sidebar = .collection(part.0) }
                    .buttonStyle(.plain)
                    .fontWeight(part.0 == scope ? .semibold : .regular)
                    .foregroundStyle(part.0 == scope ? AnyShapeStyle(.primary) : AnyShapeStyle(.subtext))
                    .help("Show \(part.0.title)")
            }
        }
        .font(.callout)
    }

    /// "3 free · 1 duplicate", opening Label Check.
    @ViewBuilder
    private var labelCheckLink: some View {
        let c = model.collection
        let free = StickerSeries.allCases.reduce(0) { sum, s in sum + c.gaps(in: s).reduce(0) { $0 + $1.count } }
        let dups = StickerSeries.allCases.reduce(0) { $0 + c.duplicates(in: $1).count }
        if c.items.contains(where: { $0.sticker != nil }) {
            Button {
                model.collectionSheet = .labelCheck
            } label: {
                let parts = [free > 0 ? "\(free.formatted()) free" : nil,
                             dups > 0 ? "\(dups) duplicate\(dups == 1 ? "" : "s")" : nil].compactMap { $0 }
                Label(parts.isEmpty ? "Label Check" : parts.joined(separator: " · "),
                      systemImage: dups > 0 ? "exclamationmark.triangle" : "checklist")
            }
            .buttonStyle(.link)
            .font(.callout)
            .help("Free label numbers and numbers used twice, in each series")
        }
    }

    private var filterField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.subtext)
            TextField("Filter", text: $model.shelfQuery, prompt: Text("Filter: jazz, own:vinyl, ripped:no, bought:2024, #12…"))
                .textFieldStyle(.plain)
                .onSubmit {
                    // A label on its own jumps to it.
                    if let form = CollectionSearchQuery.labelForm(model.shelfQuery),
                       let sticker = Sticker(series: form.series ?? goToSeries, number: form.number) {
                        model.shelfQuery = ""
                        goTo(sticker)
                    }
                }
            if !model.shelfQuery.isEmpty {
                Button { model.shelfQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.subtext)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
        .frame(maxWidth: 460)
        .help("Search the collection: words match titles, artists, record labels, notes and track titles; keys like own:, ripped:, sticker:, bought:, paid: filter")
    }

    /// Go to: a series and a number ("cd 12" and "v12" work too), scrolling to the item and showing its card.
    private var goTo: some View {
        HStack(spacing: 6) {
            Text("Go to").foregroundStyle(.subtext)
            Picker("Series", selection: $goToSeries) {
                ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            TextField("Label", text: $goToText, prompt: Text("#"))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 72)
                .onSubmit {
                    guard let form = Sticker.parse(goToText),
                          let sticker = Sticker(series: form.series ?? goToSeries, number: form.number) else { return }
                    goToSeries = sticker.series
                    goToText = String(sticker.number)
                    goTo(sticker)
                }
        }
        .font(.callout)
        .help("Type a label number and press Return to find it on your shelf")
    }

    private func goTo(_ sticker: Sticker) {
        found = sticker
        jump(to: sticker)
    }

    /// Scrolls to the item with this label (when it's shown) and outlines it for a moment.
    private func jump(to sticker: Sticker) {
        guard let item = model.collection.items(at: sticker).first else { return }
        if !shown.contains(where: { $0.id == item.id }) {
            // Shown on the whole shelf instead, with nothing filtered out.
            if scope != .all, item.medium != scope.medium { return }
            model.shelfQuery = ""
            show = .any
        }
        selection = [item.id]
        scrollTarget = item.id
        withAnimation(.easeOut(duration: 0.2)) { highlighted = item.id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlighted == item.id { withAnimation(.easeOut(duration: 0.4)) { highlighted = nil } }
        }
    }

    // MARK: Grid

    private func grid(_ items: [CollectionItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20, alignment: .top)], alignment: .leading,
                          spacing: 24, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections(items)) { section in
                        Section {
                            ForEach(section.items) { item in cell(item) }
                        } header: {
                            if let title = section.title {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(title).font(.headline)
                                    if let detail = section.detail { Text(detail).font(.callout).foregroundStyle(.subtext) }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .background(theme.isThemed ? theme.background : Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .themedScrollBackground()
            .onChange(of: scrollTarget) {
                guard let id = scrollTarget else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                scrollTarget = nil
            }
        }
    }

    private func cell(_ item: CollectionItem) -> some View {
        NavigationLink(value: CollectionItemRoute(id: item.id)) {
            CollectionCell(item: item)
                .padding(6)
                .background {
                    if highlighted == item.id {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .id(item.id)
        .contextMenu { CollectionItemMenu(model: model, item: item) }
    }

    struct GridSection: Identifiable {
        var id: String
        var title: String?
        var detail: String?
        var items: [CollectionItem]
    }

    /// Sorted by label: a section per series and hundred ("CD 100–199 · 97 labeled · 3 free"), then the unlabeled
    /// items. Otherwise one untitled section.
    private func sections(_ items: [CollectionItem]) -> [GridSection] {
        guard sort == .sticker else { return [GridSection(id: "all", items: items)] }
        var out: [GridSection] = []
        var unlabeled: [CollectionItem] = []
        var current: (key: String, sticker: Sticker, items: [CollectionItem])?
        func close() {
            guard let c = current else { return }
            let low = c.sticker.number / 100 * 100, high = low + 99
            let range = max(low, 1)...high
            let free = model.collection.gaps(in: c.sticker.series).reduce(0) { n, gap in
                n + (gap.overlaps(range) ? gap.clamped(to: range).count : 0)
            }
            let detail = ["\(c.items.count) labeled", free > 0 ? "\(free) free" : nil].compactMap { $0 }.joined(separator: " · ")
            out.append(GridSection(id: c.key, title: "\(c.sticker.series.name) \(range.lowerBound)–\(range.upperBound)", detail: detail,
                                   items: c.items))
        }
        for item in items {
            guard let s = item.sticker else { unlabeled.append(item); continue }
            let key = "\(s.series.rawValue)-\(s.number / 100)"
            if current?.key == key {
                current?.items.append(item)
            } else {
                close()
                current = (key, s, [item])
            }
        }
        close()
        if !unlabeled.isEmpty { out.append(GridSection(id: "unlabeled", title: "Unlabeled", detail: "\(unlabeled.count)", items: unlabeled)) }
        return out
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(CollectionLayout.grid)
                Label("List", systemImage: "list.bullet").tag(CollectionLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show the shelf as a grid or a list")
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(CollectionSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort by \(sort.title.lowercased())")
            Menu {
                Picker("Show", selection: $show) {
                    ForEach(CollectionShow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Show", systemImage: show == .any ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Show only some items: digitized, not digitized, unlabeled or missing details")
            Menu {
                Button("Add CD…") { model.addToCollection(medium: .cd) }
                Button("Add Vinyl…") { model.addToCollection(medium: .vinyl) }
                Button("Add Download…") { model.addToCollection(medium: .download) }
                Divider()
                Button("Add Library Albums…") { model.collectionSheet = .addLibraryAlbums }
            } label: {
                Label("Add to Collection", systemImage: "plus")
            }
            .help("Add something you own to your collection")
        }
    }

    // MARK: Empty

    private var emptyShelf: some View {
        ContentUnavailableView {
            Label("Your shelf is empty", systemImage: "books.vertical")
        } description: {
            Text("Catalog the CDs, records and downloads you own, ripped or not, with the label number on each case.")
        } actions: {
            Button("Add to Collection…") { model.addToCollection() }
                .buttonStyle(.borderedProminent)
            if !model.albums.isEmpty {
                Button("Add Albums You Own from Your Library…") { model.collectionSheet = .addLibraryAlbums }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

extension CollectionScope {
    /// The medium the scope shows, if just one.
    var medium: CollectionMedium? {
        switch self {
        case .cds: .cd
        case .vinyl: .vinyl
        case .downloads: .download
        case .all, .toDigitize: nil
        }
    }
}

/// One item in the Shelf's grid: its case or sleeve, title, artist, and its label and digital status. Owned items are
/// never dimmed, digitized or not.
struct CollectionCell: View {
    @Environment(AppModel.self) private var model
    let item: CollectionItem
    var width: CGFloat = 150

    var body: some View {
        let mark = model.collection.mark(item: item)
        VStack(alignment: .leading, spacing: 4) {
            CopyArt(mark: mark, url: model.coverURL(for: item), width: width, revision: model.coverRevision, title: item.album)
                .padding(.bottom, 4)
            Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            HStack(spacing: 6) {
                if let sticker = item.sticker { StickerPill(sticker: sticker, size: 9) }
                let state = model.collection.digitalState(item)
                DigitalStatusLabel(state: state, medium: item.medium, from: from(state)).font(.caption2)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func from(_ state: DigitalState) -> CollectionItem? {
        if case .otherCopy(_, let id?) = state { return model.item(id: id) }
        return nil
    }
}

/// An item's context menu (Shelf grid and list, artist pages, search). It's given the model: in a `Table` it doesn't
/// always get it from the environment.
struct CollectionItemMenu: View {
    let model: AppModel
    let item: CollectionItem

    var body: some View {
        let state = model.collection.digitalState(item)
        Button("Open") { model.showItem(id: item.id) }
        if state.hasMusic, let album = model.linkedAlbum(for: item) {
            Button("Open Album in Library") { model.nowPlayingExpanded = false; model.navigationPath.append(album) }
            Divider()
            Button("Play") { model.play(item: item) }
            Button("Shuffle") { model.play(item: item, shuffled: true) }
            QueueMenuButtons(player: model.player) { model.collection.libraryTracks(item) }
            AddToExportListButton(album: album)
        }
        Divider()
        if let disc = model.discInDrive(for: item) {
            Button("Rip This CD") { model.cd.show(disc, for: item) }
        }
        if item.isEditable {
            Button("Link to Library Album…") { model.collectionSheet = .link(itemID: item.id) }
            Button("Change Cover…") { model.collectionSheet = .cover(itemID: item.id, request: CoverSheetRequest()) }
        }
        if item.medium == .cd {
            Button("Shop for This CD") {
                model.cdShop.shop(releaseId: item.releaseID, album: item.album, artist: item.artist)
                model.sidebar = .cdShop
            }
        }
        if item.isEditable {
            Divider()
            Button("Remove from Collection…", role: .destructive) { model.confirmItemRemoval(item) }
        }
    }
}

// MARK: List

private extension CollectionItem {
    /// CDs by number, then records, then the unlabeled.
    var labelSort: Int { sticker.map { ($0.series == .cd ? 0 : 1) * 10_000_000 + $0.number } ?? Int.max }
    var yearSort: Int { year ?? 0 }
    var mediumSort: String { medium.name + (formatDetail ?? "") }
    var boughtSort: String { purchasedOn?.string ?? "" }
    var priceSort: Decimal { price ?? -1 }
    var recordLabelSort: String { recordLabel ?? "" }
    var catalogNumberSort: String { catalogNumber ?? "" }
}

/// The Shelf as a list. Its cells never read the model from the environment (they don't always get it in a `Table`):
/// they're given it.
struct CollectionTable: View {
    let model: AppModel
    let items: [CollectionItem]
    @Binding var selection: Set<CollectionItem.ID>
    @State private var sortOrder: [KeyPathComparator<CollectionItem>] = []

    private var sorted: [CollectionItem] { sortOrder.isEmpty ? items : items.sorted(using: sortOrder) }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Label", value: \.labelSort) { item in
                if let sticker = item.sticker { StickerPill(sticker: sticker, size: 10) }
            }
            .width(min: 56, ideal: 80)
            TableColumn("Title", value: \.album)
            TableColumn("Artist", value: \.artist)
            TableColumn("Year", value: \.yearSort) { Text($0.year.map(String.init) ?? "") }.width(46)
            TableColumn("Medium", value: \.mediumSort) { item in
                Text(item.formatDetail.map { $0 } ?? item.medium.name).help(item.medium.name)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Digital") { item in Text(Self.digital(model.collection.digitalState(item), total: item.trackCount)).monospacedDigit() }
                .width(min: 50, ideal: 64)
            TableColumn("Bought", value: \.boughtSort) { item in
                Text(item.purchasedOn.map { $0.date().formatted(date: .abbreviated, time: .omitted) } ?? "")
            }
            .width(min: 70, ideal: 96)
            TableColumn("Paid", value: \.priceSort) { item in Text(item.price.map { formatMoney($0) } ?? "").monospacedDigit() }
                .width(min: 50, ideal: 70)
            TableColumn("Record Label", value: \.recordLabelSort) { Text($0.recordLabel ?? "") }
            TableColumn("Cat. No.", value: \.catalogNumberSort) { Text($0.catalogNumber ?? "") }
        }
        .contextMenu(forSelectionType: CollectionItem.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let item = model.item(id: id) {
                CollectionItemMenu(model: model, item: item)
            }
        } primaryAction: { ids in
            if let id = sorted.first(where: { ids.contains($0.id) })?.id { model.showItem(id: id) }
        }
        .themedScrollBackground()
    }

    /// "12/12", "8/12", "12 ↻" (from another copy), "—", "Missing".
    static func digital(_ state: DigitalState, total: Int?) -> String {
        switch state {
        case .digitized(let n): "\(n)/\(max(total ?? n, n))"
        case .partial(let have, let of): "\(have)/\(of)"
        case .otherCopy(let n, _): "\(n) ↻"
        case .none: "—"
        case .missing: "Missing"
        }
    }
}

// MARK: Removing

extension View {
    /// Asks before removing `model.pendingItemRemoval` from the collection. Shown once, by `ContentView`.
    func collectionRemovalConfirmation(_ model: AppModel) -> some View {
        let item = model.pendingItemRemoval
        let title = item.map { item in
            item.sticker.map { "Remove \($0.text)?" } ?? "Remove “\(item.album.isEmpty ? "Unknown Album" : item.album)” from your collection?"
        } ?? ""
        return confirmationDialog(title, isPresented: Binding(get: { model.pendingItemRemoval != nil },
                                                              set: { if !$0 { model.pendingItemRemoval = nil } }),
                                  titleVisibility: .visible, presenting: item) { item in
            Button("Remove from Collection", role: .destructive) { model.deleteItem(id: item.id) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            let name = "“\(item.album.isEmpty ? "Unknown Album" : item.album)”\(item.artist.isEmpty ? "" : " by \(item.artist)")"
            let songs = model.collection.digitalState(item).hasMusic ? " Its songs stay in your library." : ""
            if item.sticker != nil {
                Text("\(name) leaves your collection, and its number becomes free.\(songs)")
            } else {
                Text("\(name) leaves your collection.\(songs)")
            }
        }
    }
}

// MARK: Label Check

/// Gaps and duplicates in each label series, with each item using a duplicate number to open.
struct LabelCheckSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Label Check").font(.title2.bold())
            Text("Numbers missing from each series, and numbers on more than one item. Saving a number already used is refused, so duplicates come from older versions or other copies of the library.")
                .font(.callout).foregroundStyle(.subtext).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(StickerSeries.allCases, id: \.self) { series($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    @ViewBuilder
    private func series(_ series: StickerSeries) -> some View {
        let c = model.collection
        let labeled = c.items.filter { $0.sticker?.series == series }
        let highest = labeled.compactMap(\.stickerNumber).max()
        let gaps = c.gaps(in: series)
        let free = gaps.reduce(0) { $0 + $1.count }
        let duplicates = c.duplicates(in: series).sorted { $0.key < $1.key }
        let unlabeled = c.items.filter { $0.medium == series.medium && $0.stickerNumber == nil }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(series == .cd ? "CDs" : "Vinyl").font(.headline)
                Text(highest.map { "#1–\($0) · \(labeled.count.formatted()) labeled · next \(series.name) #\(c.nextNumber(in: series))" }
                     ?? "No labels yet")
                    .font(.callout).foregroundStyle(.subtext)
            }
            if free > 0 {
                Text("\(free.formatted()) free number\(free == 1 ? "" : "s")").font(.callout.weight(.medium))
                FlowLayout(spacing: 6) {
                    ForEach(Array(gaps.prefix(60).enumerated()), id: \.offset) { _, gap in
                        Text(gap.count == 1 ? "#\(gap.lowerBound)" : "#\(gap.lowerBound)–\(gap.upperBound)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(theme.fill))
                    }
                    if gaps.count > 60 { Text("and \(gaps.count - 60) more").font(.caption).foregroundStyle(.subtext) }
                }
            } else if highest != nil {
                Label("No free numbers", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.subtext)
            }
            if !duplicates.isEmpty {
                Text("\(duplicates.count) number\(duplicates.count == 1 ? "" : "s") used twice").font(.callout.weight(.medium))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(duplicates, id: \.key) { number, items in
                        VStack(alignment: .leading, spacing: 4) {
                            if let sticker = Sticker(series: series, number: number) { StickerPill(sticker: sticker, size: 11) }
                            ForEach(items) { item in
                                HStack {
                                    Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                                    Text(item.artist).foregroundStyle(.subtext).lineLimit(1)
                                    Spacer()
                                    Button("Open") { dismiss(); model.showItem(id: item.id) }.controlSize(.small)
                                }
                                .font(.callout)
                                .padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            if unlabeled > 0 {
                HStack {
                    Text("\(unlabeled.formatted()) \(series == .cd ? (unlabeled == 1 ? "CD" : "CDs") : (unlabeled == 1 ? "record" : "records")) without a label")
                        .font(.callout).foregroundStyle(.subtext)
                    Button("Show") {
                        dismiss()
                        model.showShelf(query: "sticker:none", scope: series == .cd ? .cds : .vinyl)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}
