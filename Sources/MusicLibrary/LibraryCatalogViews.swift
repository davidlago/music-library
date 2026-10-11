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
                        Image(systemName: "globe").foregroundStyle(.subtext)
                        Text("Searching every library in the network live on the library's website.").font(.callout)
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
        .navigationTitle("Library CDs")
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
                Text(catalog.items.isEmpty ? "Searching the catalog…" : "Loading more…").foregroundStyle(.subtext)
            } else if catalog.hasMore {
                Button("Load More") { catalog.loadMore() }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.top, 4)
        if catalog.hasClientFilters, !catalog.items.isEmpty {
            Text("\(shown) of the \(catalog.items.count) titles loaded so far match. The catalog can't filter by this itself, so titles are checked as pages load.")
                .font(.caption).foregroundStyle(.subtext).frame(maxWidth: .infinity)
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
                    Image(systemName: "magnifyingglass").foregroundStyle(.subtext)
                    TextField("Search the catalog's music CDs", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit { catalog.query.text = draft }
                    if !draft.isEmpty {
                        Button { draft = ""; catalog.query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.subtext)
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
                .help("Compare with the albums in your music library")
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
                Button("Only \(catalog.homeLibrary) (My Library)") { catalog.query.libraries = [catalog.homeLibrary]; clearStaleAvailability() }
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
                    Text("Album details paused until \(until.formatted(date: .omitted, time: .shortened)) (the library asked for a break) · \(catalog.lookupRemaining) left")
                        .font(.caption).foregroundStyle(.subtext)
                } else {
                    Text("Looking up album details… \(catalog.lookupRemaining) left").font(.caption).foregroundStyle(.subtext)
                }
                Button { catalog.cancelLookups() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.subtext).help("Stop looking up albums")
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
    @Environment(\.theme) private var theme
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
                        Rectangle().fill(theme.fill)
                        Image(systemName: "opticaldisc").font(.system(size: 40)).foregroundStyle(.subtext)
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if owned {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, theme.accent)
                        .shadow(radius: 2).padding(6)
                        .help("In your library")
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
                .font(.subheadline).foregroundStyle(.subtext).lineLimit(1)
            HStack(spacing: 6) {
                CatalogStatusBadge(availability: item.availability, text: item.statusText, library: catalog.siteLibrary)
                if let year = details?.year ?? item.year { Text(String(year)).font(.caption).foregroundStyle(.subtext) }
            }
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
            Button("Show in My Library") { model.navigationPath.append(album) }
        }
        if let url = model.catalog.webURL(item.pagePath) {
            Link("Open in Library Catalog", destination: url)
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
    @Environment(\.theme) private var theme
    let item: CatalogItem
    @State private var cover: NSImage?
    @State private var descriptionExpanded = false
    @State private var loadingCopies = false

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
                                copiesSection
                                trackList(details)
                                editionsSection(details)
                            }
                            .padding(.vertical, 28).padding(.trailing, 28).padding(.leading, 4)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header(details, coverSize: min(300, geo.size.width - 48))
                            copiesSection
                            trackList(details)
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
                Button { catalog.ensureDetails(item, force: true) } label: { Label("Look Up Again", systemImage: "arrow.clockwise") }
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
                        Rectangle().fill(theme.fill)
                        Image(systemName: "opticaldisc").font(.system(size: coverSize / 4)).foregroundStyle(.subtext)
                    }
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.bottom, 10)

            Text(typeLine(details)).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.subtext)
            Text(item.displayTitle).font(.system(size: 30, weight: .bold)).lineLimit(3).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            if let mbTitle = details?.mbTitle, CatalogText.key(mbTitle) != CatalogText.key(item.displayTitle) {
                Text("Released as “\(mbTitle)”").font(.callout).foregroundStyle(.subtext)
            }
            artistLine(details)
            if let meta = metaLine(details) { Text(meta).font(.callout).foregroundStyle(.subtext) }
            if let info = details?.album, let rating = info.rating { RatingView(rating: rating, votes: info.ratingVotes) }
            if let genres = details?.album?.genres, !genres.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(genres, id: \.self) { g in
                        Text(g.capitalized).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(theme.fill))
                    }
                }
            }
            HStack(spacing: 10) {
                if let owned {
                    Button { model.navigationPath.append(owned) } label: { Label("In Your Library", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(.borderedProminent)
                        .help("Open \(owned.album) in your library")
                } else {
                    Label("Not in your library", systemImage: "circle.dashed")
                        .foregroundStyle(.subtext)
                        .padding(.trailing, 6)
                }
                CatalogListButton(item: item).buttonStyle(.bordered)
                if let url = catalog.webURL(item.pagePath) {
                    Link(destination: url) { Label("Open in Catalog", systemImage: "safari") }
                        .buttonStyle(.bordered)
                        .help("See this CD on the library's website, where you can place a hold")
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
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
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.subtext)
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(artist.name) in your library")
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
                    .help("Call number at \(item.shelfLocation ?? "the library")")
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
                        else { Text("From \(source)").font(.caption).foregroundStyle(.subtext) }
                    }
                }
            }
        } else if catalog.isLookingUp(item) {
            Label("Looking up this CD on MusicBrainz…", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.subtext)
        } else if let details, !details.isMatched {
            Label("This CD wasn't found on MusicBrainz.", systemImage: "questionmark.circle").font(.callout).foregroundStyle(.subtext)
        }
        releaseDetails(details)
        if let work = catalog.works[item.id], !work.contributors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Performers")
                ForEach(Array(work.contributors.prefix(16).enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline) {
                        PersonLink(name: CatalogText.displayName(c.name)) { model.showMusicDNA($0) }.fontWeight(.medium)
                        if let role = c.role { Text(role).foregroundStyle(.subtext) }
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
                                .background(Capsule().fill(theme.fill))
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
            ("Label", details?.label), ("Catalog #", details?.catalogNumber), ("Released", details?.releaseDate),
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
                            Text(k).foregroundStyle(.subtext)
                            Text(v).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: Tracks

    @ViewBuilder
    private func trackList(_ details: CatalogAlbumDetails?) -> some View {
        let tracks = details?.tracklist ?? []
        let contents = model.catalog.works[item.id]?.contents.first
        if !tracks.isEmpty {
            let discs = Array(Set(tracks.map(\.disc))).sorted()
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Tracks")
                card {
                    ForEach(discs, id: \.self) { disc in
                        if discs.count > 1 {
                            HStack {
                                Image(systemName: "opticaldisc").foregroundStyle(.subtext)
                                Text("Disc \(disc)").font(.callout.weight(.semibold))
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.top, disc == discs.first ? 10 : 18).padding(.bottom, 4)
                        }
                        ForEach(tracks.filter { $0.disc == disc }) { entry in
                            trackRow(number: entry.number, title: entry.title,
                                     artist: entry.artist == (details?.mbArtist ?? "") ? nil : entry.artist, duration: entry.duration)
                        }
                    }
                }
            }
        } else if let contents, !contents.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Tracks")
                card {
                    ForEach(Array(contents.tracks.enumerated()), id: \.offset) { i, title in
                        trackRow(number: i + 1, title: title, artist: nil, duration: nil)
                    }
                }
                Text("From the library's catalog record.").font(.caption).foregroundStyle(.subtext)
            }
        } else if model.catalog.isLookingUp(item) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Tracks")
                HStack { ProgressView().controlSize(.small); Text("Looking up the track list…").foregroundStyle(.subtext) }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.card.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5))
    }

    private func trackRow(number: Int, title: String, artist: String?, duration: Double?) -> some View {
        HStack(spacing: 12) {
            Text(String(number)).monospacedDigit().foregroundStyle(.subtext).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let artist, !artist.isEmpty {
                    PersonLinks(artist) { model.showMusicDNA($0) }.font(.caption)
                }
            }
            Spacer()
            Text(duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.subtext).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
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
                    Text("On the shelf at \(libraries) librar\(libraries == 1 ? "y" : "ies")").font(.callout).foregroundStyle(.subtext)
                }
                Button {
                    Task { loadingCopies = true; await catalog.loadCopies(item, force: true); loadingCopies = false }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(loadingCopies).help("Check availability again")
            }
            if copies.isEmpty {
                if loadingCopies {
                    HStack { ProgressView().controlSize(.small); Text("Checking the libraries…").foregroundStyle(.subtext) }
                } else {
                    Text(catalog.copiesError[item.id] ?? "No copy details from the catalog.").foregroundStyle(.subtext)
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
                    if home { Text("My Library").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(theme.fill)) }
                }
                Text(copy.location.components(separatedBy: " - ").dropFirst().joined(separator: " - "))
                    .font(.caption).foregroundStyle(.subtext)
            }
            Spacer()
            Text(copy.callNumber).font(.caption.monospaced()).foregroundStyle(.subtext).lineLimit(1).textSelection(.enabled)
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
                                    .font(.caption).foregroundStyle(.subtext).lineLimit(2)
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
    @Environment(\.theme) private var theme
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
                        Label("\(missing) of these CDs \(missing == 1 ? "isn't" : "aren't") in your library yet. Insert one to rip it from the Import section.",
                              systemImage: "opticaldisc")
                            .font(.callout).foregroundStyle(.subtext)
                    }
                    VStack(spacing: 0) {
                        ForEach(list) { row($0) }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(theme.card.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5))
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
                Text(catalogFailure ?? "Sign in to your library account in Settings to see what you have checked out.")
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
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
            Spacer()
            if let owned {
                Button { model.navigationPath.append(owned) } label: {
                    Label("In Your Library", systemImage: "checkmark.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open \(owned.album) in your library")
            } else if isMusic(checkout) {
                Text("Not in your library").font(.caption).foregroundStyle(.subtext)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(checkout.due.map { "Due \($0)" } ?? "").font(.caption.weight(soon ? .semibold : .regular))
                    .foregroundStyle(soon ? Color.red : Color.primary)
                if let renewed = checkout.renewed { Text("Renewed \(renewed)").font(.caption2).foregroundStyle(.subtext) }
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

struct CheckoutCover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let path: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(theme.fill)
                Image(systemName: "opticaldisc").foregroundStyle(.subtext)
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
                    .help("Remove this CD from your list on the library's website")
            } else {
                Button { catalog.addToList(item) } label: { Label("Add to \(catalog.listTitle)", systemImage: "bookmark") }
                    .disabled(busy)
                    .help("Add this CD to your list on the library's website, so you know what to look for")
            }
        }
    }
}

