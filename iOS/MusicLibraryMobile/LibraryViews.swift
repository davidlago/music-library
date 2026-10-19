import MusicLibraryCore
import SwiftUI

enum LibraryRoute: Hashable {
    case artists, albums, songs, liked
    case playlist(Int64)
    case smartPlaylist(Int64)
}

/// The Library tab lists the whole library or only what's on this iPhone.
enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "All Music", onPhone = "On This iPhone"
    var id: Self { self }
}

struct LibraryTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        LibraryStack(opener: PendingAlbumOpener()) {
            Group {
                // A collection without songs yet is a library too (its albums show up as they're ripped).
                if let library = model.library, !library.isEmpty {
                    LibraryHome(library: library)
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Library")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

/// Says the sample library is showing, and how to get your own.
private struct SampleLibraryNote: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample Library").font(.headline)
                    Text("Fictional artists and albums, made up so you can try the app. Pair with Music Library on your Mac in the Sync tab to bring your own music: it replaces the sample after the first sync. What you do here isn't sent to your Mac or Last.fm.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            }
            Button("Hide Sample Library", systemImage: "eye.slash") { model.hideSample() }
        }
    }
}

/// Shows the album a widget opened (`PhoneModel.pendingAlbumKey`) once the library is loaded, or the collection item
/// for it when the album has no songs in the library, over whatever page the tab had pushed.
private struct PendingAlbumOpener: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Environment(\.showRoute) private var showRoute

    private struct Pending: Equatable {
        var key: String?
        var libraryVersion: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Pending(key: model.pendingAlbumKey, libraryVersion: model.libraryVersion)) {
            guard let key = model.pendingAlbumKey else { return }
            if case .loading = model.state { return }
            model.pendingAlbumKey = nil
            if let album = model.library?.album(forKey: key) {
                showRoute(album)
            } else if let item = model.collection.copies(albumKey: key).first {
                showRoute(CollectionItemRoute(id: item.id))
            }
        }
    }
}

private struct LibraryHome: View {
    @Environment(PhoneModel.self) private var model
    @AppStorage("libraryScope") private var scope = LibraryScope.all
    let library: LibrarySnapshot

    var body: some View {
        let counts = counts()
        List {
            if model.isSample {
                SampleLibraryNote()
            }
            Section {
                Picker("Show", selection: $scope) { ForEach(LibraryScope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                NavigationLink(value: LibraryRoute.artists) { row("Artists", systemImage: "music.mic", count: counts.artists) }
                NavigationLink(value: LibraryRoute.albums) { row("Albums", systemImage: "square.stack", count: counts.albums) }
                NavigationLink(value: LibraryRoute.songs) { row("Songs", systemImage: "music.note", count: counts.songs) }
                if !model.likedDates.isEmpty {
                    NavigationLink(value: LibraryRoute.liked) { row("Liked Songs", systemImage: "heart", count: counts.liked, tint: .pink) }
                }
                NavigationLink(value: DNARoute(name: nil)) { Label("Music DNA", systemImage: "point.3.connected.trianglepath.dotted") }
            }
            let playlists = library.playlists.filter { scope == .all || model.availability($0.tracks) != .notOnPhone }
            if !playlists.isEmpty || !library.smartPlaylists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { item in
                        NavigationLink(value: LibraryRoute.playlist(item.id)) {
                            HStack {
                                Label(item.playlist.name, systemImage: "music.note.list")
                                Spacer()
                                AvailabilityMark(availability: model.availability(item.tracks), pending: model.isDownloadPending(item.tracks))
                            }
                        }
                    }
                    ForEach(library.smartPlaylists) { p in
                        NavigationLink(value: LibraryRoute.smartPlaylist(p.id)) {
                            Label(p.name, systemImage: "gearshape")
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text(footer)
            }
        }
        .refreshable { model.reload() }
    }

    private func row(_ title: String, systemImage: String, count: Int, tint: Color = .accentColor) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            CountPill(count: count, tint: tint)
        }
    }

    private struct Counts {
        var artists: Int, albums: Int, songs: Int, liked: Int
    }

    /// What each page lists in the current scope (`LibraryRoutePage.scoped`).
    private func counts() -> Counts {
        guard scope == .onPhone else {
            return Counts(artists: library.artists.count, albums: library.albums.count,
                          songs: library.tracks.count, liked: model.likedDates.count)
        }
        let albums = library.albums.filter { library.tracks(album: $0).contains(where: library.isPresent) }
        let artists = Set(albums.map { $0.artist.lowercased() })
        return Counts(artists: library.artists.count { artists.contains($0.name.lowercased()) }, albums: albums.count,
                      songs: library.presentIDs.count, liked: model.likedDates.keys.count { library.presentIDs.contains($0) })
    }

    private var footer: String {
        let present = library.presentIDs.count
        var s = "\(present.formatted()) of \(songCount(library.tracks.count)) on this iPhone"
        if !model.requests.isEmpty {
            let n = model.pendingDownloads.count
            if n > 0 { s += " · \(n.formatted()) waiting to download" }
        }
        return s
    }
}

extension View {
    /// Where library links go; every tab's stack uses the same pages.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { LibraryRoutePage(route: $0) }
            .navigationDestination(for: AlbumSummary.self) { AlbumPage(album: $0) }
            .navigationDestination(for: ArtistSummary.self) { ArtistPage(artist: $0) }
            .navigationDestination(for: ArtistNameRoute.self) { ArtistPage(name: $0.name) }
            .navigationDestination(for: DNARoute.self) { MusicDNAPage(name: $0.name) }
            .navigationDestination(for: QueryRoute.self) { QueryPage(route: $0) }
            .navigationDestination(for: CollectionRoute.self) { CollectionRoutePage(route: $0) }
            .navigationDestination(for: CollectionItemRoute.self) { CollectionItemPage(id: $0.id) }
    }
}

