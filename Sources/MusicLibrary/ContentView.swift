import MusicLibraryCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MainWindow()
            .onAppear { model.applyAppearance() }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all
    /// The sidebar's width, so the floating player centers over the pages beside it.
    @State private var sidebarWidth: CGFloat = 220

    var body: some View {
        let expanded = model.nowPlayingExpanded && model.player.currentTrack != nil
        // The player floats over the bottom of the pages as an overlay on the split view. Pages pushed onto a
        // NavigationStack draw over anything else in their column on macOS, so it must live outside the column.
        VStack(spacing: 0) {
            // The queue is a pane beside the split view, not an `.inspector`: on macOS 27 a NavigationSplitView with an
            // inspector can loop through constraint passes until AppKit throws (showing it, or restoring the window at
            // launch, crashed the app).
            HStack(spacing: 0) {
                splitView
                    .overlay(alignment: .bottom) {
                        if !expanded {
                            NowPlayingBar()
                                .padding(.horizontal, 20)
                                .padding(.bottom, 14)
                                .padding(.leading, columns == .detailOnly ? 0 : sidebarWidth)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                // The Radio DJ stays on the air beside the pages while you browse.
                if let session = model.radioDJ.session {
                    RadioDJPanel(session: session, dj: model.radioDJ, previews: model.previews) { model.openRadioDJ($0) }
                        .frame(width: RadioDJPanel.width)
                        .layoutPriority(1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if model.showsQueue {
                    Divider()
                    QueueView().frame(width: 300)
                }
            }
            .accessibilityHidden(expanded)
            // Same reason as the bar: inside the detail column it would sit under pushed pages.
            .overlay {
                if expanded {
                    NowPlayingView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.35), value: expanded)
        .animation(.easeInOut(duration: 0.25), value: model.radioDJ.session == nil)
        .onChange(of: model.player.currentTrack == nil) { _, noTrack in
            if noTrack { model.nowPlayingExpanded = false }
        }
    }

    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
        } detail: {
            VStack(spacing: 0) {
                if !model.ffmpegAvailable { MissingToolsBanner() }
                // One navigation stack for the whole content area; pages push albums and artists onto it.
                // Every page leaves room under its last row for the floating player. Each page root gets it: on macOS a
                // NavigationStack doesn't pass its own safe area on to the pages pushed onto it.
                NavigationStack(path: $model.navigationPath) {
                    DetailRouter().playerClearance()
                        .navigationDestination(for: AlbumSummary.self) { AlbumDetail(album: $0).playerClearance() }
                        .navigationDestination(for: ArtistSummary.self) { ArtistDetail(artist: $0).playerClearance() }
                        .navigationDestination(for: ArtistRoute.self) { ArtistDetail(name: $0.name).playerClearance() }
                        .navigationDestination(for: CatalogItem.self) { CatalogDetail(item: $0).playerClearance() }
                        .navigationDestination(for: CollectionItemRoute.self) { CollectionItemDetail(id: $0.id).playerClearance() }
                }
            }
        }
        .toolbarBackground(.windowBackground, for: .windowToolbar)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search or filter (genre:jazz)")
        .toolbar {
            if model.radioDJ.isEnabled {
                ToolbarItem(placement: .primaryAction) { RadioDJToolbarButton() }
            }
        }
        .searchSuggestions { SearchSuggestions() }
        .onSubmit(of: .search) { model.recordRecentSearch() }
        .dropDestination(for: URL.self) { urls, _ in
            model.importURLs(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { model.exportState != nil }, set: { if !$0 { model.exportState = nil } })) {
            ExportSheet()
        }
        .sheet(item: $model.smartPlaylistDraft) { SmartPlaylistEditor(draft: $0) }
        .sheet(item: $model.collectionSheet) { sheet in
            switch sheet {
            case .add(let medium, let prefill): AddToCollectionSheet(medium: medium, prefill: prefill)
            case .findByLabel(let sticker): FindByLabelPanel(initial: sticker)
            case .addLibraryAlbums: BulkAddSheet()
            case .labelCheck: LabelCheckSheet()
            case .link(let id): LinkAlbumPicker(itemID: id)
            case .cover(let id, let request): CollectionCoverSheet(itemID: id, request: request)
            case .changeEdition(let id): ChangeEditionSheet(itemID: id)
            }
        }
        .removeFromLibraryConfirmation(model)
        .collectionRemovalConfirmation(model)
    }
}

struct MissingToolsBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("ffmpeg/ffprobe not found. Importing and tag writing are disabled. Install with `brew install ffmpeg`, then reopen Settings to re-check.")
                .font(.callout)
            Spacer()
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("Listen Now", systemImage: "play.circle").tag(SidebarItem.listenNow)
            // Both collections together: what's on the shelf first, then what's digital (downloads are digital).
            Section("Collection") {
                ForEach(CollectionScope.allCases.filter { $0 != .downloads }, id: \.self) { scope in
                    let count = model.collection.count(scope)
                    // To Digitize only while something is waiting (or it's the page showing).
                    if scope != .toDigitize || count > 0 || model.sidebar == .collection(.toDigitize) {
                        Label(scope.title, systemImage: scope.symbol).badge(count).tag(SidebarItem.collection(scope))
                    }
                }
                Label("Albums", systemImage: "square.stack").badge(model.albums.count).tag(SidebarItem.albums)
                Label("Songs", systemImage: "music.note").badge(model.tracks.count).tag(SidebarItem.songs)
                Label(CollectionScope.downloads.title, systemImage: CollectionScope.downloads.symbol)
                    .badge(model.collection.count(.downloads))
                    .tag(SidebarItem.collection(.downloads))
            }
            Section("Explore") {
                // Artists from both collections, so they're with Insights, Music DNA and Concerts.
                Label("Artists", systemImage: "music.mic").badge(model.allArtists.count).tag(SidebarItem.artists)
                Label("Insights", systemImage: "chart.bar.xaxis").tag(SidebarItem.insights)
                Label("Music DNA", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.musicDNA)
                Label("Concerts", systemImage: "ticket").tag(SidebarItem.concerts)
            }
            // Ways music comes in: importing and ripping, recording records, the public library and the Shop.
            Section("Acquire") {
                Label("Import", systemImage: "square.and.arrow.down")
                    .badge(model.importer.pendingCount)
                    .tag(SidebarItem.importQueue)
                ForEach(model.cd.discs) { disc in
                    Label(disc.title, systemImage: "opticaldisc")
                        .badge(disc.isRipping ? disc.remainingCount : 0)
                        .tag(SidebarItem.cd(disc.id))
                }
                Label("Digitize Vinyl", systemImage: "waveform.badge.mic")
                    .tag(SidebarItem.digitizeVinyl)
                Label("Local Library CDs", systemImage: "building.columns").tag(SidebarItem.catalog)
                Label("My Checkouts", systemImage: "books.vertical")
                    .badge(model.catalog.cdCheckouts.count)
                    .tag(SidebarItem.catalogCheckouts)
                Label(model.catalog.listTitle, systemImage: "bookmark")
                    .badge(model.catalog.listEntries.count)
                    .tag(SidebarItem.catalogList)
                Label("Shop", systemImage: "cart").tag(SidebarItem.cdShop)
            }
            Section("Devices") {
                Label("iPhone", systemImage: "iphone")
                    .badge(model.iPhone.selection.included.count)
                    .tag(SidebarItem.iPhone)
                Label("Export List", systemImage: "externaldrive")
                    .badge(model.exportList.count)
                    .tag(SidebarItem.exportList)
            }
            Section {
                Label(AppModel.likedSongsName, systemImage: "heart.fill")
                    .badge(model.likedDates.count)
                    .tag(SidebarItem.likedSongs)
                    .contextMenu {
                        Button("Play") { model.player.play(queue: model.likedTracks, startAt: 0, source: AppModel.likedSongsName) }
                        QueueMenuButtons(player: model.player) { model.likedTracks }
                        Divider()
                        AddToExportListButton([.likedSongs])
                    }
                ForEach(model.playlists) { p in
                    PlaylistRow(playlist: p).tag(SidebarItem.playlist(p.id))
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { model.createPlaylist() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Playlist")
                }
            }
            Section {
                ForEach(model.smartPlaylists) { p in
                    Label(p.name, systemImage: "gearshape")
                        .badge(model.smartPlaylistCounts[p.id] ?? 0)
                        .tag(SidebarItem.smartPlaylist(p.id))
                        .contextMenu {
                            Button("Play") { model.player.play(queue: model.smartPlaylistTracks(p), startAt: 0, source: p.name) }
                            QueueMenuButtons(player: model.player) { model.smartPlaylistTracks(p) }
                            Divider()
                            Button("Edit…") { model.editSmartPlaylist(p) }
                            AddToExportListButton([.smartPlaylist(p.id)])
                            Button("Delete", role: .destructive) { model.deleteSmartPlaylist(p.id) }
                        }
                }
            } header: {
                HStack {
                    Text("Smart Playlists")
                    Spacer()
                    Button { model.newSmartPlaylist() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Smart Playlist")
                }
            }
        }
    }
}

struct PlaylistRow: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.renamingPlaylistID == playlist.id {
                TextField("Name", text: $draft)
                    .focused($focused)
                    .onSubmit { model.renamePlaylist(playlist.id, to: draft) }
                    .onExitCommand { model.renamingPlaylistID = nil }
                    .onAppear { draft = playlist.name; focused = true }
            } else {
                Label(playlist.name, systemImage: "music.note.list").badge(playlist.trackCount)
            }
        }
        .contextMenu {
            Button("Play") { model.player.play(queue: model.playlistTracks(playlist.id), startAt: 0, source: playlist.name) }
            QueueMenuButtons(player: model.player) { model.playlistTracks(playlist.id) }
            Divider()
            Button("Rename") { model.renamingPlaylistID = playlist.id }
            AddToExportListButton([.playlist(playlist.id)])
            Button("Delete", role: .destructive) { model.deletePlaylist(playlist.id) }
        }
    }
}

struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSearching {
            SearchResultsView()
        } else {
            destination
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch model.sidebar ?? .songs {
        case .listenNow: ListenNowView()
        case .collection(let scope): CollectionView(scope: scope).id(scope)
        case .songs: SongsView()
        case .insights: InsightsView()
        case .musicDNA: MusicDNAView()
        case .concerts: ConcertsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .importQueue: ImportView()
        case .digitizeVinyl: VinylDigitizeView()
        case .exportList: ExportListView()
        case .iPhone: IPhoneSyncView()
        case .catalog: CatalogView()
        case .catalogCheckouts: CatalogCheckoutsView()
        case .catalogList: CatalogListView()
        case .cdShop: CDShopView()
        case .likedSongs: LikedSongsView()
        case .cd(let path):
            if let disc = model.cd.discs.first(where: { $0.id == path }) {
                CDView(disc: disc).id(path)
            } else {
                ContentUnavailableView("Disc not found", systemImage: "opticaldisc")
            }
        case .playlist(let id):
            if let p = model.playlists.first(where: { $0.id == id }) {
                PlaylistView(playlist: p).id(id)
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        case .smartPlaylist(let id):
            if let p = model.smartPlaylists.first(where: { $0.id == id }) {
                SmartPlaylistView(playlist: p).id(id)
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "gearshape")
            }
        }
    }
}

extension CollectionScope {
    /// The scope's sidebar icon.
    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .cds: "opticaldisc"
        case .vinyl: "record.circle"
        case .downloads: "arrow.down.circle"
        case .toDigitize: "waveform.slash"
        }
    }
}
