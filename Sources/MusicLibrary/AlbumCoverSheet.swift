import AppKit
import MusicLibraryCore
import SwiftUI

/// Image data turned into the JPEG saved as a cover: any format AppKit reads, scaled down to at most 1600 px.
enum CoverImage {
    static let maxPixels = 1600

    static func jpeg(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:)),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let longest = max(rep.pixelsWide, rep.pixelsHigh)
        if ImageTools.isJPEG(data), longest <= maxPixels { return data }
        guard let cg = rep.cgImage else { return nil }
        let scale = min(1, Double(maxPixels) / Double(longest))
        let w = max(1, Int(Double(rep.pixelsWide) * scale)), h = max(1, Int(Double(rep.pixelsHigh) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)  // transparent PNGs get a white background, as JPEG has no alpha
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

/// What the album page opens the cover sheet with: nothing, or an image dropped on the cover.
struct CoverSheetRequest: Identifiable {
    let id = UUID()
    var image: Data?
    var source: String?
}

/// Find or upload a new cover for an album, like the cover column of the import screen: covers of matching releases on
/// the Cover Art Archive (the album's tagged release first), or an image from a file, a drag or the clipboard.
struct AlbumCoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let album: AlbumSummary
    let tracks: [Track]
    let request: CoverSheetRequest

    struct Candidate: Identifiable, Hashable {
        var id: String { "\(releaseId)|\(releaseGroupId ?? "")" }
        var releaseId: String
        var releaseGroupId: String?
        var title: String
        var detail: String
    }

    @AppStorage("embedCoverInFiles") private var embed = true
    @State private var current: Data?
    @State private var image: Data?
    @State private var source: String?
    @State private var searchAlbum = ""
    @State private var searchArtist = ""
    /// The album's own release and release group, kept first whatever is searched.
    @State private var tagged: [Candidate] = []
    @State private var candidates: [Candidate] = []
    @State private var thumbnails: [String: Data] = [:]
    @State private var noArt: Set<String> = []
    @State private var chosen: String?
    @State private var searching = false
    @State private var downloading = false
    @State private var message: String?
    @State private var searchMessage: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var applying = false
    @State private var dropTargeted = false

    private var embeddableCount: Int { AlbumCoverWriter.embeddable(tracks).count }
    private var shown: [Candidate] { candidates.filter { !noArt.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Album Cover").font(.title2.bold())
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
            if let size = pixelSize(image ?? current) {
                Text(size).font(.caption).foregroundStyle(.subtext)
            }
            HStack {
                Button("Choose Image…", action: choose)
                Button("Paste", action: paste).help("Use an image you copied")
            }
            if image != nil { Button("Keep Current Cover") { image = nil; source = nil; chosen = nil }.buttonStyle(.link) }
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
                } else if shown.isEmpty, !candidates.isEmpty, candidates.allSatisfy({ noArt.contains($0.id) || thumbnails[$0.id] != nil }) {
                    Text("None of these releases has a cover on the Cover Art Archive. Try another search, or choose an image.")
                        .foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
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
        HStack(spacing: 12) {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 160)
                Text("Updating files… \(progress.done) of \(progress.total)").font(.callout).foregroundStyle(.subtext)
            } else if embeddableCount > 0 {
                Toggle("Also embed it in the album’s \(embeddableCount == 1 ? "file" : "\(embeddableCount) files")", isOn: $embed)
                    .help("Writes the cover into the library copies of the album's mp3, flac and m4a files, so other players and exported copies show it too")
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(applying)
            Button("Use This Cover") { Task { await apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil || applying || downloading)
        }
    }

    // MARK: Actions

    private func start() async {
        searchAlbum = album.album
        searchArtist = album.artist
        if let url = model.coverURL(forAlbum: album) {
            current = await Task.detached { try? Data(contentsOf: url) }.value
        }
        if let data = request.image { use(data, source: request.source ?? "Dropped image") }
        // The album's own release (and release group) first: most likely the right cover.
        var tagged: [Candidate] = []
        func mostCommon(_ values: [String?]) -> String? {
            let counts = values.compactMap { MBID.validated($0) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        let release = mostCommon(tracks.map(\.metadata.mbReleaseId))
        let group = mostCommon(tracks.map { $0.metadata.extended.mbReleaseGroupId })
        if let release {
            tagged.append(Candidate(releaseId: release, releaseGroupId: nil, title: album.album, detail: "The release your files are tagged with"))
        }
        if let group {
            tagged.append(Candidate(releaseId: "", releaseGroupId: group, title: album.album, detail: "This album’s main cover on MusicBrainz"))
        }
        self.tagged = tagged
        candidates = tagged
        await runSearch()
    }

    private func runSearch() async {
        guard !searchAlbum.isEmpty || !searchArtist.isEmpty else { return }
        searching = true
        searchMessage = nil
        defer { searching = false }
        let keep = tagged
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

    /// Downloads the large version of a candidate's cover (falling back to smaller ones).
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
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.isFileURL {
            Task { await load(url) }
        } else if let img = NSImage(pasteboard: pb), let data = img.tiffRepresentation {
            chosen = nil
            use(data, source: "Pasted image")
        } else {
            message = "There's no image on the clipboard."
        }
    }

    /// A file, or an image dragged from a web page (downloaded).
    private func load(_ url: URL) async {
        chosen = nil
        if url.isFileURL {
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            if let data { use(data, source: url.lastPathComponent) } else { message = "Couldn't read \(url.lastPathComponent)." }
        } else if let link = url.webLink {
            downloading = true
            defer { downloading = false }
            var request = URLRequest(url: link)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
            if let (data, _) = try? await URLSession.shared.data(for: request), NSImage(data: data) != nil {
                use(data, source: "Image from \(link.host() ?? "the web")")
            } else {
                message = "Couldn't download that image."
            }
        }
    }

    private func apply() async {
        guard let image, let jpeg = CoverImage.jpeg(from: image) else {
            message = "That image couldn't be converted to JPEG."
            return
        }
        applying = true
        defer { applying = false; progress = nil }
        let embedFiles = embed && embeddableCount > 0
        if embedFiles { progress = (0, embeddableCount) }
        do {
            let result = try await model.replaceCover(of: album, with: jpeg, embed: embedFiles) { done, total in
                Task { @MainActor in progress = (done, total) }
            }
            if !result.failures.isEmpty {
                let names = result.failures.prefix(3).map(\.file).joined(separator: ", ")
                model.errorMessage = "The cover was saved, but \(result.failures.count) file\(result.failures.count == 1 ? "" : "s") kept the old embedded art (\(names)\(result.failures.count > 3 ? "…" : "")): \(result.failures[0].message)"
            }
            dismiss()
        } catch {
            message = "Couldn't save the cover: \(error.localizedDescription)"
        }
    }
}
