import MusicLibraryCore
import SwiftUI

/// The downloaded catalog, searched instantly in the app's query language, with genre and decade chips to
/// narrow the results.
struct DownloadedCatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let catalog = model.catalog
        let result = catalog.localResult
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DownloadedSearchBar()
                DownloadStatus()
                if !catalog.localQuery.issues.isEmpty {
                    Label(catalog.localQuery.issues.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                refine(result)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], spacing: 22) {
                    ForEach(result.records) { record in
                        NavigationLink(value: record.item) { CatalogCard(item: record.item) }
                            .buttonStyle(.plain)
                            .contextMenu { CatalogItemMenu(item: record.item) }
                    }
                }
            }
            .padding(20)
        }
        .overlay { emptyState(result) }
        .navigationTitle("Local Library CDs")
        .navigationSubtitle(subtitle(result))
        .toolbar {
            ToolbarItem {
                Button { catalog.downloadCatalogs(force: true) } label: { Label("Update", systemImage: "arrow.clockwise") }
                    .disabled(catalog.downloadProgress != nil)
                    .help("Download the catalog again for new titles and current availability")
            }
        }
    }

    private func subtitle(_ result: CatalogSearchResult) -> String {
        let all = model.catalog.index.count
        guard all > 0 else { return "" }
        let shown = result.records.count
        return shown == all ? "\(all.formatted()) CDs" : "\(shown.formatted()) of \(all.formatted()) CDs"
    }

    /// Genre and decade chips for the current results; clicking one adds it to the search.
    @ViewBuilder
    private func refine(_ result: CatalogSearchResult) -> some View {
        let catalog = model.catalog
        let genres = result.genres.prefix(14)
        if result.records.count > 1, !genres.isEmpty || result.decades.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                if !genres.isEmpty {
                    FlowLayout(spacing: 6) {
                        Text("Genres").font(.caption.weight(.semibold)).foregroundStyle(.subtext).padding(.trailing, 4)
                        ForEach(Array(genres), id: \.name) { g in
                            chip("\(g.name.capitalized) \(g.count)") { catalog.addToLocalSearch(SearchFilterKey.token("genre", g.name)) }
                        }
                    }
                }
                if result.decades.count > 1 {
                    FlowLayout(spacing: 6) {
                        Text("Decades").font(.caption.weight(.semibold)).foregroundStyle(.subtext).padding(.trailing, 4)
                        ForEach(result.decades, id: \.decade) { d in
                            chip("\(String(d.decade))s \(d.count)") { catalog.addToLocalSearch("decade:\(d.decade)s") }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(theme.fill))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(_ result: CatalogSearchResult) -> some View {
        let catalog = model.catalog
        if catalog.index.count == 0 {
            if let progress = catalog.downloadProgress {
                ContentUnavailableView {
                    Label("Downloading \(progress.library)'s CDs", systemImage: "arrow.down.circle")
                } description: {
                    Text("The whole catalog is downloaded once, then kept up to date. You can search it as soon as this page finishes.")
                }
            }
        } else if result.records.isEmpty {
            ContentUnavailableView("No CDs Match", systemImage: "magnifyingglass",
                                   description: Text("Try fewer filters, or search the whole network live from the libraries menu."))
        }
    }
}

/// The search field (with the filters it understands) and the library, availability, ownership, list and sort
/// controls for the downloaded catalog.
struct DownloadedSearchBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var catalog = model.catalog
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.subtext)
                    TextField("Search: miles davis   genre:jazz decade:60s -is:owned", text: $catalog.localText)
                        .textFieldStyle(.plain)
                    if !catalog.localText.isEmpty {
                        Button { catalog.localText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.subtext)
                            .help("Clear the search")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 560)
                filterHelp
                Spacer()
            }
            HStack(spacing: 10) {
                libraryMenu
                Picker("Availability", selection: $catalog.localAvailability) {
                    Text("Any Availability").tag(LibraryCatalogStore.LocalAvailability.any)
                    Text("On the Shelf at \(catalog.siteLibrary ?? "My Local Library")").tag(LibraryCatalogStore.LocalAvailability.available)
                    Text("Not on the Shelf").tag(LibraryCatalogStore.LocalAvailability.out)
                }
                .labelsHidden().fixedSize()
                .help("Availability as of the last update; the album page checks every library live")
                Picker("Ownership", selection: $catalog.localOwnership) {
                    ForEach(LibraryCatalogStore.OwnershipFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                if catalog.isSignedIn, !catalog.listId.isEmpty {
                    Toggle(isOn: $catalog.localOnList) { Label("On \(catalog.listTitle)", systemImage: "bookmark") }
                        .toggleStyle(.button)
                }
                Picker("Sort by", selection: $catalog.localSort) {
                    ForEach(CatalogLocalSort.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Spacer()
            }
        }
    }

    /// The filters the search understands; picking one adds its example to the search.
    private var filterHelp: some View {
        let catalog = model.catalog
        let keys = ["artist", "album", "title", "genre", "label", "year", "decade", "time", "added", "track", "disc", "is", "has", "missing"]
        return Menu {
            Section("Like the rest of the app") {
                ForEach(keys, id: \.self) { name in
                    if let key = SearchFilterKey.all.first(where: { $0.name == name }) {
                        Button("\(key.example) — \(help(key))") { catalog.addToLocalSearch(key.example) }
                    }
                }
            }
            Section("Local library catalog") {
                ForEach(CatalogSearchQuery.keys, id: \.name) { key in
                    Button("\(key.example) — \(key.help)") { catalog.addToLocalSearch(key.example) }
                }
            }
            Section {
                Text("-word excludes, OR combines, \"quotes\" match a phrase")
            }
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Filters you can use in the search")
    }

    /// Catalog meanings where they differ from the music library's.
    private func help(_ key: SearchFilterKey) -> String {
        switch key.name {
        case "title": "Song on the CD"
        case "time": "Album length"
        case "track": "Number of tracks"
        case "disc": "Number of discs"
        case "added": "New in the catalog within (since your first download)"
        case "is": "compilation, live, matched (on MusicBrainz), unmatched"
        default: key.help
        }
    }

    private var libraryMenu: some View {
        let catalog = model.catalog
        let label: String = switch catalog.localLibraries.count {
        case 0: catalog.downloadLibraries.count == 1 ? catalog.downloadLibraries[0] : "All Downloaded Libraries"
        case 1: catalog.localLibraries[0]
        default: "\(catalog.localLibraries[0]) + \(catalog.localLibraries.count - 1) more"
        }
        return Menu {
            if catalog.downloadLibraries.count > 1 {
                Button("All Downloaded Libraries") { catalog.localLibraries = [] }
                Divider()
                ForEach(catalog.downloadLibraries, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { catalog.localLibraries.contains(name) }, set: { on in
                        if on { catalog.localLibraries.append(name) } else { catalog.localLibraries.removeAll { $0 == name } }
                    }))
                }
                Divider()
            }
            Button("Search the Whole Network Live…") { catalog.liveMode = true }
            SettingsLink { Text("Download Other Libraries…") }
        } label: {
            Label(label, systemImage: "building.columns")
        }
        .fixedSize()
        .help("Downloaded libraries to show")
    }
}

