import AppKit
import MusicLibraryCore
import SwiftUI

// MARK: Browse

/// Library CDs: the downloaded catalog, searched locally, or the whole network searched live on the website.
struct CatalogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.catalog.showsDownloaded { DownloadedCatalogView() } else { LiveCatalogView() }
        }
        .onAppear { model.catalog.start() }
    }
}

/// The library catalog's music CDs searched live on its website: search, the libraries that own them,
/// availability, whether they're already in your library, and the catalog's sort orders.
struct LiveCatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let catalog = model.catalog
        let shown = catalog.visibleItems
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if catalog.hasDownloads {
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text("Searching every library in the network live on the local library's website.").font(.callout)
                        Spacer()
                        Button("Back to Downloaded CDs") { catalog.liveMode = false }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                CatalogFilterBar(draft: $draft)
                if let error = catalog.error {
                    CatalogErrorBanner(message: error) { catalog.search() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], spacing: 22) {
                    ForEach(shown) { item in
                        NavigationLink(value: item) { CatalogCard(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu { CatalogItemMenu(item: item) }
                            .onAppear {
                                // Scrolling to the last title loads the next page.
                                if item.id == shown.last?.id, !catalog.hasClientFilters { catalog.loadMore() }
                            }
                    }
                }
                footer(shown: shown.count)
            }
            .padding(20)
        }
        .overlay { emptyState(shown: shown.count) }
        .navigationTitle("Local Library CDs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { catalog.search(refresh: true) } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Search the catalog again (results are kept for 30 minutes)")
            }
        }
        .onAppear {
            draft = catalog.query.text
            if !catalog.hasSearched { catalog.search() }
        }
    }

    private var subtitle: String {
        let catalog = model.catalog
        guard catalog.hasSearched, catalog.error == nil, !(catalog.isLoading && catalog.items.isEmpty) else { return "" }
        return catalog.total == 1 ? "1 CD" : "\(catalog.total.formatted()) CDs"
    }

    @ViewBuilder
    private func footer(shown: Int) -> some View {
        let catalog = model.catalog
        HStack {
            Spacer()
            if catalog.isLoading {
                ProgressView().controlSize(.small)
                Text(catalog.items.isEmpty ? "Searching the catalog…" : "Loading more…").foregroundStyle(.secondary)
            } else if catalog.hasMore {
                Button("Load More") { catalog.loadMore() }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.top, 4)
        if catalog.hasClientFilters, !catalog.items.isEmpty {
            Text("\(shown) of the \(catalog.items.count) titles loaded so far match. The catalog can't filter by this itself, so titles are checked as pages load.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func emptyState(shown: Int) -> some View {
        let catalog = model.catalog
        if catalog.hasSearched, !catalog.isLoading, catalog.error == nil, shown == 0 {
            if catalog.items.isEmpty {
                ContentUnavailableView("No CDs Found", systemImage: "opticaldisc",
                                       description: Text("Try other words, more libraries, or any availability."))
            } else if !catalog.hasMore {
                ContentUnavailableView("Nothing Matches These Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

struct CatalogFilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String

    var body: some View {
        @Bindable var catalog = model.catalog
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the catalog's music CDs", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit { catalog.query.text = draft }
                    if !draft.isEmpty {
                        Button { draft = ""; catalog.query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear the search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 460)
                Picker("Search in", selection: $catalog.query.field) {
                    ForEach(CatalogSearchField.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("What to search: keywords anywhere, titles, artists or subjects (genres)")
                Spacer()
            }
            HStack(spacing: 10) {
                libraryMenu
                availabilityPicker
                Picker("Ownership", selection: $catalog.ownershipFilter) {
                    ForEach(LibraryCatalogStore.OwnershipFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("Compare with the albums in your digital collection")
                Picker("Sort by", selection: $catalog.query.sort) {
                    ForEach(CatalogSort.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Spacer()
                LookupStatus()
            }
        }
    }

    private var libraryLabel: String {
        let libraries = model.catalog.query.libraries
        switch libraries.count {
        case 0: return "All Libraries"
        case 1: return libraries[0]
        default: return "\(libraries[0]) + \(libraries.count - 1) more"
        }
    }

    private var libraryMenu: some View {
        let catalog = model.catalog
        return Menu {
            if !catalog.homeLibrary.isEmpty {
                Button("Only \(catalog.homeLibrary) (My Local Library)") { catalog.query.libraries = [catalog.homeLibrary]; clearStaleAvailability() }
            }
            Button("All Libraries in the Network") { catalog.query.libraries = [] }
            Divider()
            ForEach(catalog.libraryChoices) { library in
                Toggle(isOn: Binding(get: { catalog.query.libraries.contains(library.name) },
                                     set: { _ in catalog.toggleLibrary(library.name) })) {
                    Text(library.count.map { "\(library.name)  (\($0.formatted()))" } ?? library.name)
                }
            }
        } label: {
            Label(libraryLabel, systemImage: "building.columns")
        }
        .fixedSize()
        .help("Libraries that own a copy (any of them)")
    }

    private func clearStaleAvailability() {
        let catalog = model.catalog
        if let at = catalog.query.availableAt, !catalog.query.libraries.contains(at) { catalog.query.availableAt = nil }
    }

    private var availabilityPicker: some View {
        let catalog = model.catalog
        let selection = Binding<String>(
            get: { catalog.onlyUnavailable ? "unavailable" : catalog.query.availableAt.map { "at:" + $0 } ?? "any" },
            set: { value in
                if value == "unavailable" {
                    catalog.onlyUnavailable = true
                    catalog.query.availableAt = nil
                } else {
                    catalog.onlyUnavailable = false
                    catalog.query.availableAt = value.hasPrefix("at:") ? String(value.dropFirst(3)) : nil
                }
            })
        let selected = catalog.query.libraries.isEmpty ? [catalog.homeLibrary].filter { !$0.isEmpty } : catalog.query.libraries
        let places = selected + [catalog.query.availableAt].compactMap { $0 }.filter { !selected.contains($0) }
        return Picker("Availability", selection: selection) {
            Text("Any Availability").tag("any")
            ForEach(places, id: \.self) { Text("Available Now at \($0)").tag("at:" + $0) }
            if let site = catalog.siteLibrary { Text("Not on the Shelf at \(site)").tag("unavailable") }
        }
        .labelsHidden().fixedSize()
        .help("Only CDs on the shelf right now at a library, or only those that aren't")
    }
}

/// "Looking up album details… 12 left", while titles are matched on MusicBrainz.
struct LookupStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        if catalog.lookupRemaining > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let until = catalog.client.cooldownUntil, until > Date() {
                    Text("Album details paused until \(until.formatted(date: .omitted, time: .shortened)) (the local library's website asked for a break) · \(catalog.lookupRemaining) left")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Looking up album details… \(catalog.lookupRemaining) left").font(.caption).foregroundStyle(.secondary)
                }
                Button { catalog.cancelLookups() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop looking up albums")
            }
            .help("Track lists, years, genres and covers come from MusicBrainz, matched by each CD's barcode")
        } else if let error = catalog.lookupError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                .help(error)
        }
    }
}

struct CatalogErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button("Try Again", action: retry)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct CatalogCard: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem
    @State private var cover: NSImage?

    var body: some View {
        let catalog = model.catalog
        let details = catalog.details[item.id]
        let owned = catalog.ownedAlbum(item) != nil
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let cover {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(AppColor.fill)
                        Image(systemName: "opticaldisc").font(.system(size: 40)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if owned {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, AppColor.accent)
                        .shadow(radius: 2).padding(6)
                        .help("In your digital collection")
                }
                if catalog.isOnList(item) {
                    Image(systemName: "bookmark.fill")
                        .font(.title3).foregroundStyle(.orange)
                        .shadow(radius: 2).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("On your list “\(catalog.listTitle)”")
                }
            }
            Text(item.displayTitle).font(.headline).lineLimit(2)
            Text(item.artist.isEmpty ? (details?.mbArtist ?? "Various Artists") : item.artist)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                CatalogStatusBadge(availability: item.availability, text: item.statusText, library: catalog.siteLibrary)
                if let year = details?.year ?? item.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
            }
            let copies = catalog.collectionCopies(item)
            if !copies.isEmpty { CollectionCopyNote(copies: copies, compact: true) }
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: "\(item.id)|\(details?.releaseId ?? details?.releaseGroupId ?? "")") {
            if let image = await catalog.cover(for: item) { cover = image }
        }
    }
}

struct CatalogStatusBadge: View {
    let availability: CatalogAvailability
    let text: String
    let library: String?

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .help(text.isEmpty ? label : text)
    }

    private var label: String {
        switch availability {
        case .here: library.map { "On Shelf at \($0)" } ?? "On Shelf"
        case .elsewhere: "Other Libraries"
        case .unavailable: "Checked Out"
        case .onOrder: "On Order"
        case .online: "Online"
        case .unknown: text.isEmpty ? "Unknown" : text
        }
    }

    private var color: Color {
        switch availability {
        case .here: .green
        case .elsewhere: .orange
        case .unavailable: .red
        case .onOrder, .online, .unknown: .blue
        }
    }
}

struct CatalogItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem

    var body: some View {
        if let album = model.catalog.ownedAlbum(item) {
            Button("Show in Digital Collection") { model.navigationPath.append(album) }
        }
        if let copy = model.catalog.collectionCopies(item).first {
            Button("Show Your Copy") { model.showItem(id: copy.id) }
        }
        Button("I Own This…") { model.addToCollection(medium: .cd, prefill: model.catalog.prefill(item)) }
        if let url = model.catalog.webURL(item.pagePath) {
            Link("Open in Local Library Catalog", destination: url)
        }
        CatalogListButton(item: item)
        Divider()
        Button("Look Up Album Details Again") { model.catalog.ensureDetails(item, force: true) }
    }
}

// MARK: Detail

/// One catalog CD: its MusicBrainz info (cover, track list, year, label, genres, rating, description), where
/// copies are and whether they're on the shelf, its editions, and whether it's already in your library.
struct CatalogDetail: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem
    @State private var cover: NSImage?
    @State private var descriptionExpanded = false
    @State private var loadingCopies = false
    @State private var hoveredPreview: Int?
    @State private var refreshPreviews = false

    var body: some View {
        let catalog = model.catalog
        let details = catalog.details[item.id]
        GeometryReader { geo in
            ZStack {
                AlbumBackdrop(image: cover)
                if geo.size.width >= 920 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                header(details, coverSize: min(380, geo.size.width * 0.42 - 56))
                                sections(details)
                            }
                            .padding(28)
                        }
                        .frame(width: min(460, geo.size.width * 0.42))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                trackList(details)
                                copiesSection
                                editionsSection(details)
                            }
                            .padding(.vertical, 28).padding(.trailing, 28).padding(.leading, 4)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header(details, coverSize: min(300, geo.size.width - 48))
                            trackList(details)
                            copiesSection
                            sections(details)
                            editionsSection(details)
                        }
                        .padding(24)
                    }
                }
            }
        }
        .navigationTitle(item.displayTitle)
        .toolbar {
            ToolbarItem {
                Button {
                    catalog.ensureDetails(item, force: true)
                    refreshPreviews = true
                } label: { Label("Look Up Again", systemImage: "arrow.clockwise") }
                    .disabled(catalog.isLookingUp(item))
                    .help("Match this CD on MusicBrainz again and refresh its track list, cover and info")
            }
        }
        .task(id: item.id) {
            catalog.ensureDetails(item)
            loadingCopies = true
            await catalog.loadCopies(item)
            loadingCopies = false
            await catalog.loadWork(item)
        }
        .task(id: "\(item.id)|\(details?.releaseId ?? details?.releaseGroupId ?? "")") {
            if let image = await catalog.cover(for: item, large: true) { cover = image }
        }
        // Previews of CDs you don't have, once the MusicBrainz lookup (barcodes, Apple Music links) is done.
        .task(id: "\(item.id)|\(catalog.isLookingUp(item))|\(details?.fetchedAt.timeIntervalSince1970 ?? 0)") {
            guard !catalog.isLookingUp(item), catalog.ownedAlbum(item) == nil else { return }
            let force = refreshPreviews
            refreshPreviews = false
            await catalog.loadPreviews(item, force: force)
        }
        .onDisappear { model.previews.stop() }
    }

    // MARK: Header

    private func header(_ details: CatalogAlbumDetails?, coverSize: CGFloat) -> some View {
        let catalog = model.catalog
        let owned = catalog.ownedAlbum(item)
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if let cover {
                    Image(nsImage: cover).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(AppColor.fill)
                        Image(systemName: "opticaldisc").font(.system(size: coverSize / 4)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.bottom, 10)

            Text(typeLine(details)).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(item.displayTitle).font(.system(size: 30, weight: .bold)).lineLimit(3).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            if let mbTitle = details?.mbTitle, CatalogText.key(mbTitle) != CatalogText.key(item.displayTitle) {
                Text("Released as “\(mbTitle)”").font(.callout).foregroundStyle(.secondary)
            }
            artistLine(details)
            if let meta = metaLine(details) { Text(meta).font(.callout).foregroundStyle(.secondary) }
            if let info = details?.album, let rating = info.rating { RatingView(rating: rating, votes: info.ratingVotes) }
            if let genres = details?.album?.genres, !genres.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(genres, id: \.self) { g in
                        Text(g.capitalized).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(AppColor.fill))
                    }
                }
            }
            HStack(spacing: 10) {
                if let owned {
                    Button { model.navigationPath.append(owned) } label: { Label("In Your Digital Collection", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Open \(owned.album) in your digital collection")
                } else {
                    // Short, so the buttons beside it keep their full titles.
                    Label("No digital copy", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.trailing, 6)
                        .help("This CD isn't in your digital collection")
                }
                CatalogListButton(item: item).buttonStyle(.bordered)
                if let url = catalog.webURL(item.pagePath) {
                    Link(destination: url) { Label("Open in Catalog", systemImage: "safari") }
                        .buttonStyle(.bordered)
                        .help("See this CD on the local library's website, where you can place a hold")
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
            HStack(spacing: 10) {
                let copies = catalog.collectionCopies(item)
                if !copies.isEmpty { CollectionCopyNote(copies: copies) }
                Button("I Own This…") { model.addToCollection(medium: .cd, prefill: catalog.prefill(item)) }
                    .help("Add this CD to your physical collection, with your label number and what you paid")
            }
            shelfStatus.padding(.top, 4)
        }
    }

    @ViewBuilder
    private func artistLine(_ details: CatalogAlbumDetails?) -> some View {
        let name = item.artist.isEmpty ? (details?.mbArtist ?? "Various Artists") : item.artist
        if let artist = model.artistSummary(named: name) ?? details?.mbArtist.flatMap(model.artistSummary(named:)) {
            Button { model.navigationPath.append(artist) } label: {
                HStack(spacing: 8) {
                    ArtistPhoto(name: artist.name, size: 26)
                    Text(name).font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(artist.name) in your digital collection")
        } else {
            Text(name).font(.title3.weight(.medium)).textSelection(.enabled)
        }
    }

    private func typeLine(_ details: CatalogAlbumDetails?) -> String {
        var parts = [(details?.album?.typeLabel ?? "Music CD").uppercased()]
        if let y = details?.year ?? item.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    private func metaLine(_ details: CatalogAlbumDetails?) -> String? {
        var parts: [String] = []
        if let label = details?.label { parts.append(label) }
        if let media = details?.media { parts.append(media) }
        let tracks = details?.tracklist ?? []
        if !tracks.isEmpty {
            let total = tracks.compactMap(\.duration).reduce(0, +)
            parts.append(total > 0 ? "\(songCount(tracks.count)), \(formatLongDuration(total))" : songCount(tracks.count))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The catalog site's own library: on the shelf (with the call number) or not.
    @ViewBuilder
    private var shelfStatus: some View {
        let catalog = model.catalog
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CatalogStatusBadge(availability: item.availability, text: item.statusText, library: catalog.siteLibrary)
            if let call = item.callNumber {
                Text(call).font(.callout.monospaced()).textSelection(.enabled)
                    .help("Call number at \(item.shelfLocation ?? "the local library")")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ details: CatalogAlbumDetails?) -> some View {
        let catalog = model.catalog
        if let info = details?.album, let text = info.description {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "About")
                Text(text).lineSpacing(3).lineLimit(descriptionExpanded ? nil : 6).textSelection(.enabled)
                HStack(spacing: 14) {
                    if text.count > 350 {
                        Button(descriptionExpanded ? "Show Less" : "Read More") { withAnimation(.snappy) { descriptionExpanded.toggle() } }
                            .buttonStyle(.link)
                    }
                    if let source = info.descriptionSource {
                        if let url = info.descriptionURL?.webLink { Link("From \(source)", destination: url).font(.caption) }
                        else { Text("From \(source)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } else if catalog.isLookingUp(item) {
            Label("Looking up this CD on MusicBrainz…", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
        } else if let details, !details.isMatched {
            Label("This CD wasn't found on MusicBrainz.", systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
        }
        releaseDetails(details)
        if let work = catalog.works[item.id], !work.contributors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Performers")
                ForEach(Array(work.contributors.prefix(16).enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline) {
                        PersonLink(name: CatalogText.displayName(c.name)) { model.showMusicDNA($0) }.fontWeight(.medium)
                        if let role = c.role { Text(role).foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }
        }
        if let links = details?.album?.links.filter({ $0.url.isWebLink }), !links.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Links")
                FlowLayout(spacing: 8) {
                    ForEach(links) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: ArtistDetail.icon(link.kind))
                                .font(.callout)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(AppColor.fill))
                        }
                        .buttonStyle(.plain)
                        .help(link.url.absoluteString)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func releaseDetails(_ details: CatalogAlbumDetails?) -> some View {
        let work = model.catalog.works[item.id]
        let rows: [(String, String)] = [
            ("Record label", details?.label), ("Catalog #", details?.catalogNumber), ("Released", details?.releaseDate),
            ("Media", details?.media), ("Barcode", details?.barcode ?? work?.upcs.first),
            ("Language", item.language), ("Series", item.series),
            ("Subjects", work.map { $0.subjects.prefix(4).joined(separator: "; ") }.flatMap { $0.isEmpty ? nil : $0 }),
            ("Matched by", details?.match.map { $0 == .barcode ? "Barcode (MusicBrainz)" : "Title and artist (MusicBrainz)" }),
        ].compactMap { k, v in v.map { (k, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Release")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(rows, id: \.0) { k, v in
                        GridRow {
                            Text(k).foregroundStyle(.secondary)
                            Text(v).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Tracks

    /// The Apple Music album for previews: only for CDs that aren't in your library.
    private var previewAlbum: AppleAlbum? {
        model.catalog.ownedAlbum(item) == nil ? model.catalog.previews[item.id]?.album : nil
    }

    @ViewBuilder
    private func trackList(_ details: CatalogAlbumDetails?) -> some View {
        let tracks = details?.tracklist ?? []
        let contents = model.catalog.works[item.id]?.contents.first
        let apple = previewAlbum
        if !tracks.isEmpty {
            let lined = apple.map { ApplePreviewMatcher.lineUp(tracks.map { .init(disc: $0.disc, number: $0.number, title: $0.title) }, with: $0) } ?? [:]
            let queue = tracks.indices.compactMap { lined[$0] }
            let discs = Array(Set(tracks.map(\.disc))).sorted()
            VStack(alignment: .leading, spacing: 10) {
                tracksHeader(queue)
                card {
                    ForEach(discs, id: \.self) { disc in
                        if discs.count > 1 { discHeader(disc, first: disc == discs.first) }
                        ForEach(tracks.indices.filter { tracks[$0].disc == disc }, id: \.self) { i in
                            let entry = tracks[i]
                            trackRow(number: entry.number, title: entry.title,
                                     artist: entry.artist == (details?.mbArtist ?? "") ? nil : entry.artist, duration: entry.duration,
                                     preview: lined[i], queue: queue)
                        }
                    }
                }
                previewsFooter(queue)
            }
        } else if let contents, !contents.tracks.isEmpty {
            let lined = apple.map { ApplePreviewMatcher.lineUp(contents.tracks.enumerated().map { .init(number: $0.offset + 1, title: $0.element) }, with: $0) } ?? [:]
            let queue = contents.tracks.indices.compactMap { lined[$0] }
            VStack(alignment: .leading, spacing: 10) {
                tracksHeader(queue)
                card {
                    ForEach(Array(contents.tracks.enumerated()), id: \.offset) { i, title in
                        trackRow(number: i + 1, title: title, artist: nil, duration: nil, preview: lined[i], queue: queue)
                    }
                }
                Text("From the local library's catalog record.").font(.caption).foregroundStyle(.secondary)
                previewsFooter(queue)
            }
        } else if let apple, !apple.tracks.isEmpty {
            // No track list from MusicBrainz or the catalog: Apple Music's own.
            let queue = apple.previews
            let discs = Array(Set(apple.tracks.map(\.disc))).sorted()
            VStack(alignment: .leading, spacing: 10) {
                tracksHeader(queue)
                card {
                    ForEach(discs, id: \.self) { disc in
                        if discs.count > 1 { discHeader(disc, first: disc == discs.first) }
                        ForEach(apple.tracks.filter { $0.disc == disc }) { t in
                            trackRow(number: t.number, title: t.title, artist: t.artist == apple.artist ? nil : t.artist,
                                     duration: t.duration, preview: t.previewURL == nil ? nil : t, queue: queue)
                        }
                    }
                }
                previewsFooter(queue)
            }
        } else if model.catalog.isLookingUp(item) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Tracks")
                HStack { ProgressView().controlSize(.small); Text("Looking up the track list…").foregroundStyle(.secondary) }
            }
        } else {
            previewsFooter([])
        }
    }

    private func discHeader(_ disc: Int, first: Bool) -> some View {
        HStack {
            Image(systemName: "opticaldisc").foregroundStyle(.secondary)
            Text("Disc \(disc)").font(.callout.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, first ? 10 : 18).padding(.bottom, 4)
    }

    /// "Tracks", with a button that plays the previews in track list order.
    private func tracksHeader(_ queue: [ApplePreviewTrack]) -> some View {
        let previews = model.previews
        let playingHere = previews.isPlaying && previews.current.map(queue.contains) == true
        return HStack(alignment: .firstTextBaseline) {
            SectionHeader(title: "Tracks")
            Spacer()
            if !queue.isEmpty {
                Button {
                    if previews.current.map(queue.contains) == true { previews.togglePlayPause() } else { previews.play(queue) }
                } label: {
                    Label(playingHere ? "Pause Preview" : "Play Previews", systemImage: playingHere ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .help("Play 30-second previews of the songs from Apple Music, one after another")
            }
        }
    }

    /// Where the previews come from (with a link to the album on Apple Music), or why there are none.
    @ViewBuilder
    private func previewsFooter(_ queue: [ApplePreviewTrack]) -> some View {
        let catalog = model.catalog
        if catalog.ownedAlbum(item) == nil {
            let found = catalog.previews[item.id]
            Group {
                if catalog.previewsLoading.contains(item.id) {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Finding previews on Apple Music…") }
                } else if let error = catalog.previewsError[item.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else if let album = found?.album {
                    HStack(spacing: 10) {
                        Label(queue.isEmpty ? "Apple Music's “\(album.title)” has different songs, so there are no previews here."
                                            : "\(queue.count) song preview\(queue.count == 1 ? "" : "s") from Apple Music",
                              systemImage: "music.note")
                        if let url = album.pageURL?.webLink {
                            Link("Listen on Apple Music", destination: url).help(url.absoluteString)
                        }
                    }
                    if let error = model.previews.lastError, model.previews.current.map(queue.contains) == true {
                        Label(error, systemImage: "exclamationmark.triangle")
                    }
                } else if found != nil {
                    Label("No previews: this CD wasn't found on Apple Music.", systemImage: "music.note")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColor.card.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppColor.separator.opacity(0.5), lineWidth: 0.5))
    }

    private func trackRow(number: Int, title: String, artist: String?, duration: Double?,
                          preview: ApplePreviewTrack? = nil, queue: [ApplePreviewTrack] = []) -> some View {
        let previews = model.previews
        let isCurrent = preview.map(previews.isCurrent) ?? false
        let playing = isCurrent && previews.isPlaying
        return HStack(spacing: 12) {
            ZStack {
                if let preview, isCurrent || hoveredPreview == preview.id {
                    Button { previews.toggle(preview, in: queue) } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill").foregroundStyle(AppColor.accent)
                            .frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Pause the preview" : "Play a 30-second preview from Apple Music")
                } else {
                    Text(String(number)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).foregroundStyle(isCurrent ? AppColor.accent : .primary)
                if let artist, !artist.isEmpty {
                    PersonLinks(artist) { model.showMusicDNA($0) }.font(.caption)
                }
            }
            Spacer()
            Text(duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(alignment: .bottomLeading) {
            if isCurrent {
                GeometryReader { g in
                    Capsule().fill(AppColor.accent.opacity(0.7))
                        .frame(width: max(0, g.size.width - 28) * previews.progress, height: 2)
                        .offset(x: 14, y: g.size.height - 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard let preview else { return }
            if inside { hoveredPreview = preview.id } else if hoveredPreview == preview.id { hoveredPreview = nil }
        }
    }

    // MARK: Copies

    @ViewBuilder
    private var copiesSection: some View {
        let catalog = model.catalog
        let copies = sortedCopies(catalog.copies[item.id] ?? [])
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Where to Find It")
                Spacer()
                if !copies.isEmpty {
                    let libraries = Set(copies.filter(\.isAvailable).map(\.library)).count
                    Text("On the shelf at \(libraries) librar\(libraries == 1 ? "y" : "ies")").font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    Task { loadingCopies = true; await catalog.loadCopies(item, force: true); loadingCopies = false }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(loadingCopies).help("Check availability again")
            }
            if copies.isEmpty {
                if loadingCopies {
                    HStack { ProgressView().controlSize(.small); Text("Checking the libraries…").foregroundStyle(.secondary) }
                } else {
                    Text(catalog.copiesError[item.id] ?? "No copy details from the catalog.").foregroundStyle(.secondary)
                }
            } else {
                card {
                    ForEach(copies) { copy in copyRow(copy) }
                }
            }
        }
    }

    /// Selected libraries first (home library on top), then where it's on the shelf, then by name.
    private func sortedCopies(_ copies: [CatalogCopy]) -> [CatalogCopy] {
        let catalog = model.catalog
        func rank(_ c: CatalogCopy) -> Int {
            if c.library == catalog.homeLibrary { return 0 }
            if catalog.query.libraries.contains(c.library) { return 1 }
            return 2
        }
        return copies.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.isAvailable != b.isAvailable { return a.isAvailable }
            return a.library.localizedStandardCompare(b.library) == .orderedAscending
        }
    }

    private func copyRow(_ copy: CatalogCopy) -> some View {
        let home = copy.library == model.catalog.homeLibrary
        return HStack(spacing: 10) {
            Circle().fill(copy.isAvailable ? Color.green : Color.red.opacity(0.7)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(copy.library).fontWeight(home ? .semibold : .regular)
                    if home { Text("My Local Library").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(AppColor.fill)) }
                }
                Text(copy.location.components(separatedBy: " - ").dropFirst().joined(separator: " - "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(copy.callNumber).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            Text(copy.isAvailable ? "\(copy.available) of \(copy.total) in" : (copy.total == 1 ? "Out" : "0 of \(copy.total) in"))
                .font(.caption).monospacedDigit()
                .foregroundStyle(copy.isAvailable ? Color.green : Color.red)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Editions

    @ViewBuilder
    private func editionsSection(_ details: CatalogAlbumDetails?) -> some View {
        let editions = details?.editions ?? []
        if editions.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Editions")
                card {
                    ForEach(editions) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text([e.published, e.edition].compactMap { $0 }.joined(separator: " · ")).lineLimit(2)
                                Text([e.physical, e.upc.map { "UPC \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            CatalogStatusBadge(availability: e.availability, text: e.statusText, library: model.catalog.siteLibrary)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                    }
                }
            }
        }
    }
}

// MARK: Checkouts

/// The CDs (or everything) you have checked out, and whether each is in your music library yet.
struct CatalogCheckoutsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("checkoutsAllFormats") private var allFormats = false

    var body: some View {
        let catalog = model.catalog
        let list = allFormats ? catalog.checkouts : catalog.cdCheckouts
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Toggle("Show all formats", isOn: $allFormats).toggleStyle(.checkbox)
                    Spacer()
                    if catalog.checkoutsLoading { ProgressView().controlSize(.small) }
                }
                if let error = catalog.checkoutsError { CatalogErrorBanner(message: error) { catalog.refreshCheckouts() } }
                if !list.isEmpty {
                    let missing = list.filter { catalog.ownedAlbum($0) == nil && isMusic($0) }.count
                    if missing > 0 {
                        Label("\(missing) of these CDs \(missing == 1 ? "isn't" : "aren't") in your digital collection yet. Insert one to rip it from the Import section.",
                              systemImage: "opticaldisc")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        ForEach(list) { row($0) }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(AppColor.card.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppColor.separator.opacity(0.5), lineWidth: 0.5))
                }
            }
            .padding(20)
        }
        .overlay { emptyState(list) }
        .navigationTitle("My Checkouts")
        .navigationSubtitle(catalog.checkoutsLoaded ? (list.count == 1 ? "1 item" : "\(list.count) items") : "")
        .toolbar {
            ToolbarItem {
                Button { catalog.refreshCheckouts() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(!catalog.isSignedIn || catalog.checkoutsLoading)
            }
        }
        .onAppear {
            if catalog.isSignedIn { if !catalog.checkoutsLoaded { catalog.refreshCheckouts() } }
            else { catalog.start() }
        }
    }

    private func isMusic(_ c: CatalogCheckout) -> Bool { c.format?.localizedCaseInsensitiveContains("Music") == true }

    @ViewBuilder
    private func emptyState(_ list: [CatalogCheckout]) -> some View {
        let catalog = model.catalog
        switch catalog.account {
        case .signedOut, .failed:
            ContentUnavailableView {
                Label("Not Signed In", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text(catalogFailure ?? "Sign in to your local library account in Settings to see what you have checked out.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        case .signingIn:
            ProgressView("Signing in…")
        case .signedIn:
            if catalog.checkoutsLoaded, list.isEmpty {
                ContentUnavailableView(allFormats ? "Nothing Checked Out" : "No CDs Checked Out", systemImage: "books.vertical")
            }
        }
    }

    private var catalogFailure: String? {
        if case .failed(let message) = model.catalog.account { return message }
        return nil
    }

    private func row(_ checkout: CatalogCheckout) -> some View {
        let owned = model.catalog.ownedAlbum(checkout)
        let due = checkout.dueDate
        let soon = due.map { $0.timeIntervalSinceNow < 3 * 86_400 } ?? false
        return HStack(spacing: 12) {
            CheckoutCover(path: checkout.coverPath)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkout.displayTitle).fontWeight(.medium).lineLimit(1)
                Text([checkout.artist, checkout.format ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let owned {
                Button { model.navigationPath.append(owned) } label: {
                    Label("In Your Digital Collection", systemImage: "checkmark.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open \(owned.album) in your digital collection")
            } else if isMusic(checkout) {
                Text("Not in your digital collection").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(checkout.due.map { "Due \($0)" } ?? "").font(.caption.weight(soon ? .semibold : .regular))
                    .foregroundStyle(soon ? Color.red : Color.primary)
                if let renewed = checkout.renewed { Text("Renewed \(renewed)").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

struct CheckoutCover: View {
    @Environment(AppModel.self) private var model
    let path: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(AppColor.fill)
                Image(systemName: "opticaldisc").foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: path) {
            guard let path else { return }
            image = await model.catalog.coverImage(path: path)
        }
    }
}

// MARK: List

/// "Add to <list>" / "Remove from <list>", for the list chosen in Settings.
struct CatalogListButton: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem

    var body: some View {
        let catalog = model.catalog
        if catalog.isSignedIn, !catalog.listId.isEmpty {
            let busy = catalog.listBusy.contains(item.id)
            if let entry = catalog.listEntry(for: item) {
                Button { catalog.removeFromList(item) } label: { Label("Remove from \(catalog.listTitle)", systemImage: "bookmark.slash") }
                    .disabled(busy || entry.entryId.isEmpty)
                    .help("Remove this CD from your list on the local library's website")
            } else {
                Button { catalog.addToList(item) } label: { Label("Add to \(catalog.listTitle)", systemImage: "bookmark") }
                    .disabled(busy)
                    .help("Add this CD to your list on the local library's website, so you know what to look for")
            }
        }
    }
}

/// The list chosen in Settings: what's on it, where it's on the shelf, and removing titles.
struct CatalogListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        let entries = catalog.listEntries
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let url = catalog.webURL(catalog.listId.isEmpty ? "/MyAccount/Lists" : CatalogPaths.list(catalog.listId)) {
                        Link("Open on the Local Library's Website", destination: url).font(.callout)
                    }
                    Spacer()
                    if catalog.listLoading { ProgressView().controlSize(.small) }
                    LookupStatus()
                }
                if let error = catalog.listError { CatalogErrorBanner(message: error) { catalog.loadList() } }
                if !entries.isEmpty {
                    let here = entries.filter { $0.item.availability == .here }.count
                    let site = catalog.siteLibrary ?? "your local library"
                    Text("\(here) of \(entries.count) on the shelf at \(site) right now.").font(.callout).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(entries) { row($0) }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(AppColor.card.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppColor.separator.opacity(0.5), lineWidth: 0.5))
                }
            }
            .padding(20)
        }
        .overlay { emptyState(entries) }
        .navigationTitle(catalog.listTitle)
        .navigationSubtitle(catalog.listLoaded ? (entries.count == 1 ? "1 title" : "\(entries.count) titles") : "")
        .toolbar {
            ToolbarItem {
                Button { catalog.loadList() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .disabled(!catalog.isSignedIn || catalog.listId.isEmpty || catalog.listLoading)
            }
        }
        .onAppear {
            if catalog.isSignedIn {
                if catalog.userLists.isEmpty { catalog.loadUserLists() } else if !catalog.listLoaded { catalog.loadList() }
            } else {
                catalog.start()
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ entries: [CatalogListEntry]) -> some View {
        let catalog = model.catalog
        if !catalog.isSignedIn {
            if catalog.account == .signingIn {
                ProgressView("Signing in…")
            } else {
                ContentUnavailableView {
                    Label("Not Signed In", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Sign in to your local library account in Settings, then pick the list to use.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            }
        } else if catalog.listId.isEmpty {
            ContentUnavailableView {
                Label("No List Chosen", systemImage: "bookmark")
            } description: {
                Text("Pick one of your local library lists in Settings ▸ Local Library. CDs you add while browsing go there.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if catalog.listLoaded, entries.isEmpty {
            ContentUnavailableView("Nothing on This List Yet", systemImage: "bookmark",
                                   description: Text("Add CDs from Local Library CDs with the bookmark button or by right-clicking them."))
        }
    }

    private func row(_ entry: CatalogListEntry) -> some View {
        let catalog = model.catalog
        let item = entry.item
        let owned = catalog.ownedAlbum(item)
        return HStack(spacing: 12) {
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    ListCover(item: item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle).fontWeight(.medium).lineLimit(1)
                        Text(item.artist.isEmpty ? (catalog.details[item.id]?.mbArtist ?? "Various Artists") : item.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let call = item.callNumber, item.availability == .here {
                        Text(call).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    CatalogStatusBadge(availability: item.availability, text: item.statusText, library: catalog.siteLibrary)
                    if owned != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.accent).help("In your digital collection")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { catalog.removeFromList(item) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(catalog.listBusy.contains(item.id) || entry.entryId.isEmpty)
                .help("Remove from \(catalog.listTitle)")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contextMenu { CatalogItemMenu(item: item) }
    }
}

private struct ListCover: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem
    @State private var image: NSImage?

    var body: some View {
        let d = model.catalog.details[item.id]
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(AppColor.fill)
                Image(systemName: "opticaldisc").foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(item.id)|\(d?.releaseId ?? d?.releaseGroupId ?? "")") {
            if let found = await model.catalog.cover(for: item) { image = found }
        }
    }
}

/// What you own of a CD listed elsewhere (a library's catalog, a shop): "In your physical collection: CD #142 (not ripped)",
/// "You have it on Vinyl #12", "You have it as a download". Clicking it opens the copy.
struct CollectionCopyNote: View {
    @Environment(AppModel.self) private var model
    /// The matching copies, the closest first.
    let copies: [CollectionItem]
    /// One short line for a card: "CD #142 · not ripped".
    var compact = false
    /// For a shop's edition: whether these are copies of that exact edition ("You own this edition (CD #142)").
    var edition: Bool?

    var body: some View {
        if let copy = preferred {
            Button { model.showItem(id: copy.id) } label: {
                Label(compact ? short(copy) : text(copy), systemImage: "books.vertical.fill")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(text(copy))
        }
    }

    /// A CD first (the lowest label), then a record, then a download.
    private var preferred: CollectionItem? {
        copies.min { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : (a.stickerNumber ?? .max) < (b.stickerNumber ?? .max)
        }
    }

    private func rank(_ item: CollectionItem) -> Int {
        switch item.medium {
        case .cd: 0
        case .vinyl: 1
        case .other: 2
        case .download: 3
        }
    }

    private func ripped(_ item: CollectionItem) -> String {
        model.collection.digitalState(item).hasMusic ? (item.medium == .cd ? "ripped" : "digitized")
            : (item.medium == .cd ? "not ripped" : "not digitized")
    }

    private func text(_ item: CollectionItem) -> String {
        if let edition {
            let name = item.sticker?.text ?? "your CD"
            return edition ? "You own this edition (\(name))" : "You own another edition (\(name))"
        }
        switch item.medium {
        case .cd: return "In your physical collection: \(item.sticker?.text ?? "your CD") (\(ripped(item)))"
        case .vinyl: return "You have it on \(item.sticker?.text ?? "vinyl")"
        case .download: return "You have it as a download"
        case .other: return "You have it on \(item.formatDetail ?? "another medium")"
        }
    }

    private func short(_ item: CollectionItem) -> String {
        switch item.medium {
        case .cd: return "\(item.sticker?.text ?? "Your CD") · \(ripped(item))"
        case .vinyl: return item.sticker?.text ?? "On vinyl"
        case .download: return "Your download"
        case .other: return item.formatDetail ?? "Yours"
        }
    }
}
