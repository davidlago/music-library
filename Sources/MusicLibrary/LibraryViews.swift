import MusicLibraryCore
import SwiftUI

struct TrackTable: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    /// Title and message shown when `tracks` is empty; defaults suit the whole library or a search.
    var emptyState: (title: String, message: String)?
    /// What the list is, for the queue's "Next from …".
    var source: String?
    @State private var selection = Set<Track.ID>()
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var pendingRemoval: Set<Track.ID>?
    @State private var infoTrack: Track?

    private var sorted: [Track] { sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder) }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("Composer", value: \.composer) { PersonLinks($0.composer) }
            TableColumn("Year", value: \.yearSort) { Text($0.year.map(String.init) ?? "") }.width(50)
            TableColumn("Track", value: \.trackSort) { Text($0.trackNo.map(String.init) ?? "") }.width(50)
            TableColumn("Time", value: \.duration) { Text(formatTime($0.duration)).monospacedDigit() }.width(60)
            TableColumn("Format", value: \.formatSort) { Text($0.formatLabel) }.width(90)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if !ids.isEmpty { menu(for: ids) }
        } primaryAction: { ids in
            let list = sorted
            if let idx = list.firstIndex(where: { ids.contains($0.id) }) { model.player.play(queue: list, startAt: idx, source: source) }
        }
        .themedScrollBackground()
        .sheet(item: $infoTrack) { TrackInfoSheet(track: $0).themedSheet() }
        .background {
            Button("Get Info") { showInfo(for: selection) }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.count ?? 0) song\(pendingRemoval?.count == 1 ? "" : "s") from the library?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move Files to Trash", role: .destructive) {
                if let ids = pendingRemoval { model.removeFromLibrary(ids); selection.subtract(ids) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { Text("The files are moved to the Trash and removed from all playlists.") }
        .overlay {
            if tracks.isEmpty {
                let empty = emptyState ?? (model.isSearching
                    ? ("No Results", "Nothing matches “\(model.searchText)”.")
                    : ("No Songs", "Drop audio files or folders here, or use File ▸ Import…"))
                ContentUnavailableView(empty.title, systemImage: "music.note", description: Text(empty.message))
                    .allowsHitTesting(false)
            }
        }
    }

    private func showInfo(for ids: Set<Track.ID>) {
        guard ids.count == 1, let id = ids.first else { return }
        infoTrack = tracks.first { $0.id == id }
    }

    @ViewBuilder
    private func menu(for ids: Set<Track.ID>) -> some View {
        let chosen = sorted.filter { ids.contains($0.id) }
        Button("Play") {
            let list = sorted
            if let idx = list.firstIndex(where: { ids.contains($0.id) }) { model.player.play(queue: list, startAt: idx, source: source) }
        }
        QueueMenuButtons(player: model.player) { chosen }
        Menu("Add to Playlist") {
            ForEach(model.playlists) { p in
                Button(p.name) { model.add(chosen.map(\.id), toPlaylist: p.id) }
            }
            if !model.playlists.isEmpty { Divider() }
            Button("New Playlist…") { model.createPlaylist(adding: chosen.map(\.id)) }
        }
        AddToExportListButton(tracks: chosen)
        if ids.count == 1 { Button("Get Info") { showInfo(for: ids) } }
        if ids.count == 1, let track = chosen.first {
            let people = model.people(on: track)
            if !people.isEmpty {
                Menu("Music DNA") {
                    ForEach(people, id: \.self) { name in Button(name) { model.showMusicDNA(name) } }
                }
            }
        }
        Divider()
        Button("Show in Finder") { model.showInFinder(chosen) }
        Button("Remove from Library…", role: .destructive) { pendingRemoval = ids }
    }
}

struct SongsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TrackTable(tracks: model.tracks, source: "Songs")
            .navigationTitle("Songs")
            .navigationSubtitle(model.tracks.count == 1 ? "1 song" : "\(model.tracks.count) songs")
    }
}

struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("albumSort") private var sort = AlbumSort.artist

    enum AlbumSort: String, CaseIterable, Identifiable {
        case added, title, artist, year, mostPlayed, recent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .added: "Date Added"
            case .title: "Title"
            case .artist: "Artist"
            case .year: "Release Year"
            case .mostPlayed: "Most Played"
            case .recent: "Recently Played"
            }
        }
    }

    var body: some View {
        let shown = sorted(model.albums)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], spacing: 18) {
                    ForEach(shown) { a in
                        NavigationLink(value: a) {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverThumb(url: model.coverURL(forAlbum: a), size: 150)
                                Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.headline).lineLimit(1)
                                Text(a.artist.isEmpty ? "Unknown Artist" : a.artist).font(.subheadline).foregroundStyle(.subtext).lineLimit(1)
                                if let detail = detail(a) {
                                    Text(detail).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                                }
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            AlbumMenuButtons(album: a)
                            Divider()
                            AddToExportListButton(album: a)
                        }
                    }
                }
            }
            .padding(20)
        }
        .overlay { if model.albums.isEmpty { ContentUnavailableView("No Albums", systemImage: "square.stack") } }
        .navigationTitle("Albums")
        .navigationSubtitle(model.albums.count == 1 ? "1 album" : "\(model.albums.count) albums")
    }

    private func key(_ a: AlbumSummary) -> String { AlbumInfoStore.key(a) }

    /// Albums arrive sorted by artist; other orders are stable on top of that.
    private func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        func plays(_ a: AlbumSummary) -> PlayTotal { model.albumPlayTotals[key(a)] ?? PlayTotal() }
        func by<T: Comparable>(_ value: (AlbumSummary) -> T, descending: Bool) -> [AlbumSummary] {
            albums.enumerated().sorted { x, y in
                let a = value(x.element), b = value(y.element)
                return a != b ? (descending ? a > b : a < b) : x.offset < y.offset
            }.map(\.element)
        }
        switch sort {
        case .artist: return albums
        case .added: return by({ model.albumAddedDates[key($0)] ?? .distantPast }, descending: true)
        case .title: return by({ $0.album.isEmpty ? "\u{FFFF}" : $0.album.lowercased() }, descending: false)
        case .year: return by({ $0.year ?? Int.min }, descending: true)
        case .mostPlayed: return by({ plays($0).plays * 1_000_000 + Int(plays($0).listened) }, descending: true)
        case .recent: return by({ plays($0).lastPlayed ?? .distantPast }, descending: true)
        }
    }

    /// A third line matching the sort, so the order makes sense at a glance.
    private func detail(_ a: AlbumSummary) -> String? {
        switch sort {
        case .added:
            return model.albumAddedDates[key(a)].map { "Added " + $0.formatted(.relative(presentation: .named)) }
        case .year:
            return a.year.map(String.init)
        case .mostPlayed:
            let p = model.albumPlayTotals[key(a)] ?? PlayTotal()
            if p.plays > 0 { return "\(p.plays) play\(p.plays == 1 ? "" : "s") · \(formatListened(p.listened))" }
            return p.listened >= 1 ? formatListened(p.listened) + " listened" : nil
        case .recent:
            return model.albumPlayTotals[key(a)]?.lastPlayed.map { "Played " + $0.formatted(.relative(presentation: .named)) }
        case .title, .artist:
            return nil
        }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var selection = Set<Int>()

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { position, t in
                HStack {
                    Text("\(position + 1)").monospacedDigit().foregroundStyle(.subtext).frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading) {
                        Text(t.title).lineLimit(1)
                        Text("\(t.artist) — \(t.album)").font(.caption).foregroundStyle(.subtext).lineLimit(1)
                    }
                    Spacer()
                    Text(formatTime(t.duration)).monospacedDigit().foregroundStyle(.subtext)
                }
                .tag(position)
            }
            .onMove { offsets, destination in
                model.movePlaylistTracks(playlist.id, from: Array(offsets), to: destination)
                reload()
            }
        }
        .themedScrollBackground()
        .onDeleteCommand { removeSelected() }
        .contextMenu(forSelectionType: Int.self) { positions in
            if !positions.isEmpty {
                Button("Play") { play(from: positions.min() ?? 0) }
                QueueMenuButtons(player: model.player) { positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
                Button("Show in Finder") { model.showInFinder(positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }) }
                AddToExportListButton(tracks: positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil })
                Divider()
                Button("Remove from Playlist") { remove(positions) }
            }
        } primaryAction: { positions in play(from: positions.min() ?? 0) }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list",
                                       description: Text("Right-click songs in your library and choose Add to Playlist."))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(playlist.name)
        .navigationSubtitle("\(tracks.count) songs")
        .toolbar {
            ToolbarItemGroup {
                Button("Play", systemImage: "play.fill") { play(from: 0) }.disabled(tracks.isEmpty)
                Button("Export…", systemImage: "square.and.arrow.up") { model.exportPlaylist(playlist) }.disabled(tracks.isEmpty)
                    .help("Copy this playlist into a single folder with an .m3u file")
                AddToExportListButton([.playlist(playlist.id)])
            }
        }
        .onAppear(perform: reload)
        .onChange(of: playlist.trackCount) { reload() }
        .onChange(of: model.totalTracks) { reload() }
    }

    private func reload() { tracks = model.playlistTracks(playlist.id) }

    private func play(from position: Int) { model.player.play(queue: tracks, startAt: position, source: playlist.name) }

    private func removeSelected() { remove(selection) }

    private func remove(_ positions: Set<Int>) {
        model.removeFromPlaylist(playlist.id, positions: Array(positions))
        selection = []
        reload()
    }
}

/// Context menu for an album cover: play it or queue it.
struct AlbumMenuButtons: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary

    var body: some View {
        let title = album.album.isEmpty ? "Unknown Album" : album.album
        Button("Play") { model.player.play(queue: model.tracks(of: album), startAt: 0, source: title) }
        Button("Shuffle") { model.player.play(queue: model.tracks(of: album).shuffled(), startAt: 0, source: title) }
        QueueMenuButtons(player: model.player) { model.tracks(of: album) }
    }
}

/// Context menu items for an artist: play or queue all their songs.
struct ArtistMenuButtons: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistSummary

    var body: some View {
        let name = artist.name.isEmpty ? "Unknown Artist" : artist.name
        Button("Play") { model.player.play(queue: model.tracks(ofArtist: artist.name), startAt: 0, source: name) }
        Button("Shuffle") { model.player.play(queue: model.tracks(ofArtist: artist.name).shuffled(), startAt: 0, source: name) }
        QueueMenuButtons(player: model.player) { model.tracks(ofArtist: artist.name) }
    }
}