/// The list chosen in Settings: what's on it, where it's on the shelf, and removing titles.
struct CatalogListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let catalog = model.catalog
        let entries = catalog.listEntries
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let url = catalog.webURL(catalog.listId.isEmpty ? "/MyAccount/Lists" : CatalogPaths.list(catalog.listId)) {
                        Link("Open on the Library's Website", destination: url).font(.callout)
                    }
                    Spacer()
                    if catalog.listLoading { ProgressView().controlSize(.small) }
                    LookupStatus()
                }
                if let error = catalog.listError { CatalogErrorBanner(message: error) { catalog.loadList() } }
                if !entries.isEmpty {
                    let here = entries.filter { $0.item.availability == .here }.count
                    let site = catalog.siteLibrary ?? "your library"
                    Text("\(here) of \(entries.count) on the shelf at \(site) right now.").font(.callout).foregroundStyle(.subtext)
                    VStack(spacing: 0) {
                        ForEach(entries) { row($0) }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 14).fill(theme.card.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5))
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
                    Text("Sign in to your library account in Settings, then pick the list to use.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            }
        } else if catalog.listId.isEmpty {
            ContentUnavailableView {
                Label("No List Chosen", systemImage: "bookmark")
            } description: {
                Text("Pick one of your library lists in Settings ▸ Library. CDs you add while browsing go there.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if catalog.listLoaded, entries.isEmpty {
            ContentUnavailableView("Nothing on This List Yet", systemImage: "bookmark",
                                   description: Text("Add CDs from Library CDs with the bookmark button or by right-clicking them."))
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
                            .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                    }
                    Spacer()
                    if let call = item.callNumber, item.availability == .here {
                        Text(call).font(.caption.monospaced()).foregroundStyle(.subtext).lineLimit(1)
                    }
                    CatalogStatusBadge(availability: item.availability, text: item.statusText, library: catalog.siteLibrary)
                    if owned != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent).help("In your library")
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
    @Environment(\.theme) private var theme
    let item: CatalogItem
    @State private var image: NSImage?

    var body: some View {
        let d = model.catalog.details[item.id]
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(theme.fill)
                Image(systemName: "opticaldisc").foregroundStyle(.subtext)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(item.id)|\(d?.releaseId ?? d?.releaseGroupId ?? "")") {
            if let found = await model.catalog.cover(for: item) { image = found }
        }
    }
}
