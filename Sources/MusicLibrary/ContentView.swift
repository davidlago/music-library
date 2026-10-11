import MusicLibraryCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MainWindow()
            .themedRoot(model.theme)
            .onAppear { model.applyAppearance() }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var dropTargeted = false

    var body: some View {
        let expanded = model.nowPlayingExpanded && model.player.currentTrack != nil
        // The player bar spans the window below the split view. Pages pushed onto a NavigationStack draw over
        // anything else in their column on macOS, so the bar must live outside the column to stay visible.
        VStack(spacing: 0) {
            splitView
                .accessibilityHidden(expanded)
                // Same reason as the bar: inside the detail column it would sit under pushed pages.
                .overlay {
                    if expanded {
                        NowPlayingView()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            if !expanded {
                Divider()
                NowPlayingBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: expanded)
        .onChange(of: model.player.currentTrack == nil) { _, noTrack in
            if noTrack { model.nowPlayingExpanded = false }
        }
    }

    private var splitView: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SidebarView()
                .scrollContentBackground(theme.isThemed ? .hidden : .automatic)
                .background(theme.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !model.ffmpegAvailable { MissingToolsBanner() }
                // One navigation stack for the whole content area; pages push albums and artists onto it.
                NavigationStack(path: $model.navigationPath) {
                    DetailRouter()
                        .navigationDestination(for: AlbumSummary.self) { AlbumDetail(album: $0) }
                        .navigationDestination(for: ArtistSummary.self) { ArtistDetail(artist: $0) }
                        .navigationDestination(for: CatalogItem.self) { CatalogDetail(item: $0) }
                }
            }
            .background(theme.isThemed ? theme.background : Color.clear)
        }
        .inspector(isPresented: $model.showsQueue) {
            QueueView().inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbarBackground(theme.toolbar, for: .windowToolbar)
        .toolbarBackground(theme.isThemed ? .visible : .automatic, for: .windowToolbar)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search or filter (genre:jazz)")
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
            ExportSheet().themedSheet()
        }
        .sheet(item: $model.smartPlaylistDraft) { SmartPlaylistEditor(draft: $0).themedSheet() }
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
            Section("Library") {
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Artists", systemImage: "music.mic").tag(SidebarItem.artists)
                Label("Insights", systemImage: "chart.bar.xaxis").tag(SidebarItem.insights)
                Label("Music DNA", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.musicDNA)
                Label("Concerts", systemImage: "ticket").tag(SidebarItem.concerts)
            }
            Section("Import") {
                Label("Import", systemImage: "square.and.arrow.down")
                    .sidebarBadge(model.importer.pendingCount)
                    .tag(SidebarItem.importQueue)
                ForEach(model.cd.discs) { disc in
                    Label(disc.title, systemImage: "opticaldisc")
                        .sidebarBadge(disc.isRipping ? disc.remainingCount : 0)
                        .tag(SidebarItem.cd(disc.id))
                }
            }
            Section("Library Catalog") {
                Label("Library CDs", systemImage: "building.columns").tag(SidebarItem.catalog)
                Label("My Checkouts", systemImage: "books.vertical")
                    .sidebarBadge(model.catalog.cdCheckouts.count)
                    .tag(SidebarItem.catalogCheckouts)
                Label(model.catalog.listTitle, systemImage: "bookmark")
                    .sidebarBadge(model.catalog.listEntries.count)
                    .tag(SidebarItem.catalogList)
            }
            Section("Export") {
                Label("Export List", systemImage: "externaldrive")
                    .sidebarBadge(model.exportList.count)
                    .tag(SidebarItem.exportList)
            }
            Section {
                Label(AppModel.likedSongsName, systemImage: "heart.fill")
                    .sidebarBadge(model.likedDates.count)
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
                        .sidebarBadge(model.smartPlaylistCounts[p.id] ?? 0)
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
                Label(playlist.name, systemImage: "music.note.list").sidebarBadge(playlist.trackCount)
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
        case .songs: SongsView()
        case .insights: InsightsView()
        case .musicDNA: MusicDNAView()
        case .concerts: ConcertsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .importQueue: ImportView()
        case .exportList: ExportListView()
        case .catalog: CatalogView()
        case .catalogCheckouts: CatalogCheckoutsView()
        case .catalogList: CatalogListView()
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
