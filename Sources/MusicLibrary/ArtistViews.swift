import AppKit
import MusicLibraryCore
import SwiftUI

// MARK: Photo

/// An artist's photo from the info cache, or their initials until one is downloaded.
struct ArtistPhoto: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let name: String
    var size: CGFloat = 140
    @State private var image: NSImage?

    var body: some View {
        let file = model.artistInfo.imageFile(for: name)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                InitialsBadge(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
        .task(id: file) { image = await model.artistInfo.image(for: name) }
    }
}

// MARK: Grid

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var filter = ""
    @State private var photoArtist: ArtistSummary?
    @AppStorage("artistSort") private var sort = ArtistSort.name

    enum ArtistSort: String, CaseIterable, Identifiable {
        case name = "Name", songs = "Songs", albums = "Albums", listened = "Time Listened", recent = "Recently Played"
        var id: String { rawValue }
    }

    var body: some View {
        let shown = sorted(filtered(model.artists))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(shownCount: shown.count)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(shown) { a in
                        NavigationLink(value: a) { ArtistCard(artist: a) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ArtistMenuButtons(artist: a)
                                Divider()
                                Button("Show Music DNA") { model.showMusicDNA(a.name) }
                                    .disabled(model.collaborations.person(named: a.name) == nil)
                                Button("Update Artist Info") { model.refreshArtistInfo([a.name]) }
                                Button("Change Photo…") { photoArtist = a }.disabled(a.name.isEmpty)
                                AddToExportListButton([.artist(a.name)])
                            }
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            if model.artists.isEmpty {
                ContentUnavailableView("No Artists", systemImage: "music.mic")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .sheet(item: $photoArtist) { ArtistPhotoSheet(name: $0.name, request: CoverSheetRequest()).themedSheet() }
        .navigationTitle("Artists")
        .navigationSubtitle(filter.isEmpty ? "\(model.artists.count) artists" : "\(shown.count) of \(model.artists.count) artists")
    }

    private func header(shownCount: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.subtext)
                TextField("Filter artists, genres, countries", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.subtext)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
            .frame(maxWidth: 320)
            Picker("Sort by", selection: $sort) {
                ForEach(ArtistSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Spacer()
            SyncStatus()
        }
    }

    private func filtered(_ artists: [ArtistSummary]) -> [ArtistSummary] {
        let q = TextNormalizer.normalize(filter)
        guard !q.isEmpty else { return artists }
        return artists.filter { a in
            var parts: [String] = [a.name]
            if let info = model.artistInfo.info(for: a.name) {
                parts += info.genres
                parts.append(info.summary())
                parts.append(info.disambiguation ?? "")
            }
            return TextNormalizer.normalize(parts.joined(separator: " ")).contains(q)
        }
    }

    private func sorted(_ artists: [ArtistSummary]) -> [ArtistSummary] {
        func plays(_ a: ArtistSummary) -> PlayTotal { model.artistPlayTotals[ArtistInfoStore.key(a.name)] ?? PlayTotal() }
        switch sort {
        case .name: return artists
        case .songs: return artists.sorted { $0.trackCount > $1.trackCount }
        case .albums: return artists.sorted { $0.albumCount != $1.albumCount ? $0.albumCount > $1.albumCount : $0.trackCount > $1.trackCount }
        case .listened: return artists.sorted { plays($0).listened > plays($1).listened }
        case .recent: return artists.sorted { (plays($0).lastPlayed ?? .distantPast) > (plays($1).lastPlayed ?? .distantPast) }
        }
    }
}

struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistSummary
    @State private var hovering = false

    var body: some View {
        let listened = model.artistPlayTotals[ArtistInfoStore.key(artist.name)]?.listened ?? 0
        VStack(spacing: 6) {
            ArtistPhoto(name: artist.name, size: 136)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 5, y: 3)
                .scaleEffect(hovering ? 1.03 : 1)
                .padding(.bottom, 4)
            Text(artist.name.isEmpty ? "Unknown Artist" : artist.name)
                .font(.headline).lineLimit(1)
            Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(songCount(artist.trackCount))")
                .font(.caption).foregroundStyle(.subtext).lineLimit(1)
            if listened >= 1 {
                Label(formatListened(listened), systemImage: "headphones")
                    .font(.caption2).foregroundStyle(.subtext).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// "Updating artist info…" while the background sync runs.
struct SyncStatus: View {
    @Environment(AppModel.self) private var model
    var showsUpdateButton = true

    var body: some View {
        let store = model.artistInfo
        if store.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating artist info · \(store.remaining) left").font(.caption).foregroundStyle(.subtext)
                Button("Stop") { store.cancel() }.controlSize(.small)
            }
        } else if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                .help(error)
        } else if showsUpdateButton {
            Button("Update All Artist Info") { model.refreshArtistInfo(model.artists.map(\.name)) }
                .controlSize(.small)
                .help("Download photos, bios and links from MusicBrainz, Wikipedia and Wikimedia Commons")
        }
    }
}