private struct LibraryRoutePage: View {
    @Environment(PhoneModel.self) private var model
    @AppStorage("libraryScope") private var scope = LibraryScope.all
    let route: LibraryRoute

    var body: some View {
        if let library = model.library {
            switch route {
            case .artists:
                ArtistList(artists: scoped(library.artists) { library.tracks(artist: $0.name) })
                    .navigationTitle("Artists")
            case .albums:
                AlbumGrid(albums: scoped(library.albums) { library.tracks(album: $0) }, library: library)
                    .navigationTitle("Albums")
            case .songs:
                TrackListPage(title: "Songs", tracks: scope == .onPhone ? library.presentTracks : library.tracks, sortable: true)
            case .liked:
                TrackListPage(title: "Liked Songs", tracks: scopedTracks(model.likedTracks), item: .likedSongs)
            case .playlist(let id):
                if let item = library.playlists.first(where: { $0.id == id }) {
                    TrackListPage(title: item.playlist.name, tracks: item.tracks, item: .playlist(id))
                }
            case .smartPlaylist(let id):
                if let p = library.smartPlaylists.first(where: { $0.id == id }) {
                    TrackListPage(title: p.name, tracks: scopedTracks(library.tracks(smartPlaylist: p)), item: .smartPlaylist(id))
                }
            }
        } else {
            LibraryStatusView()
        }
    }

    private func scoped<T>(_ items: [T], tracks: (T) -> [Track]) -> [T] {
        scope == .all ? items : items.filter { model.availability(tracks($0)) != .notOnPhone }
    }

    private func scopedTracks(_ tracks: [Track]) -> [Track] { scope == .all ? tracks : model.playable(tracks) }
}

struct ArtistList: View {
    @Environment(PhoneModel.self) private var model
    let artists: [ArtistSummary]
    @State private var filter = ""

    var body: some View {
        let shown = filter.isEmpty ? artists : artists.filter { $0.name.localizedStandardContains(filter) }
        List(shown) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    ArtistPhoto(name: artist.name, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artist.name.isEmpty ? "Unknown Artist" : artist.name).lineLimit(1)
                        Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(songCount(artist.trackCount))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let library = model.library {
                        let tracks = library.tracks(artist: artist.name)
                        AvailabilityMark(availability: model.availability(tracks), pending: model.isDownloadPending(tracks))
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter artists")
        .overlay { if shown.isEmpty { ContentUnavailableView.search(text: filter) } }
    }
}

/// Which library albums the Albums grid shows, by whether you own a copy (as the Mac's).
enum AlbumCollectionFilter: String, CaseIterable, Identifiable {
    case all, inCollection, notInCollection
    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All Albums"
        case .inCollection: "In Your Collection"
        case .notInCollection: "Not in Your Collection"
        }
    }

    var icon: String {
        switch self {
        case .all: "square.stack"
        case .inCollection: "books.vertical"
        case .notInCollection: "arrow.left.arrow.right"
        }
    }
}

struct AlbumGrid: View {
    @Environment(PhoneModel.self) private var model
    let albums: [AlbumSummary]
    let library: LibrarySnapshot
    @AppStorage("albumsCollectionFilter") private var filter = AlbumCollectionFilter.all
    /// Before the collection: only albums you own. Read once as In Your Collection.
    @AppStorage("albumsOwnedOnly") private var ownedOnly = false
    /// The Mac's orders (`AlbumSort`).
    @AppStorage("albumSort") private var sort = AlbumSort.artist

