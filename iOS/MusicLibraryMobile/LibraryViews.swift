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
        LibraryStack {
            Group {
                if let library = model.library, !library.tracks.isEmpty {
                    LibraryHome(library: library)
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Library")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
            .modifier(PendingAlbumOpener())
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

/// Pushes the album a widget opened (`PhoneModel.pendingAlbumKey`) once the library is loaded.
private struct PendingAlbumOpener: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute

    private struct Pending: Equatable {
        var key: String?
        var libraryVersion: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Pending(key: model.pendingAlbumKey, libraryVersion: model.libraryVersion)) {
            guard let key = model.pendingAlbumKey else { return }
            if case .loading = model.state { return }
            model.pendingAlbumKey = nil
            if let album = model.library?.album(forKey: key) { openRoute(album) }
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
            .navigationDestination(for: DNARoute.self) { MusicDNAPage(name: $0.name) }
            .navigationDestination(for: QueryRoute.self) { QueryPage(route: $0) }
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
                TrackListPage(title: "Songs", tracks: scope == .onPhone ? library.presentTracks : library.tracks)
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

struct AlbumGrid: View {
    @Environment(PhoneModel.self) private var model
    let albums: [AlbumSummary]
    let library: LibrarySnapshot

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumCell(album: album, library: library) }
                        .buttonStyle(.plain)
                        .contextMenu { AlbumMenu(album: album) }
                }
            }
            .padding()
        }
    }
}

/// A cover with the title and artist; dimmed when none of its songs are on the phone.
struct AlbumCell: View {
    @Environment(PhoneModel.self) private var model
    let album: AlbumSummary
    let library: LibrarySnapshot
    var size: CGFloat = 160
    var subtitle: String?

    var body: some View {
        let tracks = library.tracks(album: album)
        let availability = model.availability(tracks)
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(url: library.coverURL(album: album), size: size, owned: model.purchase(for: album) != nil)
                .opacity(availability == .notOnPhone ? 0.55 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(album.album.isEmpty ? "Unknown Album" : album.album).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
                AvailabilityMark(availability: availability, pending: model.isDownloadPending(tracks))
            }
            Text(subtitle ?? album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        if !tracks.isEmpty {
            Button("Play", systemImage: "play") { player.play(queue: tracks, source: album.album) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(tracks) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(tracks) }
        }
        let availability = model.availability(item)
        if availability != .onPhone, !model.isDownloadPending(model.library?.tracks(album: album) ?? []) {
            Button("Download to iPhone", systemImage: "arrow.down.circle") { model.download(item) }.disabled(!model.sync.isPaired)
        }
        if availability != .notOnPhone {
            Button("Remove from iPhone", systemImage: "trash", role: .destructive) { model.remove(item) }
        }
    }
}

/// Songs with Play and Shuffle at the top (and, for lists, what's on the phone).
struct TrackListPage: View {
    let title: String
    let tracks: [Track]
    var item: ExportItem?

    var body: some View {
        List {
            if let item, !tracks.isEmpty {
                AvailabilityBar(item: item, tracks: tracks, noun: "list")
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            PlayButtons(tracks: tracks, source: title)
            TrackRows(tracks: tracks, source: title)
        }
        .listStyle(.plain)
        .navigationTitle(title)
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