// MARK: Detail

/// An artist's page by name: for an artist you only have items by (no songs, so no `ArtistSummary`).
struct ArtistRoute: Hashable {
    var name: String
}

/// An artist's page: their songs and albums in the library, and the items in your collection by them (records
/// never digitized included). The page stays open while either is left.
struct ArtistDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let artistName: String
    @State private var tracks: [Track] = []
    @State private var albums: [AlbumSummary] = []
    @State private var items: [CollectionItem] = []
    @State private var bioExpanded = false
    @State private var showAllSongs = false
    @State private var photoSheet: CoverSheetRequest?
    @State private var hoveringPhoto = false
    @State private var photoDropTargeted = false

    init(artist: ArtistSummary) { artistName = artist.name }
    init(name: String) { artistName = name }

    private var name: String { artistName.isEmpty ? "Unknown Artist" : artistName }

    var body: some View {
        let info = model.artistInfo.info(for: artistName)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero(info)
                statTiles(info)
                if let bio = info?.bio { about(bio, info!) }
                if let links = info?.links.filter(\.url.isWebLink), !links.isEmpty { linksSection(links) }
                ArtistConcertsSection(artist: artistName, mbid: info?.mbid)
                if !items.isEmpty { collectionSection }
                if !albums.isEmpty { albumsSection }
                if !tracks.isEmpty { songsSection }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .toolbar {
            ToolbarItem { AddToExportListButton([.artist(artistName)]) }
            ToolbarItem {
                Button { photoSheet = CoverSheetRequest() } label: { Label("Change Photo…", systemImage: "person.crop.circle") }
                    .disabled(artistName.isEmpty)
                    .help("Search for or upload a photo of \(name)")
            }
            ToolbarItem {
                Button { model.refreshArtistInfo([artistName]) } label: {
                    Label("Update Artist Info", systemImage: "arrow.clockwise")
                }
                .disabled(model.artistInfo.isFetching(artistName))
                .help("Download the latest photo, bio and links")
            }
        }
        .sheet(item: $photoSheet) { ArtistPhotoSheet(name: artistName, request: $0).themedSheet() }
        .onAppear(perform: load)
        .onChange(of: model.libraryVersion) {
            load()
            // All of the artist's songs were removed from the library, and nothing by them is in the collection.
            if tracks.isEmpty, items.isEmpty { dismiss() }
        }
        .onChange(of: model.collectionVersion) {
            items = model.collection.items(artist: artistName)
            if tracks.isEmpty, items.isEmpty { dismiss() }
        }
    }

    private func load() {
        tracks = model.tracks(ofArtist: artistName)
        albums = model.albums(forArtist: artistName)
        items = model.collection.items(artist: artistName)
    }

    /// In Your Collection: every item by the artist, with or without songs in the library.
    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "In Your Collection")
                Spacer()
                Button("Show on Shelf") { model.showShelf(query: SearchFilterKey.token("artist", artistName)) }
                    .buttonStyle(.link)
                    .help("Open the Shelf with only \(name)'s items")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionCell(item: item, width: 140) }
                            .buttonStyle(.plain)
                            .contextMenu { CollectionItemMenu(model: model, item: item) }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Sections

    private func hero(_ info: ArtistInfo?) -> some View {
        HStack(alignment: .center, spacing: 28) {
            photo(size: 190)
            VStack(alignment: .leading, spacing: 8) {
                Text("ARTIST").font(.caption.weight(.semibold)).foregroundStyle(.subtext).tracking(1.2)
                Text(name).font(.system(size: 36, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                if let info {
                    let summary = info.summary()
                    if !summary.isEmpty || info.disambiguation != nil {
                        Text([summary, info.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.title3).foregroundStyle(.subtext)
                    }
                    if !info.genres.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(info.genres, id: \.self) { g in
                                Button { model.search(SearchFilterKey.token("genre", g)) } label: {
                                    Text(g.capitalized).font(.caption)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(Capsule().fill(theme.fill))
                                }
                                .buttonStyle(.plain)
                                .help("Search your library for \(g)")
                            }
                        }
                    }
                } else if model.artistInfo.isFetching(artistName) {
                    Label("Looking up artist info…", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.subtext)
                }
                HStack(spacing: 10) {
                    Button { play(tracks, at: 0) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                        .buttonStyle(.borderedProminent)
                    Button { play(tracks.shuffled(), at: 0) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.bordered)
                    if model.collaborations.person(named: artistName) != nil {
                        Button { model.showMusicDNA(artistName) } label: {
                            Label("Music DNA", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .buttonStyle(.bordered)
                        .help("See who \(name) worked with")
                    }
                    Menu {
                        QueueMenuButtons(player: model.player) { tracks }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
                        .help("Play Next or Add to Queue")
                }
                .controlSize(.large)
                .disabled(tracks.isEmpty)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .background {
            ZStack {
                theme.card
                ArtistBackdrop(name: artistName)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }

    /// The photo, with "Change Photo…" on hover; dropping an image on it opens the photo sheet with that image.
    private func photo(size: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ArtistPhoto(name: artistName, size: size)
            if hoveringPhoto, !artistName.isEmpty {
                Button { photoSheet = CoverSheetRequest() } label: { Label("Change Photo…", systemImage: "photo") }
                    .controlSize(.small)
                    .padding(.bottom, 14)
            }
        }
        .overlay { if photoDropTargeted { Circle().strokeBorder(theme.accent, lineWidth: 3) } }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onHover { hoveringPhoto = $0 }
        .contextMenu {
            Button("Change Photo…") { photoSheet = CoverSheetRequest() }.disabled(artistName.isEmpty)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL, !artistName.isEmpty else { return false }
            let data = try? Data(contentsOf: url)
            guard let data, NSImage(data: data) != nil else { return false }
            photoSheet = CoverSheetRequest(image: data, source: url.lastPathComponent)
            return true
        } isTargeted: { photoDropTargeted = $0 }
    }

    private func statTiles(_ info: ArtistInfo?) -> some View {
        let p = model.artistPlayTotals[ArtistInfoStore.key(artistName)] ?? PlayTotal()
        let total = tracks.reduce(0) { $0 + $1.duration }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            StatTile(value: tracks.count.formatted(), label: tracks.count == 1 ? "Song" : "Songs", icon: "music.note")
            StatTile(value: albums.count.formatted(), label: albums.count == 1 ? "Album" : "Albums", icon: "square.stack")
            if !items.isEmpty {
                StatTile(value: items.count.formatted(), label: "In your collection", icon: "books.vertical")
            }
            StatTile(value: formatLongDuration(total), label: "In your library", icon: "clock")
            StatTile(value: formatListened(p.listened), label: "Time listened", icon: "headphones")
            StatTile(value: p.plays.formatted(), label: p.plays == 1 ? "Play" : "Plays", icon: "play.circle")
            StatTile(value: p.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                     label: "Last played", icon: "calendar")
            if let scrobbles = info?.lastfmUserPlaycount, scrobbles > 0 {
                StatTile(value: scrobbles.formatted(), label: "Last.fm scrobbles", icon: "dot.radiowaves.left.and.right")
            }
        }
    }

    private func about(_ bio: String, _ info: ArtistInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")
            Text(bio)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(bioExpanded ? nil : 5)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
            HStack(spacing: 14) {
                if bio.count > 400 {
                    Button(bioExpanded ? "Show Less" : "Read More") { withAnimation(.snappy) { bioExpanded.toggle() } }
                        .buttonStyle(.link)
                }
                if let source = info.bioSource {
                    if let url = info.bioURL?.webLink {
                        Link("From \(source)", destination: url).font(.caption)
                    } else {
                        Text("From \(source)").font(.caption).foregroundStyle(.subtext)
                    }
                }
                if let credit = model.artistInfo.photoCredit(for: artistName) {
                    if let url = credit.url?.webLink {
                        Link("Photo: \(credit.label)", destination: url).font(.caption)
                    } else {
                        Text("Photo: \(credit.label)").font(.caption).foregroundStyle(.subtext)
                    }
                }
            }
        }
    }

    private func linksSection(_ links: [ArtistLink]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Links")
            FlowLayout(spacing: 8) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: Self.icon(link.kind))
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

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Albums in Your Library")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(albums) { a in
                    NavigationLink(value: a) {
                        VStack(alignment: .leading, spacing: 4) {
                            CoverThumb(url: model.coverURL(forAlbum: a), size: 140, revision: model.coverRevision,
                                       mark: model.copyMark(for: a))
                            Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.callout.weight(.medium)).lineLimit(1)
                            Text([a.year.map(String.init), songCount(a.trackCount)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.subtext)
                        }
                        .frame(width: 140, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AddToExportListButton(album: a)
                        Divider()
                        RemoveFromLibraryButton(album: a)
                    }
                }
            }
        }
    }

    private var songsSection: some View {
        let ranked = rankedTracks
        let anyPlays = ranked.contains { (model.playTotals[$0.id]?.plays ?? 0) > 0 }
        let shown = showAllSongs ? ranked : Array(ranked.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: anyPlays ? "Most Played" : "Songs")
                Spacer()
                if ranked.count > 8 {
                    Button(showAllSongs ? "Show Fewer" : "Show All \(ranked.count) Songs") { withAnimation(.snappy) { showAllSongs.toggle() } }
                        .buttonStyle(.link)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    ArtistSongRow(index: i + 1, track: t, total: model.playTotals[t.id]) { play(ranked, at: i) }
                    if i < shown.count - 1 { Divider().opacity(0.5) }
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    /// Most played first, then album order.
    private var rankedTracks: [Track] {
        tracks.enumerated().sorted { a, b in
            let pa = model.playTotals[a.element.id]?.plays ?? 0, pb = model.playTotals[b.element.id]?.plays ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
    }

    private func play(_ list: [Track], at index: Int) {
        guard list.indices.contains(index) else { return }
        model.player.play(queue: list, startAt: index, source: name)
    }

    static func icon(_ kind: ArtistLink.Kind) -> String {
        switch kind {
        case .official: "globe"
        case .wikipedia, .wikidata: "book"
        case .review: "quote.bubble"
        case .rateyourmusic: "star"
        case .genius: "text.quote"
        case .lastfm: "dot.radiowaves.left.and.right"
        case .bandcamp, .spotify, .appleMusic, .tidal, .deezer, .soundcloud: "music.note"
        case .youtube: "play.rectangle"
        case .instagram, .tiktok: "camera"
        case .twitter, .facebook, .bluesky: "bubble.left"
        case .discogs, .allmusic, .musicbrainz: "opticaldisc"
        case .setlistfm, .songkick, .bandsintown: "ticket"
        case .imdb: "film"
        }
    }
}

/// The artist's photo, blurred, behind the header.
private struct ArtistBackdrop: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let name: String
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 50).opacity(0.35)
                    .clipped()
                    // Keeps the header text readable however busy the photo is.
                    .overlay(LinearGradient(colors: [theme.card.opacity(0.8), theme.card.opacity(0.45)],
                                            startPoint: .leading, endPoint: .trailing))
            }
        }
        .task(id: model.artistInfo.imageFile(for: name)) { image = await model.artistInfo.image(for: name) }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.title2.bold()) }
}

