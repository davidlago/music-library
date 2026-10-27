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
    @State private var infoTrack: Track?

    private var sorted: [Track] { sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder) }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Text(Image(systemName: "heart")).accessibilityLabel("Liked")) { LikeButton(model: model, track: $0) }.width(22)
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("Composer", value: \.composer) { PersonLinks($0.composer) { model.showMusicDNA($0) } }
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
        .sheet(item: $infoTrack) { TrackInfoSheet(track: $0) }
        .background {
            Button("Get Info") { showInfo(for: selection) }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
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
        LikeMenuButton(tracks: chosen)
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
        RemoveFromLibraryButton(tracks: chosen)
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

/// The Albums grid's Owned menu: every album, or only those you have (or don't have) a copy of.
enum AlbumsCollectionFilter: String, CaseIterable, Identifiable {
    case all, inCollection, notInCollection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Albums"
        case .inCollection: "Albums You Own"
        case .notInCollection: "Albums You Don't Own"
        }
    }
}

struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @AppStorage("albumSort") private var sort = AlbumSort.artist
    @AppStorage("albumsCollectionFilter") private var filter = AlbumsCollectionFilter.all
    /// Before the collection: only albums you own. Read once as In Your Collection.
    @AppStorage("albumsOwnedOnly") private var ownedOnly = false

    var body: some View {
        let shown = sorted(filtered(model.albums))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Owned", selection: $filter) {
                        ForEach(AlbumsCollectionFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .help("Show every album, or only those you have a copy of (a CD, a record or a download), or don't")
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18, alignment: .top)], spacing: 18) {
                    ForEach(shown) { a in
                        let mark = model.copyMark(for: a)
                        NavigationLink(value: a) {
                            VStack(alignment: .leading, spacing: 4) {
                                CopyArt(mark: mark, url: model.coverURL(forAlbum: a), width: 150, revision: model.coverRevision)
                                    .overlay(alignment: .topTrailing) { copiesChip(mark) }
                                    .padding(.bottom, 4)
                                Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.headline).lineLimit(1)
                                Text(a.artist.isEmpty ? "Unknown Artist" : a.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                if let detail = detail(a) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            AlbumMenuButtons(album: a)
                            Divider()
                            addToCollectionMenu(a)
                            AddToExportListButton(album: a)
                            Divider()
                            RemoveFromLibraryButton(album: a)
                        }
                    }
                }
                if shown.isEmpty, !model.albums.isEmpty {
                    // Below the controls, not over them, so the filter can be switched back.
                    ContentUnavailableView(filter == .inCollection ? "No Albums You Own" : "No Albums",
                                           systemImage: "opticaldisc",
                                           description: Text(filter == .inCollection
                                                             ? "Add a copy on an album's page, or right-click an album and choose I Own This."
                                                             : "You own a copy of every album in your digital collection."))
                        .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .overlay {
            if model.albums.isEmpty { ContentUnavailableView("No Albums", systemImage: "square.stack") }
        }
        .navigationTitle("Albums")
        .navigationSubtitle(shown.count == 1 ? "1 album" : "\(shown.count) albums")
        .onAppear {
            if ownedOnly {
                ownedOnly = false
                if filter == .all { filter = .inCollection }
            }
        }
    }

    private func filtered(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        switch filter {
        case .all: albums
        case .inCollection: albums.filter { !model.collection.copies(albumKey: key($0)).isEmpty }
        case .notInCollection: albums.filter { model.collection.copies(albumKey: key($0)).isEmpty }
        }
    }

    /// "2" in the corner of an album you have more than one copy of.
    @ViewBuilder
    private func copiesChip(_ mark: CopyMark) -> some View {
        let more: Int = switch mark {
        case .cd(_, _, let more), .vinyl(_, _, let more), .download(_, let more), .other(let more): more
        case .notInCollection: 0
        }
        if more > 0 {
            Text("\(more + 1)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.65)))
                .padding(4)
                .help("You have \(more + 1) copies of this album")
                .accessibilityLabel("\(more + 1) copies")
        }
    }

    /// I Own This ▸ As CD / As Vinyl / As Download, each with the next label in its series; ⌘Z undoes it.
    private func addToCollectionMenu(_ a: AlbumSummary) -> some View {
        Menu("I Own This") {
            ForEach(CollectionMedium.known, id: \.self) { medium in
                let next = medium.series.map { " (\($0.name) #\(model.nextNumber(in: $0)))" } ?? ""
                Button("As \(medium.name)\(next)") { addCopy(of: a, medium: medium) }
            }
        }
    }

    private func addCopy(of album: AlbumSummary, medium: CollectionMedium) {
        guard let saved = model.addCopy(of: album, medium: medium) else { return }
        let id = saved.id
        undoManager?.registerUndo(withTarget: model) { model in
            // Only the item just added, and only while nothing else changed it.
            MainActor.assumeIsolated {
                if let current = model.item(id: id), abs(current.updatedAt.timeIntervalSince(saved.updatedAt)) < 0.001 {
                    model.deleteItem(id: id)
                }
            }
        }
        undoManager?.setActionName("Add Copy")
    }

    private func key(_ a: AlbumSummary) -> String { AlbumInfoStore.key(a) }

    private func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        sort.sorted(albums, added: model.albumAddedDates, plays: model.albumPlayTotals)
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
                    Text("\(position + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading) {
                        Text(t.title).lineLimit(1)
                        Text("\(t.artist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    LikeButton(model: model, track: t)
                    Text(formatTime(t.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(position)
            }
            .onMove { offsets, destination in
                model.movePlaylistTracks(playlist.id, from: Array(offsets), to: destination)
                reload()
            }
        }
        .onDeleteCommand { removeSelected() }
        .contextMenu(forSelectionType: Int.self) { positions in
            if !positions.isEmpty {
                Button("Play") { play(from: positions.min() ?? 0) }
                QueueMenuButtons(player: model.player) { positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
                LikeMenuButton(tracks: positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil })
                Button("Show in Finder") { model.showInFinder(positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil }) }
                AddToExportListButton(tracks: positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil })
                Divider()
                Button("Remove from Playlist") { remove(positions) }
                RemoveFromLibraryButton(tracks: positions.sorted().compactMap { tracks.indices.contains($0) ? tracks[$0] : nil })
            }
        } primaryAction: { positions in play(from: positions.min() ?? 0) }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list",
                                       description: Text("Right-click songs in your digital collection and choose Add to Playlist."))
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

/// "Remove from Digital Collection…" for songs or a whole album; `removeFromLibraryConfirmation` asks before anything goes.
struct RemoveFromLibraryButton: View {
    @Environment(AppModel.self) private var model
    var tracks: [Track] = []
    var album: AlbumSummary?

    var body: some View {
        Button("Remove from Digital Collection…", role: .destructive) {
            if let album {
                model.confirmRemoval(model.tracks(of: album), title: album.album.isEmpty ? "Unknown Album" : album.album)
            } else {
                model.confirmRemoval(tracks)
            }
        }
    }
}

extension View {
    /// " Your copy CD #12 stays in your physical collection, marked not ripped.", for the items whose album leaves the
    /// library.
    fileprivate static func keptCopies(_ items: [CollectionItem]) -> String {
        guard let first = items.first else { return "" }
        func name(_ item: CollectionItem) -> String { item.sticker?.text ?? item.medium.name.lowercased() }
        func marked(_ item: CollectionItem) -> String {
            switch item.medium {
            case .cd: "not ripped"
            case .download: "not in your digital collection"
            case .vinyl, .other: "not digitized"
            }
        }
        let place = items.allSatisfy(\.medium.isPhysical) ? "your physical collection"
            : items.allSatisfy({ $0.medium == .download }) ? "your downloads" : "what you own"
        if items.count == 1 { return " Your copy \(name(first)) stays in \(place), marked \(marked(first))." }
        return " Your \(items.count) copies (\(items.prefix(3).map(name).joined(separator: ", "))\(items.count > 3 ? "…" : "")) stay in \(place)."
    }

    /// Asks before removing `model.pendingRemoval` from the library. Shown once, by `ContentView`.
    func removeFromLibraryConfirmation(_ model: AppModel) -> some View {
        let request = model.pendingRemoval
        let count = request?.tracks.count ?? 0
        let what = request?.title.map { "“\($0)”" }
            ?? (count == 1 ? request.map { "“\($0.tracks[0].title)”" } ?? "1 song" : "\(count) songs")
        return confirmationDialog(
            "Remove \(what) from your digital collection?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: request
        ) { request in
            Button("Move to Trash", role: .destructive) { model.removeFromLibrary(Set(request.tracks.map(\.id))) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            let n = request.tracks.count
            Text("""
                \(n == 1 ? "The file is" : "The \(n) files are") moved to the Trash. \
                \(n == 1 ? "The song is" : "The songs are") removed from all playlists, \
                with \(n == 1 ? "its" : "their") plays and likes.\(Self.keptCopies(model.copiesLosingMusic(Set(request.tracks.map(\.id)))))
                """)
        }
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

/// The special Liked Songs playlist: every liked song, most recently liked first. It can't be renamed or deleted.
struct LikedSongsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracks = model.likedTracks
        let name = AppModel.likedSongsName
        TrackTable(tracks: tracks, emptyState: ("No Liked Songs", "Click the heart next to a song to add it here."), source: name)
            .navigationTitle(name)
            .navigationSubtitle("\(songCount(tracks.count)) · \(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))")
            .toolbar {
                ToolbarItemGroup {
                    Button("Play", systemImage: "play.fill") { model.player.play(queue: tracks, startAt: 0, source: name) }.disabled(tracks.isEmpty)
                    Button("Shuffle", systemImage: "shuffle") { model.player.play(queue: tracks.shuffled(), startAt: 0, source: name) }.disabled(tracks.isEmpty)
                    Button("Export…", systemImage: "square.and.arrow.up") { model.export(name: name, tracks: tracks) }.disabled(tracks.isEmpty)
                        .help("Copy this playlist into a single folder with an .m3u file")
                    AddToExportListButton([.likedSongs])
                }
            }
    }
}

/// The heart that adds a song to Liked Songs. Takes the model instead of reading it from the environment, so it
/// works inside `Table` cells.
struct LikeButton: View {
    let model: AppModel
    let track: Track
    var font: Font = .body
    /// False hides the empty heart (rows show it on hover); a liked song always shows its heart.
    var showsUnliked = true

    var body: some View {
        let liked = model.isLiked(track)
        Button { model.toggleLike(track) } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(font)
                .foregroundStyle(liked ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: liked)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(liked || showsUnliked ? 1 : 0)
        .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
        .accessibilityLabel(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

/// Like or unlike songs from a context menu: unlikes only when every one is already liked.
struct LikeMenuButton: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let allLiked = !tracks.isEmpty && tracks.allSatisfy(model.isLiked)
        Button(allLiked ? "Remove from Liked Songs" : "Add to Liked Songs", systemImage: allLiked ? "heart.slash" : "heart") {
            model.setLiked(tracks, !allLiked)
        }
    }
}
