import MusicLibraryCore
import SwiftUI

/// The Mac app's search: the same query language (`artist:`, `decade:90s`, `format:flac`…) and spelling correction,
/// over the whole library (songs that aren't on the phone are dimmed and can be downloaded).
struct SearchTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var text = ""
    @State private var results = SearchResults()

    var body: some View {
        LibraryStack {
            Group {
                if let library = model.library, !library.tracks.isEmpty {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                               description: Text("Try “radiohead”, “decade:90s”, “format:flac” or “genre:jazz”."))
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
        .task(id: SearchKey(text: text, version: model.libraryVersion)) {
            guard let index = model.library?.index else { return }
            let query = text
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = SearchResults(); return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { index.search(query) }.value
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private struct SearchKey: Equatable {
        var text: String
        var version: Int
    }
}

/// Results for a query opened from elsewhere (a genre, an Insights row…).
struct QueryPage: View {
    @Environment(PhoneModel.self) private var model
    let route: QueryRoute
    @State private var results: SearchResults?

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
        .task(id: "\(route.query)|\(model.libraryVersion)") {
            guard let index = model.library?.index else { return }
            let query = route.query
            results = await Task.detached(priority: .userInitiated) { index.search(query, autocorrect: false) }.value
        }
    }
}

struct SearchResultsList: View {
    @Environment(PhoneModel.self) private var model
    let results: SearchResults
    let text: String
    let library: LibrarySnapshot

    var body: some View {
        if results.tracks.isEmpty && results.albums.isEmpty && results.artists.isEmpty && results.issues.isEmpty {
            ContentUnavailableView.search(text: text)
        } else {
            List {
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
