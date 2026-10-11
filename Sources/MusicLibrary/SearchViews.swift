import MusicLibraryCore
import SwiftUI

/// Completions under the toolbar search field: recent searches when empty, then filters and library values.
struct SearchSuggestions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.searchText.isEmpty {
            ForEach(model.recentSearches, id: \.self) { s in
                Label(s, systemImage: "clock.arrow.circlepath").searchCompletion(s)
            }
        } else {
            ForEach(model.searchCompletions, id: \.self) { c in
                HStack {
                    Text(c.label).lineLimit(1)
                    Spacer()
                    Text(c.detail).foregroundStyle(.subtext).lineLimit(1)
                }
                .searchCompletion(c.replacement)
            }
        }
    }
}

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.searchResults
            VStack(spacing: 0) {
                SearchHeader(results: results)
                Divider()
                if !results.artists.isEmpty || !results.albums.isEmpty {
                    TopHitsStrip(artists: results.artists, albums: results.albums)
                    Divider()
                }
                TrackTable(tracks: results.tracks, source: "Search")
            }
            .navigationTitle("Search")
            .navigationSubtitle(results.tracks.isEmpty ? "" : "\(songCount(results.tracks.count)) · \(formatLongDuration(results.totalDuration))")
    }
}

struct SearchHeader: View {
    @Environment(AppModel.self) private var model
    let results: SearchResults
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let corrected = results.correctedText {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.subtext)
                    Text("Showing results for")
                    Text(corrected).bold()
                    Text("·").foregroundStyle(.subtext)
                    Button("Search for “\(model.searchText)” instead") { model.searchExactly() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
            ForEach(results.issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Text("Refine").font(.caption).foregroundStyle(.subtext)
                RefineMenus()
                Spacer(minLength: 12)
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(results.tracks.isEmpty)
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .disabled(results.tracks.count < 2)
                Button { model.newSmartPlaylist(query: model.searchText) } label: {
                    Label("Save as Smart Playlist", systemImage: "gearshape")
                }
                .help("Keep this search in the sidebar; it updates as your library grows")
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Search syntax")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        SearchHelpView { example in model.search(example); showHelp = false }
                    }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func play(shuffled: Bool) {
        let list = shuffled ? results.tracks.shuffled() : results.tracks
        if !list.isEmpty { model.player.play(queue: list, startAt: 0, source: "Search") }
    }
}

/// Menus that add a filter to the current search. Options come from the library, so they grow with it.
struct RefineMenus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            let genres = model.index.topValues(.genre, limit: 30)
            if !genres.isEmpty {
                Menu("Genre") {
                    ForEach(genres, id: \.name) { g in
                        Button("\(g.name)  (\(g.count))") { model.refineSearch(with: SearchFilterKey.token("genre", g.name)) }
                    }
                }
            }
            let decades = model.index.decades
            if !decades.isEmpty {
                Menu("Decade") {
                    ForEach(decades, id: \.name) { d in
                        Button("\(d.name)  (\(d.count))") { model.refineSearch(with: "decade:" + d.name) }
                    }
                }
            }
            Menu("Quality") {
                Button("Lossless") { model.refineSearch(with: "is:lossless") }
                Button("Hi-Res (above 16-bit / 48 kHz)") { model.refineSearch(with: "is:hires") }
                Button("Lossy") { model.refineSearch(with: "is:lossy") }
            }
            Menu("Added") {
                Button("Last 7 days") { model.refineSearch(with: "added:7d") }
                Button("Last 30 days") { model.refineSearch(with: "added:30d") }
                Button("Last year") { model.refineSearch(with: "added:1y") }
                Button("Over a year ago") { model.refineSearch(with: "added:>1y") }
            }
            Menu("Missing") {
                Button("Cover art") { model.refineSearch(with: "missing:cover") }
                Button("Year") { model.refineSearch(with: "missing:year") }
                Button("Genre") { model.refineSearch(with: "missing:genre") }
                Button("MusicBrainz match") { model.refineSearch(with: "missing:mbid") }
                Button("Composer") { model.refineSearch(with: "missing:composer") }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Artists and albums the search hit directly, shown above the matching songs.
struct TopHitsStrip: View {
    @Environment(AppModel.self) private var model
    let artists: [ArtistSummary]
    let albums: [AlbumSummary]
    private let size: CGFloat = 76

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(artists.prefix(20)) { a in
                    NavigationLink(value: a) {
                        VStack(spacing: 4) {
                            ArtistPhoto(name: a.name, size: size)
                            Text(a.name.isEmpty ? "Unknown Artist" : a.name).font(.caption.weight(.medium)).lineLimit(1)
                            Text("Artist · \(a.albumCount) album\(a.albumCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.subtext).lineLimit(1)
                        }
                        .frame(width: size + 16)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistMenuButtons(artist: a)
                        Divider()
                        AddToExportListButton([.artist(a.name)])
                    }
                }
                ForEach(albums.prefix(40)) { a in
                    NavigationLink(value: a) {
                        VStack(alignment: .leading, spacing: 4) {
                            CoverThumb(url: model.coverURL(forAlbum: a), size: size, revision: model.coverRevision)
                            Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.caption.weight(.medium)).lineLimit(1)
                            Text([a.artist, a.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.subtext).lineLimit(1)
                        }
                        .frame(width: size + 16, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumMenuButtons(album: a)
                        Divider()
                        AddToExportListButton(album: a)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(height: size + 58)
    }
}

struct InitialsBadge: View {
    let name: String
    var size: CGFloat = 76

    var body: some View {
        // "Rachael & Vilray" → "RV": skip words without letters.
        let initials = name.split(separator: " ").filter { $0.contains(where: \.isLetter) }.prefix(2)
            .compactMap { $0.first(where: \.isLetter) }.map(String.init).joined()
        ZStack {
            Circle().fill(.quaternary)
            if initials.isEmpty {
                Image(systemName: "music.mic").font(.system(size: size / 3)).foregroundStyle(.subtext)
            } else {
                Text(initials.uppercased()).font(.system(size: size / 3, weight: .semibold, design: .rounded)).foregroundStyle(.subtext)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A cheat sheet for the search syntax; examples are clickable.
struct SearchHelpView: View {
    var onExample: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search syntax").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    basic("words", "All words must match, in any field")
                    basic("\"exact phrase\"", "Words in this order")
                    basic("-word  -genre:pop", "Exclude matches")
                    basic("a OR b", "Either side may match")
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    ForEach(SearchFilterKey.all, id: \.name) { k in
                        GridRow {
                            Text(k.name + ":").font(.system(.callout, design: .monospaced)).bold()
                            Text(k.help).font(.callout).foregroundStyle(.subtext)
                                .frame(maxWidth: 260, alignment: .leading)
                            Button(k.example) { onExample(k.example) }
                                .buttonStyle(.link)
                                .font(.system(.callout, design: .monospaced))
                        }
                    }
                }
                Text("Numbers accept comparisons and ranges: year:>2000, year:1990-1999, time:3:00..5:00")
                    .font(.caption).foregroundStyle(.subtext)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
    }

    private func basic(_ syntax: String, _ meaning: String) -> some View {
        GridRow {
            Text(syntax).font(.system(.callout, design: .monospaced))
            Text(meaning).font(.callout).foregroundStyle(.subtext)
        }
    }
}

// MARK: Smart playlists

struct SmartPlaylistEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SmartPlaylistDraft
    @State private var showHelp = false

    init(draft: SmartPlaylistDraft) { _draft = State(initialValue: draft) }

    var body: some View {
        let preview = model.index.search(draft.query, autocorrect: false)
        let query = draft.query.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.id == nil ? "New Smart Playlist" : "Edit Smart Playlist").font(.headline)
            Form {
                TextField("Name", text: $draft.name, prompt: Text(query.isEmpty ? "Smart Playlist" : query))
                TextField(text: $draft.query, prompt: Text("genre:jazz year:<1970 is:lossless")) { Text("Rules").font(.body) }
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                if query.isEmpty {
                    Text("Use the same syntax as the search field. The playlist updates itself as your library changes.")
                } else {
                    Text("Currently matches \(songCount(preview.tracks.count)) · \(formatLongDuration(preview.totalDuration))")
                }
                ForEach(preview.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .font(.callout).foregroundStyle(.subtext)
            DisclosureGroup("Syntax", isExpanded: $showHelp) {
                SearchHelpView { example in
                    draft.query = draft.query.trimmingCharacters(in: .whitespaces).isEmpty ? example : draft.query + " " + example
                }
                .frame(height: 260)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.smartPlaylistDraft = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var d = draft
                    if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = query }
                    model.saveSmartPlaylist(d)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}

struct SmartPlaylistView: View {
    @Environment(AppModel.self) private var model
    let playlist: SmartPlaylist
    @State private var tracks: [Track] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").foregroundStyle(.subtext)
                Text(playlist.query).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                Text("\(songCount(tracks.count)) · \(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.callout).foregroundStyle(.subtext)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            TrackTable(tracks: tracks, emptyState: ("No Matches Yet", "Songs matching these rules will appear here as you add them."), source: playlist.name)
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Play", systemImage: "play.fill") { model.player.play(queue: tracks, startAt: 0, source: playlist.name) }.disabled(tracks.isEmpty)
                Button("Shuffle", systemImage: "shuffle") { model.player.play(queue: tracks.shuffled(), startAt: 0, source: playlist.name) }.disabled(tracks.isEmpty)
                Button("Edit Rules…", systemImage: "slider.horizontal.3") { model.editSmartPlaylist(playlist) }
                Button("Export…", systemImage: "square.and.arrow.up") { model.export(name: playlist.name, tracks: tracks) }.disabled(tracks.isEmpty)
                    .help("Copy this playlist into a single folder with an .m3u file")
                AddToExportListButton([.smartPlaylist(playlist.id)])
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.libraryVersion) { load() }
        .onChange(of: playlist.query) { load() }
    }

    private func load() { tracks = model.smartPlaylistTracks(playlist) }
}
