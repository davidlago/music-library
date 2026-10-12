import MusicLibraryCore
import SwiftUI

enum LibraryRoute: Hashable {
    case artists, albums, songs, liked
    case playlist(Int64)
    case smartPlaylist(Int64)
}

struct LibraryTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
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
            .libraryDestinations()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

private struct LibraryHome: View {
    @Environment(PhoneModel.self) private var model
    let library: LibrarySnapshot

    var body: some View {
        List {
            Section {
                NavigationLink(value: LibraryRoute.artists) { Label("Artists", systemImage: "music.mic") }
                NavigationLink(value: LibraryRoute.albums) { Label("Albums", systemImage: "square.stack") }
                NavigationLink(value: LibraryRoute.songs) { Label("Songs", systemImage: "music.note") }
                if !model.likedDates.isEmpty {
                    NavigationLink(value: LibraryRoute.liked) { Label("Liked Songs", systemImage: "heart") }
                }
            }
            if !library.playlists.isEmpty || !library.smartPlaylists.isEmpty {
                Section("Playlists") {
                    ForEach(library.playlists) { item in
                        NavigationLink(value: LibraryRoute.playlist(item.id)) {
                            Label(item.playlist.name, systemImage: "music.note.list")
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
                Text("\(library.tracks.count) of \(library.snapshotTrackCount) songs on this iPhone")
            }
        }
        .refreshable { model.reload() }
    }
}

extension View {
    /// Where library links go; every tab's stack uses the same pages.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { LibraryRoutePage(route: $0) }
            .navigationDestination(for: AlbumSummary.self) { AlbumPage(album: $0) }
            .navigationDestination(for: ArtistSummary.self) { ArtistPage(artist: $0) }
    }
}

private struct LibraryRoutePage: View {
    @Environment(PhoneModel.self) private var model
    let route: LibraryRoute

    var body: some View {
        if let library = model.library {
            switch route {
            case .artists:
                List(library.artists) { artist in
                    NavigationLink(value: artist) {
                        VStack(alignment: .leading) {
                            Text(artist.name.isEmpty ? "Unknown Artist" : artist.name)
                            Text("^[\(artist.albumCount) album](inflect: true)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Artists")
            case .albums:
                AlbumGrid(albums: library.albums, library: library).navigationTitle("Albums")
            case .songs:
                TrackListPage(title: "Songs", tracks: library.tracks)
            case .liked:
                TrackListPage(title: "Liked Songs", tracks: model.likedTracks)
            case .playlist(let id):
                if let item = library.playlists.first(where: { $0.id == id }) {
                    TrackListPage(title: item.playlist.name, tracks: item.tracks)
                }
            case .smartPlaylist(let id):
                if let p = library.smartPlaylists.first(where: { $0.id == id }) {
                    TrackListPage(title: p.name, tracks: library.tracks(smartPlaylist: p))
                }
            }
        } else {
            LibraryStatusView()
        }
    }
}

struct AlbumGrid: View {
    let albums: [AlbumSummary]
    let library: LibrarySnapshot

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 4) {
                            CoverImage(url: library.coverURL(album: album), size: 160)
                            Text(album.album.isEmpty ? "Unknown Album" : album.album).font(.subheadline).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 160, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

/// Songs with Play and Shuffle at the top.
struct TrackListPage: View {
    let title: String
    let tracks: [Track]

    var body: some View {
        List {
            PlayButtons(tracks: tracks, source: title)
            TrackRows(tracks: tracks, source: title)
        }
        .listStyle(.plain)
        .navigationTitle(title)
    }
}

struct PlayButtons: View {
    @Environment(PhonePlayer.self) private var player
    let tracks: [Track]
    let source: String

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(queue: tracks, source: source) } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button { player.play(queue: tracks.shuffled(), source: source) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(tracks.isEmpty)
        .listRowSeparator(.hidden)
    }
}

/// Rows that play the list from the tapped song.
struct TrackRows: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    let tracks: [Track]
    let source: String
    var numbered = false

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
            Button { player.play(queue: tracks, startAt: i, source: source) } label: {
                TrackRow(track: track, numbered: numbered, library: model.library,
                         isCurrent: player.currentTrack?.id == track.id, isLiked: model.isLiked(track))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext([track]) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue([track]) }
                LikeMenuButton(track: track)
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    var numbered = false
    let library: LibrarySnapshot?
    var isCurrent = false
    var isLiked = false

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
            Text(Format.time(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
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

struct AlbumPage: View {
    @Environment(PhoneModel.self) private var model
    let album: AlbumSummary

    var body: some View {
        if let library = model.library {
            let tracks = library.tracks(album: album)
            List {
                VStack(spacing: 8) {
                    CoverImage(url: library.coverURL(album: album), size: 260)
                        .shadow(radius: 8, y: 4)
                    Text(album.album.isEmpty ? "Unknown Album" : album.album)
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    if let artist = library.artists.first(where: { $0.name == album.artist }) {
                        NavigationLink(value: artist) { Text(album.artist).font(.title3) }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    Text(Format.albumDetails(album: album, tracks: tracks))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                PlayButtons(tracks: tracks, source: album.album)
                TrackRows(tracks: tracks, source: album.album, numbered: true)
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            LibraryStatusView()
        }
    }
}

struct ArtistPage: View {
    @Environment(PhoneModel.self) private var model
    let artist: ArtistSummary

    var body: some View {
        if let library = model.library {
            ScrollView {
                PlayButtons(tracks: library.tracks(artist: artist.name), source: artist.name)
                    .padding(.horizontal)
                AlbumGrid(albums: library.albums(artist: artist.name), library: library)
            }
            .navigationTitle(artist.name.isEmpty ? "Unknown Artist" : artist.name)
        } else {
            LibraryStatusView()
        }
    }
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "1997 · 12 songs, 53 min · FLAC 16/44.1"
    static func albumDetails(album: AlbumSummary, tracks: [Track]) -> String {
        let minutes = Int((tracks.reduce(0) { $0 + $1.duration } / 60).rounded())
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) \(tracks.count == 1 ? "song" : "songs"), \(minutes) min")
        let formats = Array(Set(tracks.compactMap { $0.audioFormat?.compact })).sorted()
        if !formats.isEmpty { parts.append(formats.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