struct StatTile: View {
    @Environment(\.theme) private var theme
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.callout).foregroundStyle(.subtext)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.subtext)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

struct ArtistSongRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let index: Int
    let track: Track
    let total: PlayTotal?
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        let isCurrent = model.player.currentTrack?.id == track.id
        HStack(spacing: 12) {
            ZStack {
                if hovering {
                    Image(systemName: "play.fill").font(.caption)
                } else if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(theme.accent)
                } else {
                    Text("\(index)").monospacedDigit().foregroundStyle(.subtext)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
                Text([track.album, track.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
            Spacer()
            LikeButton(model: model, track: track, showsUnliked: hovering)
            if let plays = total?.plays, plays > 0 {
                Text("\(plays) play\(plays == 1 ? "" : "s")").font(.caption).foregroundStyle(.subtext).monospacedDigit()
            }
            Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.subtext).frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovering ? theme.fill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            QueueMenuButtons(player: model.player) { [track] }
            LikeMenuButton(tracks: [track])
            Menu("Add to Playlist") {
                ForEach(model.playlists) { p in Button(p.name) { model.add([track.id], toPlaylist: p.id) } }
                if !model.playlists.isEmpty { Divider() }
                Button("New Playlist…") { model.createPlaylist(adding: [track.id]) }
            }
            AddToExportListButton(tracks: [track])
            Divider()
            Button("Show in Finder") { model.showInFinder([track]) }
            RemoveFromLibraryButton(tracks: [track])
        }
        .help("Double-click to play")
    }
}