    var body: some View {
        let filtered = albums.filter { album in
            switch filter {
            case .all: true
            case .inCollection: model.copyMark(for: album) != .notInCollection
            case .notInCollection: model.copyMark(for: album) == .notInCollection
            }
        }
        let shown = sort.sorted(filtered, added: library.albumAddedDates, plays: model.albumPlayTotals)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(shown) { album in
                    NavigationLink(value: album) { AlbumCell(album: album, library: library, detail: detail(album), jewelCase: true) }
                        .buttonStyle(.plain)
                        .contextMenu { AlbumMenu(album: album) }
                        .environment(\.explainsMarksOnPress, false)
                }
            }
            .padding()
        }
        .overlay {
            if filter != .all, shown.isEmpty, !albums.isEmpty {
                if filter == .inCollection {
                    ContentUnavailableView("Nothing in Your Collection", systemImage: "books.vertical",
                                           description: Text("Albums you add to your collection in Music Library on your Mac show up here."))
                } else {
                    ContentUnavailableView("You Own Them All", systemImage: "books.vertical",
                                           description: Text("Every album in your library is in your collection."))
                }
            }
        }
        .onAppear {
            if ownedOnly {
                filter = .inCollection
                ownedOnly = false
            }
        }
        .toolbar {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                }
                Section {
                    Picker("Collection", selection: $filter) {
                        ForEach(AlbumCollectionFilter.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                }
            } label: {
                Image(systemName: filter != .all ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Sort and Filter")
        }
    }

    /// A third line matching the sort, so the order makes sense at a glance (as on the Mac).
    private func detail(_ a: AlbumSummary) -> String? {
        let key = SearchIndex.albumKey(album: a.album, artist: a.artist)
        switch sort {
        case .added:
            return library.albumAddedDates[key].map { "Added " + $0.formatted(.relative(presentation: .named)) }
        case .year:
            return a.year.map(String.init)
        case .mostPlayed:
            let p = model.albumPlayTotals[key] ?? PlayTotal()
            if p.plays > 0 { return "\(p.plays) play\(p.plays == 1 ? "" : "s") · \(formatListened(p.listened))" }
            return p.listened >= 1 ? formatListened(p.listened) + " listened" : nil
        case .recent:
            return model.albumPlayTotals[key]?.lastPlayed.map { "Played " + $0.formatted(.relative(presentation: .named)) }
        case .title, .artist:
            return nil
        }
    }
}

/// A cover (in the album grid, as you own it: a CD in its jewel case, a record in its sleeve) with the title and artist;
/// dimmed when none of its songs are on the phone.
struct AlbumCell: View {
    @Environment(PhoneModel.self) private var model
    let album: AlbumSummary
    let library: LibrarySnapshot
    var size: CGFloat = 160
    var subtitle: String?
    /// A third line, like when it was added.
    var detail: String?
    var jewelCase = false

