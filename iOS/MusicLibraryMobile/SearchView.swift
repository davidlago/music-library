import MusicLibraryCore
import SwiftUI

/// The Mac app's search: the same query language (`artist:`, `decade:90s`, `format:flac`…) and spelling correction.
struct SearchTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var text = ""
    @State private var results = SearchResults()

    var body: some View {
        NavigationStack {
            Group {
                if let library = model.library, !library.tracks.isEmpty {
                    resultsList(library)
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Search")
            .libraryDestinations()
        }
        .searchable(text: $text, prompt: "Songs, albums, artists, or artist:…")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .task(id: SearchKey(text: text, library: model.library?.root, count: model.library?.tracks.count ?? 0)) {
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
        var library: URL?
        var count: Int
    }

    @ViewBuilder
    private func resultsList(_ library: LibrarySnapshot) -> some View {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                   description: Text("Try “radiohead”, “decade:90s”, “format:flac” or “genre:jazz”."))
        } else if results.tracks.isEmpty && results.albums.isEmpty && results.artists.isEmpty && results.issues.isEmpty {
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
                            NavigationLink(artist.name, value: artist)
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums.prefix(10)) { album in
                            NavigationLink(value: album) {
                                HStack(spacing: 12) {
                                    CoverImage(url: library.coverURL(album: album), size: 44)
                                    VStack(alignment: .leading) {
                                        Text(album.album).lineLimit(1)
                                        Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !results.tracks.isEmpty {
                    Section("Songs") {
                        TrackRows(tracks: results.tracks, source: "Search")
                    }
                }
            }
        }
    }
}
