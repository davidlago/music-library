import MusicLibraryCore
import SwiftUI

// MARK: Routes

/// Pages of the collection (items themselves are `CollectionItemRoute`).
enum CollectionRoute: Hashable {
    case scope(CollectionScope)
    /// Items with a digital copy whose songs aren't all on this iPhone.
    case readyToDownload
    /// Free and duplicate label numbers in a series.
    case labelCheck(StickerSeries)
    /// The items matching a query in the collection's search language (from Insights).
    case query(String, title: String)
}

struct CollectionRoutePage: View {
    let route: CollectionRoute

    var body: some View {
        switch route {
        case .scope(let scope): CollectionListPage(scope: scope)
        case .readyToDownload: ReadyToDownloadPage()
        case .labelCheck(let series): LabelCheckPage(series: series)
        case .query(let query, let title): CollectionListPage(scope: .all, query: query, title: title)
        }
    }
}

// MARK: Tab

/// The Collection tab: the CDs and records you own, then the digital collection, with or without songs in the library (downloads are on the Digital
/// tab). Read-only; the collection is edited in Music Library on the Mac.
struct CollectionTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        LibraryStack(opener: PendingLinksOpener()) {
            Group {
                if let library = model.library, !library.isEmpty {
                    // With nothing on the shelf, the digital collection alone (downloads are digital).
                    if model.collection.count(.all) == 0 {
                        LibraryHome(library: library)
                    } else {
                        CollectionHome(library: library)
                    }
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Collection")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

/// The albums (`PhoneModel.pendingAlbumKey`) and items (`pendingItemID`) widgets, the watch and Siri open, both shown
/// on the Collection tab.
private struct PendingLinksOpener: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(PendingItemOpener()).modifier(PendingAlbumOpener())
    }
}

/// Shows the item a widget or Siri opened (`PhoneModel.pendingItemID`) once the library is loaded, over whatever page
/// the tab had pushed.
private struct PendingItemOpener: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Environment(\.showRoute) private var showRoute

    private struct Pending: Equatable {
        var id: String?
        var libraryVersion: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Pending(id: model.pendingItemID, libraryVersion: model.libraryVersion)) {
            guard let id = model.pendingItemID else { return }
            if case .loading = model.state { return }
            model.pendingItemID = nil
            if model.item(id: id) != nil { showRoute(CollectionItemRoute(id: id)) }
        }
    }
}

// MARK: Home

struct CollectionHome: View {
    @Environment(PhoneModel.self) private var model
    let library: LibrarySnapshot

    var body: some View {
        let collection = model.collection
        let ready = model.readyToDownload
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isSample { sampleNote }
                FindByLabelCard()
                tiles(collection, ready: ready)
                rows(collection, ready: ready)
                DigitalCollectionCard(library: library)
                recentlyAdded(collection)
                footnotes(collection)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { model.reload() }
        .radioDJPage(.page("the Physical Collection home", details: [
            "\(collection.count(.cds)) CDs, \(collection.count(.vinyl)) records, \(collection.count(.downloads)) downloads; \(collection.count(.toDigitize)) to digitize; \(ready.count) ready to download to this iPhone"]))
    }

    private var sampleNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample Library").font(.headline)
                Text("A made-up physical collection of CDs and records, so you can try the app. Your own replaces it after your first sync.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Hide Sample Library") { model.hideSample() }.font(.subheadline.weight(.medium)).padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tiles(_ c: MusicCollection, ready: [CollectionItem]) -> some View {
        let toDigitize = c.items(in: .toDigitize)
        let toRip = toDigitize.count { $0.medium == .cd }
        return StatGrid {
            tile(.scope(.cds), value: c.count(.cds), label: "CDs", icon: "opticaldisc",
                 detail: c.count(.cds) > 0 ? "Next label: CD #\(c.nextNumber(in: .cd))" : nil)
            tile(.scope(.vinyl), value: c.count(.vinyl), label: "Vinyl", icon: "record.circle",
                 detail: c.count(.vinyl) > 0 ? "Next label: Vinyl #\(c.nextNumber(in: .vinyl))" : nil)
            tile(.scope(.toDigitize), value: toDigitize.count, label: "To Digitize", icon: "waveform.slash",
                 detail: toDigitize.isEmpty ? "Everything's digitized" : (toRip > 0 ? "\(toRip) CD\(toRip == 1 ? "" : "s") to rip" : nil))
            tile(.readyToDownload, value: ready.count, label: "Ready to Download", icon: "icloud.and.arrow.down",
                 detail: ready.isEmpty ? nil : "Not on this iPhone yet")
        }
    }