    var body: some View {
        let tracks = library.tracks(album: album)
        let availability = model.availability(tracks)
        VStack(alignment: .leading, spacing: 4) {
            Group {
                let mark = model.copyMark(for: album)
                if jewelCase {
                    CopyArt(mark: mark, url: library.coverURL(album: album), width: size, title: album.album)
                        .padding(.bottom, 4)
                } else {
                    CoverImage(url: library.coverURL(album: album), size: size, mark: mark)
                }
            }
            .opacity(availability == .notOnPhone ? 0.55 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(album.album.isEmpty ? "Unknown Album" : album.album).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
                AvailabilityMark(availability: availability, pending: model.isDownloadPending(tracks))
            }
            Text(subtitle ?? album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

/// Play, queue and download/remove for an album's long-press menu.
struct AlbumMenu: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let album: AlbumSummary

    var body: some View {
        let tracks = model.playable(model.library?.tracks(album: album) ?? [])
        let item = ExportItem.album(album: album.album, artist: album.artist)
        // What the cover's marks mean: pressing and holding them opens this menu.
        let meanings = model.copyMark(for: album).meanings
        if !meanings.isEmpty {
            Section { ForEach(meanings, id: \.self) { Text($0) } }
        }
        if !tracks.isEmpty {
            Button("Play", systemImage: "play") { player.play(queue: tracks, source: album.album) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(tracks) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(tracks) }
        }
        let availability = model.availability(item)
        if availability != .onPhone, !model.isDownloadPending(model.library?.tracks(album: album) ?? []) {
            Button("Download to iPhone", systemImage: "arrow.down.circle") { model.download(item) }.disabled(!model.sync.isPaired)
        }
        if availability != .notOnPhone, !model.isSample {
            Button("Remove from iPhone", systemImage: "trash", role: .destructive) { model.remove(item) }
        }
    }
}

/// Songs with Play and Shuffle at the top (and, for lists, what's on the phone). A `sortable` list (Songs) has the
/// Mac's song table orders in its toolbar.
struct TrackListPage: View {
    let title: String
    let tracks: [Track]
    var item: ExportItem?
    var sortable = false
    @AppStorage("songSort") private var sort = SongSort.artist
    @AppStorage("songSortAscending") private var ascending = true

    var body: some View {
        let shown = sortable ? sort.sorted(tracks, ascending: ascending) : tracks
        List {
            if let item, !tracks.isEmpty {
                AvailabilityBar(item: item, tracks: tracks, noun: "list")
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            PlayButtons(tracks: shown, source: title)
            TrackRows(tracks: shown, source: title)
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .toolbar {
            if sortable {
                Menu {
                    Picker("Sort By", selection: Binding(get: { sort }, set: { sort = $0; ascending = $0.defaultAscending })) {
                        ForEach(SongSort.allCases) { Text($0.label).tag($0) }
                    }
                    Section {
                        Picker("Order", selection: $ascending) {
                            Text(sort.directionLabels.ascending).tag(true)
                            Text(sort.directionLabels.descending).tag(false)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
        }
    }
}

struct PlayButtons: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    let tracks: [Track]
    let source: String

    var body: some View {
        let playable = model.playable(tracks)
        HStack(spacing: 12) {
            Button { player.play(queue: playable, source: source) } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { player.play(queue: playable.shuffled(), source: source) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(playable.isEmpty)
        .listRowSeparator(.hidden)
    }
}

/// Rows that play the list's songs on the phone from the tapped one. A song that isn't here offers to download it.
struct TrackRows: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    let tracks: [Track]
    let source: String
    var numbered = false
    @State private var missing: Track?

    var body: some View {
        ForEach(tracks) { track in
            let present = model.isPresent(track)
            Button {
                if present {
                    let playable = model.playable(tracks)
                    player.play(queue: playable, startAt: playable.firstIndex(of: track) ?? 0, source: source)
                } else {
                    missing = track
                }
            } label: {
                TrackRow(track: track, numbered: numbered, library: model.library,
                         isCurrent: player.currentTrack?.id == track.id, isLiked: model.isLiked(track),
                         isPresent: present, isPending: model.pendingDownloads.contains(track.id))
            }
            .buttonStyle(.plain)
            .contextMenu { SongMenu(track: track) }
        }
        .confirmationDialog("“\(missing?.title ?? "")” isn't on this iPhone", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } }),
                            titleVisibility: .visible, presenting: missing) { track in
            if model.sync.isPaired {
                Button("Download Song") { model.download(.track(track.id)) }
                if let album = model.library?.album(of: track) {
                    Button("Download Album") { model.download(.album(album: album.album, artist: album.artist)) }
                }
            }
        } message: { _ in
            Text(model.sync.isPaired ? "Download it from your Mac to play it here." : "Pair with your Mac in the Sync tab to download music.")
        }
    }
}

/// A song's long-press menu.
struct SongMenu: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    let track: Track

    var body: some View {
        if model.isPresent(track) {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([track]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue([track]) }
        }
        LikeMenuButton(track: track)
        if let album = model.library?.album(of: track) {
            Button("Go to Album", systemImage: "square.stack") { openRoute(album) }
        }
        if let artist = model.library?.artist(named: track.effectiveAlbumArtist) {
            Button("Go to Artist", systemImage: "music.mic") { openRoute(artist) }
        }
        Button("Song Info", systemImage: "info.circle") { model.infoTrack = track }
        SongAvailabilityButtons(track: track)
    }
}

struct TrackRow: View {
    let track: Track
    var numbered = false
    let library: LibrarySnapshot?
    var isCurrent = false
    var isLiked = false
    var isPresent = true
    var isPending = false

    var body: some View {
        HStack(spacing: 12) {
            if numbered {
                Text(track.trackNo.map(String.init) ?? "–")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            } else {
                CoverImage(url: library.flatMap { track.coverURL(root: $0.root) }, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? "Untitled" : track.title)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                let subtitle = numbered ? (track.artist == track.effectiveAlbumArtist ? "" : track.artist)
                    : [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isLiked {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink).accessibilityLabel("Liked")
            }
            if !isPresent {
                AvailabilityMark(availability: .notOnPhone, pending: isPending)
            }
            Text(Format.time(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .opacity(isPresent ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

/// Like or Unlike for a song's menu; the change shows at once and goes to the Mac at the next sync.
struct LikeMenuButton: View {
    @Environment(PhoneModel.self) private var model
    let track: Track

    var body: some View {
        let liked = model.isLiked(track)
        Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") { model.toggleLike(track) }
    }
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
