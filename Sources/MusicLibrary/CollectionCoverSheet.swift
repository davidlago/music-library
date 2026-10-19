import AppKit
import MusicLibraryCore
import SwiftUI

/// Change Cover… for an item: a Cover Art Archive front (its own release and release group first, then releases found
/// on MusicBrainz), a file, a dragged image or the clipboard, saved as the item's own cover in
/// `Music/Collection Covers` (`AppModel.changeItem(id:cover:)`, a new file each time). An item with a cover of its own
/// can go back to its library album's. The album's files and cover.jpg are never touched.
struct CollectionCoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let itemID: String
    let request: CoverSheetRequest

    struct Candidate: Identifiable, Hashable {
        var id: String { "\(releaseId)|\(releaseGroupId ?? "")" }
        var releaseId: String
        var releaseGroupId: String?
        var title: String
        var detail: String
    }

    @State private var current: Data?
    @State private var image: Data?
    @State private var source: String?
    @State private var searchAlbum = ""
    @State private var searchArtist = ""
    @State private var own: [Candidate] = []
    @State private var candidates: [Candidate] = []
    @State private var thumbnails: [String: Data] = [:]
    @State private var noArt: Set<String> = []
    @State private var chosen: String?
    @State private var searching = false
    @State private var downloading = false
    @State private var message: String?
    @State private var searchMessage: String?
    @State private var dropTargeted = false

    private var shown: [Candidate] { candidates.filter { !noArt.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cover").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                preview
                Divider()
                searchPane
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 780, height: 560)
        .task { await start() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 10) {
            DataImage(data: image ?? current, size: 240)
                .overlay {
                    if downloading { ProgressView().controlSize(.large) }
                    if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 3) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    Task { await load(url) }
                    return true
                } isTargeted: { dropTargeted = $0 }
            Text(image != nil ? (source ?? "New cover") : (current != nil ? "Current cover" : "No cover yet"))
                .font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            HStack {
                Button("Choose Image…", action: choose)
                Button("Paste", action: paste).help("Use an image you copied")
            }
            if image != nil { Button("Keep Current Cover") { image = nil; source = nil; chosen = nil }.buttonStyle(.link) }
            if let item = model.item(id: itemID), item.coverFile != nil, model.linkedAlbum(for: item) != nil {
                Button("Use the Album's Cover") { useAlbumCover() }
                    .buttonStyle(.link)
                    .help("Show the cover of its album in your library instead of its own")
            }
            Text("Or drop an image file here.").font(.caption).foregroundStyle(.subtext)
            if let message { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .frame(width: 250)
    }

    // MARK: Search

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Album", text: $searchAlbum)
                TextField("Artist", text: $searchArtist)
                Button("Search") { Task { await runSearch() } }
                    .disabled(searching || (searchAlbum.isEmpty && searchArtist.isEmpty))
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateCell(_ c: Candidate) -> some View {
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

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Use This Cover", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil || downloading)
        }
    }

    // MARK: Actions

    private func start() async {
        guard let item = model.item(id: itemID) else { return }
        searchAlbum = item.album
        searchArtist = item.artist
        if let url = model.coverURL(for: item) {
            current = await Task.detached { try? Data(contentsOf: url) }.value
        }
        if let data = request.image { use(data, source: request.source ?? "Dropped image") }
        var own: [Candidate] = []
        if let release = item.releaseID {
            own.append(Candidate(releaseId: release, releaseGroupId: nil, title: item.album, detail: "The edition you own"))
        }
        if let group = item.releaseGroupID {
            own.append(Candidate(releaseId: "", releaseGroupId: group, title: item.album, detail: "This album’s main cover on MusicBrainz"))
        }
        self.own = own
        candidates = own
        await runSearch()
    }

    private func runSearch() async {
        guard !searchAlbum.isEmpty || !searchArtist.isEmpty else { return }
        searching = true
        searchMessage = nil
        defer { searching = false }
        let keep = own
        do {
            let found = try await model.musicBrainz.searchReleases(album: searchAlbum, artist: searchArtist)
            let known = Set(keep.map(\.releaseId))
            candidates = keep + found.filter { !known.contains($0.id) }.map { r in
                let parts = [r.date, r.country, r.format, r.label].filter { !$0.isEmpty }
                return Candidate(releaseId: r.id, releaseGroupId: nil, title: r.title,
                                 detail: ([r.artist] + parts).filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if candidates.isEmpty { searchMessage = "No releases found. Check the album and artist, or choose an image." }
        } catch {
            candidates = keep
            searchMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func loadThumbnail(_ c: Candidate) async {
        guard thumbnails[c.id] == nil, !noArt.contains(c.id) else { return }
        if let data = try? await model.coverArt.fetchFront(releaseId: c.releaseId, releaseGroupId: c.releaseGroupId, size: 250),
           NSImage(data: data) != nil {
            thumbnails[c.id] = data
        } else {
            noArt.insert(c.id)
        }
    }

    private func pick(_ c: Candidate) async {
        chosen = c.id
        downloading = true
        defer { downloading = false }
        for size in [1200, 500] {
            if let data = try? await model.coverArt.fetchFront(releaseId: c.releaseId, releaseGroupId: c.releaseGroupId, size: size),
               chosen == c.id, NSImage(data: data) != nil {
                use(data, source: "\(c.title) · \(c.detail)")
                return
            }
        }
        if chosen == c.id, let thumb = thumbnails[c.id] { use(thumb, source: "\(c.title) (small version)") }
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

    private func load(_ url: URL) async {
        chosen = nil
        downloading = !url.isFileURL
        defer { downloading = false }
        switch await ImageInput.load(url) {
        case .success(let image): use(image.data, source: image.source)
        case .failure(let failure): message = failure.message
        }
    }

    private func apply() {
        guard let image, let jpeg = CoverImage.jpeg(from: image) else {
            message = "That image couldn't be converted to JPEG."
            return
        }
        guard model.changeItem(id: itemID, cover: jpeg, { _ in }) != nil else {
            message = "Couldn't save the cover."
            return
        }
        dismiss()
    }

    /// Drops the item's own cover (its file is removed once saved): it shows its library album's again.
    private func useAlbumCover() {
        model.changeItem(id: itemID) { $0.coverFile = nil }
        dismiss()
    }
}