/// Download progress, or when the catalog was last updated and how much of it has album details.
struct DownloadStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        HStack(spacing: 8) {
            if let progress = catalog.downloadProgress {
                ProgressView(value: Double(progress.page), total: Double(max(progress.pages ?? 1, 1)))
                    .frame(width: 120)
                if let until = progress.pausedUntil {
                    Text("Paused: the local library's website asked for a break. Resuming at \(until.formatted(date: .omitted, time: .shortened)) (page \(progress.page) of \(progress.pages ?? 0)).")
                        .font(.caption).foregroundStyle(.subtext)
                } else {
                    Text(progress.pages.map { "Downloading \(progress.library)'s CDs… page \(progress.page) of \($0)" }
                         ?? "Downloading \(progress.library)'s CDs…")
                        .font(.caption).foregroundStyle(.subtext)
                }
            } else if let error = catalog.downloadError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                Button("Try Again") { catalog.downloadCatalogs(force: true) }.controlSize(.small)
            } else if let date = catalog.lastDownload {
                Text("Updated \(date.formatted(.relative(presentation: .named))) · \(catalog.detailedCount.formatted()) of \(catalog.records.count.formatted()) with album details")
                    .font(.caption).foregroundStyle(.subtext)
            }
            Spacer()
            LookupStatus()
        }
    }
}

/// Settings ▸ Library: which libraries' catalogs to download.
struct CatalogDownloadSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        Section {
            ForEach(catalog.downloadLibraries, id: \.self) { name in
                LabeledContent(name) {
                    HStack {
                        let count = catalog.records.values.filter { $0.libraries.contains(name) }.count
                        Text(catalog.downloadDates[name] == nil ? "Not downloaded yet" : "\(count.formatted()) CDs")
                            .foregroundStyle(.subtext)
                        Button { catalog.removeDownload(name) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop downloading \(name)'s catalog")
                    }
                }
            }
            Menu("Add a Library…") {
                ForEach(catalog.libraryChoices.filter { !catalog.downloadLibraries.contains($0.name) }) { library in
                    Button(library.count.map { "\(library.name)  (\($0.formatted()) CDs, \(estimate($0)))" } ?? library.name) {
                        catalog.downloadLibraries.append(library.name)
                        catalog.downloadCatalogs()
                    }
                }
            }
            .fixedSize()
            HStack {
                Button("Update Now") { catalog.downloadCatalogs(force: true) }
                    .disabled(catalog.downloadProgress != nil || catalog.downloadLibraries.isEmpty)
                Button("Look Up Missing Album Details") { catalog.queueDownloadLookups() }
                    .disabled(catalog.records.isEmpty || !catalog.autoLookup)
                Spacer()
                if catalog.downloadProgress != nil { ProgressView().controlSize(.small) }
            }
            let missing = catalog.records.keys.filter { catalog.needsLookup($0) }.count
            if missing > 0 {
                Text("\(missing.formatted()) CDs still to look up on MusicBrainz, about \(duration(missing)) at its pace of one request a second.")
                    .font(.caption).foregroundStyle(.subtext)
            }
        } header: {
            Text("Downloaded catalogs")
        } footer: {
            Text("Every CD these libraries own is downloaded and searched on your Mac. New titles and availability are checked when the download is more than 12 hours old; album details are looked up once.")
                .font(.caption).foregroundStyle(.subtext)
        }
    }

    /// Roughly how long looking up `count` CDs takes (about 4.5 s each).
    private func duration(_ count: Int) -> String {
        let minutes = Int((Double(count) * 4.5 / 60).rounded(.up))
        return minutes < 90 ? "\(minutes) min" : "\(Int((Double(minutes) / 60).rounded())) hours"
    }

    private func estimate(_ count: Int) -> String { "about \(duration(count)) to look up" }
}
