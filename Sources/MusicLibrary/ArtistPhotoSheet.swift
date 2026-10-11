import AppKit
import MusicLibraryCore
import SwiftUI

/// Find or upload a photo for an artist, like the album cover sheet: pictures from Deezer and Wikimedia (the artist's
/// Deezer page and Wikipedia article first, when MusicBrainz links them), or an image from a file, a drag or the
/// clipboard. The chosen photo is kept apart from the downloaded one, so updating the artist's info doesn't replace it.
struct ArtistPhotoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let name: String
    let request: CoverSheetRequest

    private let finder = ArtistPhotoFinder()

    @State private var current: Data?
    @State private var image: Data?
    @State private var source: String?
    @State private var credit: (label: String, url: URL?)?
    @State private var searchName = ""
    /// Photos the artist's links point to, kept first whatever is searched.
    @State private var linked: [ArtistPhotoCandidate] = []
    @State private var results: [ArtistPhotoCandidate] = []
    @State private var thumbnails: [String: Data] = [:]
    @State private var noImage: Set<String> = []
    @State private var chosen: String?
    @State private var loadingLinked = true
    @State private var searching = false
    @State private var downloading = false
    @State private var message: String?
    @State private var searchMessage: String?
    @State private var applying = false
    @State private var dropTargeted = false

    private var displayName: String { name.isEmpty ? "Unknown Artist" : name }

    private var shown: [ArtistPhotoCandidate] {
        var seen = Set<String>()
        return (linked + results).filter { !noImage.contains($0.id) && seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Artist Photo").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                preview
                Divider()
                search
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 780, height: 560)
        .task { await start() }
        .task { await loadLinked() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 10) {
            PhotoCircle(data: image ?? current, size: 220)
                .overlay {
                    if downloading { ProgressView().controlSize(.large) }
                    if dropTargeted { Circle().strokeBorder(theme.accent, lineWidth: 3) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    Task { await load(url) }
                    return true
                } isTargeted: { dropTargeted = $0 }
            Text(image != nil ? (source ?? "New photo") : (current != nil ? "Current photo" : "No photo yet"))
                .font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            if let size = pixelSize(image ?? current) {
                Text(size).font(.caption).foregroundStyle(.subtext)
            }
            HStack {
                Button("Choose Image…", action: choose)
                Button("Paste", action: paste).help("Use an image you copied")
            }
            if image != nil { Button("Keep Current Photo") { image = nil; source = nil; credit = nil; chosen = nil }.buttonStyle(.link) }
            Text("Or drop an image file here.").font(.caption).foregroundStyle(.subtext)
            if let message { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .frame(width: 250)
    }

    private func pixelSize(_ data: Data?) -> String? {
        guard let data, let rep = NSBitmapImageRep(data: data) else { return nil }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }

    // MARK: Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Artist", text: $searchName)
                Button("Search") { Task { await runSearch() } }
                    .disabled(searching || searchName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await runSearch() } }
            Text("Artist pictures from Deezer, and photos from Wikipedia and Wikimedia Commons").font(.caption).foregroundStyle(.subtext)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(shown) { c in candidateCell(c) }
                }
                .padding(2)
            }
            .overlay {
                if shown.isEmpty {
                    if searching || loadingLinked {
                        ProgressView("Searching Deezer and Wikimedia…")
                    } else if let searchMessage {
                        Text(searchMessage).foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateCell(_ c: ArtistPhotoCandidate) -> some View {
        Button { Task { await pick(c) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                PhotoCircle(data: thumbnails[c.id], size: 128)
                    .overlay {
                        if thumbnails[c.id] == nil { ProgressView().controlSize(.small) }
                        if chosen == c.id { Circle().strokeBorder(theme.accent, lineWidth: 3) }
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
        .help("Use this photo")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.artistInfo.hasChosenPhoto(name) {
                let downloaded = model.artistInfo.imageFiles[ArtistInfoStore.key(name)] != nil
                Button(downloaded ? "Use Downloaded Photo" : "Remove Photo", action: revert)
                    .disabled(applying)
                    .help(downloaded ? "Go back to the photo downloaded with the artist's info" : "Show the artist's initials again")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(applying)
            Button("Use This Photo", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil || applying || downloading)
        }
    }

    // MARK: Actions

    private func start() async {
        searchName = name
        if let url = model.artistInfo.imageURL(for: name) {
            current = await Task.detached { try? Data(contentsOf: url) }.value
        }
        if let data = request.image { use(data, source: request.source ?? "Dropped image") }
        await runSearch()
    }

    private func loadLinked() async {
        defer { loadingLinked = false }
        guard let info = model.artistInfo.info(for: name) else { return }
        linked = await finder.linked(info)
    }

    private func runSearch() async {
        let query = searchName.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        searchMessage = nil
        defer { searching = false }
        do {
            results = try await finder.search(query)
            if results.isEmpty { searchMessage = "No photos found. Check the name, or choose an image." }
        } catch {
            results = []
            searchMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func loadThumbnail(_ c: ArtistPhotoCandidate) async {
        guard thumbnails[c.id] == nil, !noImage.contains(c.id) else { return }
        if let data = try? await finder.thumbnail(c), NSImage(data: data) != nil {
            thumbnails[c.id] = data
        } else {
            noImage.insert(c.id)
        }
    }

    /// Downloads the large version of a candidate's photo (falling back to the thumbnail).
    private func pick(_ c: ArtistPhotoCandidate) async {
        chosen = c.id
        downloading = true
        defer { downloading = false }
        let credit = (label: c.credit, url: c.pageURL)
        if let data = try? await finder.image(for: c), chosen == c.id, NSImage(data: data) != nil {
            use(data, source: "\(c.title) · \(c.detail)", credit: credit)
        } else if chosen == c.id, let thumb = thumbnails[c.id] {
            use(thumb, source: "\(c.title) (small version)", credit: credit)
        }
    }

    private func use(_ data: Data, source: String, credit: (label: String, url: URL?)? = nil) {
        guard NSImage(data: data) != nil else { message = "That file isn't an image."; return }
        message = nil
        image = data
        self.source = source
        self.credit = credit
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

    private func apply() {
        guard let image, let jpeg = CoverImage.jpeg(from: image) else {
            message = "That image couldn't be converted to JPEG."
            return
        }
        applying = true
        defer { applying = false }
        do {
            try model.artistInfo.setPhoto(jpeg, for: name, credit: credit?.label, creditURL: credit?.url)
            dismiss()
        } catch {
            message = "Couldn't save the photo: \(error.localizedDescription)"
        }
    }

    private func revert() {
        do {
            try model.artistInfo.removeChosenPhoto(for: name)
            dismiss()
        } catch {
            message = "Couldn't remove the photo: \(error.localizedDescription)"
        }
    }
}

/// Image data in a circle, the way artist photos are shown.
private struct PhotoCircle: View {
    @Environment(\.theme) private var theme
    let data: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "person.fill").font(.system(size: size / 4)).foregroundStyle(.subtext)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}
