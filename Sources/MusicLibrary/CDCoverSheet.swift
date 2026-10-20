import AppKit
import MusicLibraryCore
import SwiftUI
import UniformTypeIdentifiers

/// A release whose Cover Art Archive front the cover sheets suggest.
struct CoverCandidate: Identifiable, Hashable {
    var id: String { "\(releaseId)|\(releaseGroupId ?? "")" }
    var releaseId: String
    var releaseGroupId: String?
    var title: String
    var detail: String
}

/// The search half of a cover sheet: album and artist fields, and the Cover Art Archive fronts of the releases
/// MusicBrainz finds for them (releases without one are left out). Picking one downloads its large version and hands it
/// to `onPick` with a line saying where it's from.
struct CoverSearchPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var album: String
    @Binding var artist: String
    /// The release picked last; cleared by the sheet when the image comes from somewhere else.
    @Binding var chosen: String?
    @Binding var downloading: Bool
    let onPick: (Data, String) -> Void

    @State private var candidates: [CoverCandidate] = []
    @State private var thumbnails: [String: Data] = [:]
    @State private var noArt: Set<String> = []
    @State private var searching = false
    @State private var searchMessage: String?

    private var shown: [CoverCandidate] { candidates.filter { !noArt.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Album", text: $album)
                TextField("Artist", text: $artist)
                Button("Search") { Task { await runSearch() } }
                    .disabled(searching || (album.isEmpty && artist.isEmpty))
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await runSearch() } }
            Text("Covers from the Cover Art Archive, for releases on MusicBrainz").font(.caption).foregroundStyle(.subtext)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(shown) { c in candidateCell(c) }
                }
                .padding(2)
            }
            .overlay {
                if searching {
                    ProgressView("Searching MusicBrainz…")
                } else if shown.isEmpty, let searchMessage {
                    Text(searchMessage).foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
                } else if shown.isEmpty, !candidates.isEmpty, candidates.allSatisfy({ noArt.contains($0.id) || thumbnails[$0.id] != nil }) {
                    Text("None of these releases has a cover on the Cover Art Archive. Try fewer words, just the artist, or choose an image.")
                        .foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await runSearch() }
    }

    private func candidateCell(_ c: CoverCandidate) -> some View {
        Button { Task { await pick(c) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                DataImage(data: thumbnails[c.id], size: 128)
                    .overlay {
                        if thumbnails[c.id] == nil { ProgressView().controlSize(.small) }
                        if chosen == c.id { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 3) }
                    }
                Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                Text(c.detail).font(.caption2).foregroundStyle(.subtext).lineLimit(2)
            }
            .frame(width: 128, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(thumbnails[c.id] == nil)
        .task(id: c.id) { await loadThumbnail(c) }
        .help("Use this cover")
    }

    private func runSearch() async {
        guard !album.isEmpty || !artist.isEmpty else {
            searchMessage = "Type an album or an artist to find covers."
            return
        }
        searching = true
        searchMessage = nil
        defer { searching = false }
        do {
            let found = try await model.musicBrainz.searchReleases(album: album, artist: artist)
            candidates = found.map { r in
                let parts = [r.date, r.country, r.format, r.label].filter { !$0.isEmpty }
                return CoverCandidate(releaseId: r.id, releaseGroupId: nil, title: r.title,
                                      detail: ([r.artist] + parts).filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if candidates.isEmpty { searchMessage = "No releases found. Try fewer words, just the artist, or choose an image." }
        } catch {
            candidates = []
            searchMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func loadThumbnail(_ c: CoverCandidate) async {
        guard thumbnails[c.id] == nil, !noArt.contains(c.id) else { return }
        if let data = try? await model.coverArt.fetchFront(releaseId: c.releaseId, releaseGroupId: c.releaseGroupId, size: 250),
           NSImage(data: data) != nil {
            thumbnails[c.id] = data
        } else {
            noArt.insert(c.id)
        }
    }

    /// Downloads the large version of a candidate's cover (falling back to smaller ones).
    private func pick(_ c: CoverCandidate) async {
        chosen = c.id
        downloading = true
        defer { downloading = false }
        for size in [1200, 500] {
            if let data = try? await model.coverArt.fetchFront(releaseId: c.releaseId, releaseGroupId: c.releaseGroupId, size: size),
               chosen == c.id, NSImage(data: data) != nil {
                onPick(data, "\(c.title) · \(c.detail)")
                return
            }
        }
        if chosen == c.id, let thumb = thumbnails[c.id] { onPick(thumb, "\(c.title) (small version)") }
    }
}

/// Choose Cover… on the page of a disc MusicBrainz doesn't know: covers of releases MusicBrainz finds for the page's
/// album and artist (often another edition with the same art), or an image from a file, a drag (also from a web page)
/// or the clipboard. The cover goes to the disc (`CDController.setCover`), and to the CD in your collection once it's
/// there.
struct CDCoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var disc: CDDisc

    @State private var image: Data?
    @State private var source: String?
    @State private var album = ""
    @State private var artist = ""
    @State private var chosen: String?
    @State private var downloading = false
    @State private var message: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CD Cover").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                preview
                Divider()
                CoverSearchPane(album: $album, artist: $artist, chosen: $chosen, downloading: $downloading) { data, source in
                    use(data, source: source)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Cover") {
                    if let image { model.cd.setCover(disc, image) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil || downloading)
            }
        }
        .padding(20)
        .frame(width: 780, height: 560)
        .onAppear {
            // The search starts from the names on the page (the disc's, or what was typed there).
            album = disc.searchAlbum
            artist = disc.searchArtist
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            DataImage(data: image ?? disc.cover, size: 240)
                .overlay {
                    if downloading { ProgressView().controlSize(.large) }
                    if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 3) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    Task { await load(url) }
                    return true
                } isTargeted: { dropTargeted = $0 }
            Text(image != nil ? (source ?? "New cover") : (disc.cover != nil ? "Current cover" : "No cover yet"))
                .font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            HStack {
                Button("Choose Image…", action: choose)
                Button("Paste", action: paste).help("Use an image you copied")
            }
            Text("Or drop an image here, from a file or a web page.").font(.caption).foregroundStyle(.subtext)
                .multilineTextAlignment(.center)
            if let message { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .frame(width: 250)
    }

    private func use(_ data: Data, source: String) {
        guard NSImage(data: data) != nil else { message = "That file isn't an image."; return }
        message = nil
        image = data
        self.source = source
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    private func paste() {
        switch ImageInput.pasted() {
        case .file(let url): Task { await load(url) }
        case .image(let data): chosen = nil; use(data, source: "Pasted image")
        case nil: message = "There's no image on the clipboard."
        }
    }

    /// A file, or an image dragged from a web page (downloaded).
    private func load(_ url: URL) async {
        chosen = nil
        downloading = !url.isFileURL
        defer { downloading = false }
        switch await ImageInput.load(url) {
        case .success(let image): use(image.data, source: image.source)
        case .failure(let failure): message = failure.message
        }
    }
}