    private func tile(_ route: CollectionRoute, value: Int, label: String, icon: String, detail: String?) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: icon).font(.callout).foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                    InsightChevron()
                }
                Text(value.formatted()).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func rows(_ c: MusicCollection, ready: [CollectionItem]) -> some View {
        VStack(spacing: 0) {
            scopeRow(.all, "Shelf", systemImage: "books.vertical", count: c.count(.all), detail: "Every CD and record you own")
            divider
            scopeRow(.cds, "CDs", systemImage: "opticaldisc", count: c.count(.cds), detail: "Ripped or not")
            divider
            scopeRow(.vinyl, "Vinyl", systemImage: "record.circle", count: c.count(.vinyl), detail: "Records, digitized or not")
            divider
            scopeRow(.toDigitize, "To Digitize", systemImage: "waveform.slash", count: c.count(.toDigitize),
                     detail: "No digital copy yet")
            divider
            NavigationLink(value: CollectionRoute.readyToDownload) {
                row("Ready to Download", systemImage: "icloud.and.arrow.down", count: ready.count,
                    detail: "Digitized, not on this iPhone yet")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .card()
    }

    private var divider: some View { Divider().padding(.leading, 50) }

    private func scopeRow(_ scope: CollectionScope, _ title: String, systemImage: String, count: Int, detail: String) -> some View {
        NavigationLink(value: CollectionRoute.scope(scope)) {
            row(title, systemImage: systemImage, count: count, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, systemImage: String, count: Int, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CountPill(count: count)
            InsightChevron()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func recentlyAdded(_ c: MusicCollection) -> some View {
        let recent = Array(CollectionSort.added.sorted(c.items(in: .all)).prefix(12))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recently Added")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(recent) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionCell(item: item, width: 140) }
                                .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
            }
        }
    }

    @ViewBuilder
    private func footnotes(_ c: MusicCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(StickerSeries.allCases, id: \.self) { series in
                if let text = LabelCheckSummary.text(c, series: series) {
                    NavigationLink(value: CollectionRoute.labelCheck(series)) {
                        HStack(spacing: 4) {
                            Text(text)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if c.unreadable > 0 {
                Label("\(c.unreadable) item\(c.unreadable == 1 ? " needs" : "s need") a newer version of Music Library.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Edit your physical collection in Music Library on your Mac.").foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}

/// "CD: 3 free numbers · 1 duplicate", for a series with labels.
enum LabelCheckSummary {
    static func text(_ c: MusicCollection, series: StickerSeries) -> String? {
        let numbered = c.items.contains { $0.sticker?.series == series }
        guard numbered else { return nil }
        let free = c.gaps(in: series).reduce(0) { $0 + $1.count }
        let duplicates = c.duplicates(in: series).count
        var parts: [String] = []
        if free > 0 { parts.append("\(free.formatted()) free number\(free == 1 ? "" : "s")") }
        if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("no gaps, next #\(c.nextNumber(in: series))") }
        return "\(series.name): " + parts.joined(separator: " · ")
    }
}

// MARK: Cells and status

/// An item in a grid: its case or sleeve, title and artist. The sticker and badges on the cover say the rest (press
/// and hold one for what it means). Never dimmed: you own it whether or not its songs are here.
struct CollectionCell: View {
    @Environment(PhoneModel.self) private var model
    let item: CollectionItem
    var width: CGFloat = 160
    var highlighted = false

    var body: some View {
        let state = model.collection.digitalState(item)
        VStack(alignment: .leading, spacing: 4) {
            CopyArt(mark: model.copyMark(for: item), url: model.library?.coverURL(item: item), width: width, title: item.album)
                .padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
                // Only whether the songs are on this iPhone: the cover's badge already says "Not ripped".
                if state.hasMusic { CollectionStatusMark(item: item, state: state) }
            }
            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(highlighted ? 0.18 : 0)))
        .padding(-6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An item in a list: a small cover, title, artist, label and status.
struct CollectionRow: View {
    @Environment(PhoneModel.self) private var model
    let item: CollectionItem

    var body: some View {
        let state = model.collection.digitalState(item)
        HStack(spacing: 12) {
            CoverImage(url: model.library?.coverURL(item: item), size: 48, title: item.album)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let sticker = item.sticker { StickerPill(sticker: sticker, size: 10) }
                    else { Text(item.origin == .songs ? "Songs" : item.medium.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    DigitalStatusLabel(item: item, state: state, collection: model.collection, compact: true)
                        .font(.caption2).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            CollectionStatusMark(item: item, state: state)
        }
        .contentShape(Rectangle())
    }
}

/// Where the availability mark goes for an item: with no digital copy, a disc or record (nothing to download); else
/// whether its songs are on this iPhone.
struct CollectionStatusMark: View {
    @Environment(PhoneModel.self) private var model
    let item: CollectionItem
    let state: DigitalState

    var body: some View {
        if state.hasMusic {
            let tracks = model.collection.libraryTracks(item)
            AvailabilityMark(availability: model.availability(tracks), pending: model.isDownloadPending(tracks))
        } else if state == .missing {
            Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Digital copy no longer in your digital collection")
        } else if item.medium.isPhysical {
            Image(systemName: item.medium == .vinyl ? "record.circle" : item.medium == .cd ? "opticaldisc" : "shippingbox")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("No digital copy")
        }
    }
}

/// Where an item's digital copy stands, with its icon: nothing for a full digital copy (unless asked), "Not ripped",
/// "8 of 12", "From your CD #142", "Missing".
struct DigitalStatusLabel: View {
    let item: CollectionItem
    let state: DigitalState
    let collection: MusicCollection
    /// Leaves out a full digital copy (the usual case) to keep cells short.
    var compact = false

    var body: some View {
        if let status = describe() {
            Label {
                Text(status.text)
            } icon: {
                Image(systemName: status.icon)
            }
            .labelStyle(StatusLabelStyle())
            .foregroundStyle(.secondary)
        }
    }

    private func describe() -> (text: String, icon: String)? {
        switch state {
        case .digitized:
            if compact { return nil }
            return (item.medium == .download ? "In your digital collection" : item.medium == .cd ? "Ripped" : "Digitized", "checkmark.circle")
        case .partial(let have, let total):
            return ("\(have) of \(total)", "circle.lefthalf.filled")
        case .otherCopy(_, let from):
            if let from = from.flatMap(collection.item(id:)) {
                return ("From your " + (from.sticker?.text ?? from.medium.name.lowercased()), "arrow.triangle.2.circlepath")
            }
            return (compact ? "From elsewhere" : "Same album, from elsewhere", "arrow.triangle.2.circlepath")
        case .none:
            guard item.medium.isPhysical else { return ("No files", "questionmark.circle") }
            return (item.medium == .cd ? "Not ripped" : "Not digitized", "waveform.slash")
        case .missing:
            return ("Missing", "exclamationmark.circle")
        }
    }

    private struct StatusLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                configuration.icon
                configuration.title
            }
        }
    }
}

// MARK: List page

enum CollectionLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: Self { self }
}

/// A scope of the collection (or the items matching a query), as a grid of cases and sleeves or a list, in the order
/// picked; sorted by label, it's in sections of a hundred numbers ("CD 100–199"). The search field filters in the
/// collection's search language; a label ("12", "#12", "v12") jumps to it instead.
struct CollectionListPage: View {
    @Environment(PhoneModel.self) private var model
    let scope: CollectionScope
    var query: String?
    var title: String?
    @AppStorage("collectionLayout") private var layout = CollectionLayout.grid
    @AppStorage private var sort: CollectionSort
    @State private var text = ""
    @State private var filtered: [CollectionItem]?
    @State private var highlighted: String?

    init(scope: CollectionScope, query: String? = nil, title: String? = nil) {
        self.scope = scope
        self.query = query
        self.title = title
        let byLabel: Set<CollectionScope> = [.cds, .vinyl, .toDigitize]
        _sort = AppStorage(wrappedValue: query == nil && byLabel.contains(scope) ? .sticker : .added,
                           "collectionSort.\(query == nil ? scope.rawValue : "query")")
    }

    var body: some View {
        let items = sort.sorted(filtered ?? base)
        let sections = Self.sections(items, by: sort)
        ScrollViewReader { proxy in
            Group {
                switch layout {
                case .grid: grid(sections)
                case .list: list(sections)
                }
            }
            .onChange(of: jumpTarget(in: items)) { _, target in
                guard let target else { highlighted = nil; return }
                highlighted = target
                withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .overlay {
            if items.isEmpty {
                if text.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "books.vertical")
                } else {
                    ContentUnavailableView.search(text: text)
                }
            }
        }
        .navigationTitle(title ?? scope.title)
        .radioDJPage(.page("the \(title ?? scope.title) list of their \(scope == .downloads ? "digital" : "physical") collection",
                           details: ["\(model.collection.count(scope)) items" + (query.map { ", matching \($0)" } ?? "")]))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter, or a label like 12")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            if let target = jumpTarget(in: items) { highlighted = target }
        }
        .task(id: FilterKey(text: text, version: model.collectionVersion)) { await filter() }
        .toolbar {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(CollectionSort.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    Picker("View As", selection: $layout) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(CollectionLayout.grid)
                        Label("List", systemImage: "list.bullet").tag(CollectionLayout.list)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort and View")
        }
    }

    private var emptyTitle: String {
        if query != nil { return "Nothing Matches" }
        switch scope {
        case .toDigitize: return "Everything's Digitized"
        case .all: return "Your Shelf Is Empty"
        default: return "No \(scope.title)"
        }
    }

    /// The items before the search field filters them.
    private var base: [CollectionItem] {
        if let query { return model.collectionIndex.search(query) }
        return model.collection.items(in: scope)
    }

    private struct FilterKey: Equatable {
        var text: String
        var version: Int
    }

    private func filter() async {
        let typed = text.trimmingCharacters(in: .whitespaces)
        // A label jumps to it; it doesn't filter.
        guard !typed.isEmpty, CollectionSearchQuery.labelForm(typed) == nil else { filtered = nil; return }
        let full = [query ?? scope.query, typed].filter { !$0.isEmpty }.joined(separator: " ")
        let index = model.collectionIndex
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) { index.search(full) }.value
        guard !Task.isCancelled else { return }
        filtered = found
    }

    /// The item a label typed in the search field points at: in the scope's series, else CDs first.
    private func jumpTarget(in items: [CollectionItem]) -> String? {
        guard let label = CollectionSearchQuery.labelForm(text) else { return nil }
        let series = label.series.map { [$0] } ?? (scope == .vinyl ? [.vinyl, .cd] : [.cd, .vinyl])
        for s in series {
            if let hit = items.first(where: { $0.sticker == Sticker(series: s, number: label.number) }) { return hit.id }
        }
        return nil
    }

    // MARK: Sections

    struct ShelfSection: Identifiable {
        var id: String
        var title: String?
        var detail: String?
        var items: [CollectionItem]
    }

    /// One section, or by label: a hundred numbers of a series each ("CD 100–199 · 97 labeled · 3 free"), then the
    /// unlabeled items.
    static func sections(_ items: [CollectionItem], by sort: CollectionSort) -> [ShelfSection] {
        guard sort == .sticker else { return [ShelfSection(id: "all", items: items)] }
        var out: [ShelfSection] = []
        var unlabeled: [CollectionItem] = []
        for item in items {
            guard let s = item.sticker else { unlabeled.append(item); continue }
            let low = s.number / 100 * 100
            let id = "\(s.series.rawValue)-\(low)"
            if out.last?.id == id { out[out.count - 1].items.append(item) }
            else { out.append(ShelfSection(id: id, title: "\(s.series.name) \(max(low, 1))–\(low + 99)", items: [item])) }
        }
        for i in out.indices {
            let numbers = Set(out[i].items.compactMap(\.stickerNumber))
            let low = max(out[i].items.first?.stickerNumber.map { $0 / 100 * 100 } ?? 1, 1)
            let free = numbers.max().map { high in (low...high).count { !numbers.contains($0) } } ?? 0
            out[i].detail = "\(numbers.count) labeled" + (free > 0 ? " · \(free) free" : "")
        }
        if !unlabeled.isEmpty { out.append(ShelfSection(id: "unlabeled", title: out.isEmpty ? nil : "No Label", items: unlabeled)) }
        return out
    }

    private func header(_ section: ShelfSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title ?? "").font(.headline)
            if let detail = section.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(.bar)
    }

    private func grid(_ sections: [ShelfSection]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) {
                                CollectionCell(item: item, highlighted: highlighted == item.id)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    } header: {
                        if section.title != nil { header(section).padding(.horizontal, -16) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func list(_ sections: [ShelfSection]) -> some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        NavigationLink(value: CollectionItemRoute(id: item.id)) {
                            CollectionRow(item: item)
                        }
                        .listRowBackground(highlighted == item.id ? Color.accentColor.opacity(0.18) : nil)
                        .id(item.id)
                    }
                } header: {
                    if let title = section.title {
                        HStack(alignment: .firstTextBaseline) {
                            Text(title)
                            if let detail = section.detail { Text(detail).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: Ready to Download

/// CDs and records with a digital copy whose songs aren't all on this iPhone, and Download All, which asks the Mac for each
/// album (`SyncRequest`s, kept until a sync, so it works before pairing too).
struct ReadyToDownloadPage: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let items = model.readyToDownload
        let waiting = items.filter { !model.isDownloadPending(model.collection.libraryTracks($0)) }
        let songs = items.reduce(0) { $0 + model.collection.libraryTracks($1).count { !model.isPresent($0) } }
        List {
            if !items.isEmpty {
                Section {
                    Button {
                        model.download(waiting.compactMap(model.exportItem(for:)))
                    } label: {
                        Label(waiting.count == items.count ? "Download All" : "Download the Rest (\(waiting.count))",
                              systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(waiting.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(model.sync.isPaired
                         ? "\(items.count) album\(items.count == 1 ? "" : "s") · \(songCount(songs)) not on this iPhone. They download at the next sync with \(model.sync.macName ?? "your Mac")."
                         : "\(items.count) album\(items.count == 1 ? "" : "s") · \(songCount(songs)) not on this iPhone. They download at the first sync after you pair with your Mac (Sync, on Listen Now).")
                }
            }
            Section {
                ForEach(items) { item in
                    NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionRow(item: item) }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("All Here", systemImage: "checkmark.circle",
                                       description: Text("Every CD and record you've digitized is on this iPhone."))
            }
        }
        .navigationTitle("Ready to Download")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Label Check

/// The numbers free between the labels used in a series, the numbers on more than one item, and the CDs or records
/// without a label.
struct LabelCheckPage: View {
    @Environment(PhoneModel.self) private var model
    @State private var series: StickerSeries

    init(series: StickerSeries) { _series = State(initialValue: series) }

    var body: some View {
        let c = model.collection
        let numbered = c.items.compactMap { $0.sticker?.series == series ? $0.stickerNumber : nil }
        let gaps = c.gaps(in: series)
        let duplicates = c.duplicates(in: series).sorted { $0.key < $1.key }
        let unlabeled = c.items.filter { $0.medium == series.medium && $0.stickerNumber == nil }
        List {
            Section {
                Picker("Series", selection: $series) {
                    ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if let high = numbered.max() {
                    LabeledContent("Labels used", value: "#1–#\(high)")
                    LabeledContent("Labeled", value: Set(numbered).count.formatted())
                } else {
                    Text("No \(series == .cd ? "CDs" : "records") have a label yet.").foregroundStyle(.secondary)
                }
                LabeledContent("Next label", value: "\(series.name) #\(c.nextNumber(in: series))")
            }
            Section {
                if gaps.isEmpty {
                    Text("None: every number up to the highest is used.").foregroundStyle(.secondary)
                }
                ForEach(gaps, id: \.lowerBound) { gap in
                    LabeledContent(gap.count == 1 ? "#\(gap.lowerBound)" : "#\(gap.lowerBound)–#\(gap.upperBound)",
                                   value: gap.count == 1 ? "" : "\(gap.count) numbers")
                        .monospacedDigit()
                }
            } header: {
                Text("Free Numbers")
            }
            if !duplicates.isEmpty {
                ForEach(duplicates, id: \.key) { number, items in
                    Section {
                        ForEach(items) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionRow(item: item) }
                        }
                    } header: {
                        Text("\(series.name) #\(number) is on \(items.count) items")
                    }
                }
            }
            if !unlabeled.isEmpty {
                Section("Without a Label") {
                    ForEach(unlabeled) { item in
                        NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionRow(item: item) }
                    }
                }
            }
            Section {
            } footer: {
                Text("Labels are put on and changed in Music Library on your Mac.")
            }
        }
        .navigationTitle("Label Check")
        .navigationBarTitleDisplayMode(.inline)
    }
}
