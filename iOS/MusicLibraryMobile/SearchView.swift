import MusicLibraryCore
import SwiftUI

/// The Mac app's search: the same query language (`artist:`, `decade:90s`, `format:flac`, `own:vinyl`…) and
/// spelling correction, over the whole library and the collection (songs that aren't on the phone are dimmed and can
/// be downloaded). A label ("142", "cd 142", "v12") also shows the items that have it.
struct SearchTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var text = ""
    @State private var results = LibrarySearch.Results()

    var body: some View {
        LibraryStack {
            Group {
                if let library = model.library, !library.isEmpty {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                               description: Text("Try “radiohead”, “decade:90s”, “format:flac”, “own:vinyl” or a label like “cd 12”."))
                    } else {
                        SearchResultsList(results: results, text: text, library: library)
                    }
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Search")
        }
        .searchable(text: $text, prompt: "Songs, albums, artists, or artist:…")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: SearchKey(text: text, version: model.libraryVersion, collection: model.collectionVersion)) {
            guard let index = model.library?.index else { return }
            let query = text
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = LibrarySearch.Results(); return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let collectionIndex = model.collectionIndex, collection = model.collection
            let found = await Task.detached(priority: .userInitiated) {
                LibrarySearch.run(query, index: index, collectionIndex: collectionIndex, collection: collection)
            }.value
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private struct SearchKey: Equatable {
        var text: String
        var version: Int
        var collection: Int
    }
}

/// Results for a query opened from elsewhere (a genre, an Insights row…).
struct QueryPage: View {
    @Environment(PhoneModel.self) private var model
    let route: QueryRoute
    @State private var results: LibrarySearch.Results?

    var body: some View {
        Group {
            if let library = model.library, let results {
                SearchResultsList(results: results, text: route.query, library: library)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(route.title ?? route.query)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(route.query)|\(model.libraryVersion)|\(model.collectionVersion)") {
            guard let index = model.library?.index else { return }
            let query = route.query
            let collectionIndex = model.collectionIndex, collection = model.collection
            results = await Task.detached(priority: .userInitiated) {
                LibrarySearch.run(query, index: index, collectionIndex: collectionIndex, collection: collection, autocorrect: false)
            }.value
        }
    }
}

struct SearchResultsList: View {
    @Environment(PhoneModel.self) private var model
    let found: LibrarySearch.Results
    let text: String
    let library: LibrarySnapshot
    @State private var showAllItems = false

    init(results: LibrarySearch.Results, text: String, library: LibrarySnapshot) {
        found = results
        self.text = text
        self.library = library
    }

    private var results: SearchResults { found.library }

    var body: some View {
        // Label hits are listed on their own.
        let labelIDs = Set(found.labelHits.map(\.id))
        let items = found.items.filter { !labelIDs.contains($0.id) }
        if results.tracks.isEmpty && results.albums.isEmpty && results.artists.isEmpty && results.issues.isEmpty
            && found.labelHits.isEmpty && items.isEmpty {
            ContentUnavailableView.search(text: text)
        } else {
            List {
                if !found.labelHits.isEmpty {
                    Section("Label") {
                        ForEach(found.labelHits) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionRow(item: item) }
                        }
                    }
                }
                if !items.isEmpty {
                    Section("Collection") {
                        ForEach(items.prefix(showAllItems ? 200 : 6)) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionRow(item: item) }
                        }
                        if items.count > 6 {
                            Button(showAllItems ? "Show Fewer" : "Show All \(min(items.count, 200))") {
                                withAnimation(.snappy) { showAllItems.toggle() }
                            }
                            .font(.callout.weight(.medium))
                        }
                    }
                }
                if !results.issues.isEmpty {
                    Section {
                        ForEach(results.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
                if let corrected = results.correctedText {
                    Section { Text("Showing results for “\(corrected)”").font(.callout).foregroundStyle(.secondary) }
                }
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists.prefix(5)) { artist in
                            NavigationLink(value: artist) {
                                HStack(spacing: 12) {
                                    ArtistPhoto(name: artist.name, size: 40)
                                    Text(artist.name.isEmpty ? "Unknown Artist" : artist.name)
                                }
                            }
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums.prefix(10)) { album in
                            let tracks = library.tracks(album: album)
                            NavigationLink(value: album) {
                                HStack(spacing: 12) {
                                    CoverImage(url: library.coverURL(album: album), size: 44)
                                    VStack(alignment: .leading) {
                                        Text(album.album).lineLimit(1)
                                        Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    AvailabilityMark(availability: model.availability(tracks), pending: model.isDownloadPending(tracks))
                                }
                            }
                            .contextMenu { AlbumMenu(album: album) }
                        }
                    }
                }
                if !results.tracks.isEmpty {
                    Section("Songs") {
                        PlayButtons(tracks: results.tracks, source: text)
                        TrackRows(tracks: results.tracks, source: text)
                    }
                }
            }
        }
    }
}
