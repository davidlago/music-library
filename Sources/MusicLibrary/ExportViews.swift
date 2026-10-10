import AppKit
import MusicLibraryCore
import SwiftUI

/// Something picked for export. Resolved to tracks when exporting, so playlists export their current contents.
enum ExportItem: Codable, Hashable, Identifiable {
    case library
    case album(album: String, artist: String)
    case artist(String)
    case track(Int64)
    case playlist(Int64)
    case smartPlaylist(Int64)

    var id: Self { self }
}

/// The Export List page: what's been picked, the options, and the Export button.
struct ExportListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ExportItem>()
    @State private var totalBytes: Int64?

    var body: some View {
        @Bindable var model = model
        let tracks = model.exportListTracks
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.exportList) { item in
                    ExportItemRow(item: item).tag(item)
                        .contextMenu {
                            Button("Remove from Export List") { remove(selection.contains(item) ? selection : [item]) }
                        }
                }
            }
            .themedScrollBackground()
            .onDeleteCommand { remove(selection) }
            .overlay {
                if model.exportList.isEmpty {
                    ContentUnavailableView("Nothing to Export", systemImage: "externaldrive",
                                           description: Text("Right-click albums, songs, artists or playlists and choose Add to Export List, or add the entire library."))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Write playlist files (.m3u) to a Playlists folder", isOn: $model.exportPlaylistFiles)
                    .help("Playlists in the list also get an .m3u file that points at the exported songs. These files are replaced on every export.")
                Toggle("Back up the library database (replaces library.sqlite at the destination)", isOn: $model.exportBackupDatabase)
                    .help("Saves a snapshot of your library database, with playlists and listening history, to the root of the destination.")
                Text("Songs are copied into Music/Artist/Album like your library. Files already at the destination are never overwritten, and nothing is deleted.")
                    .font(.caption).foregroundStyle(.subtext)
                HStack {
                    Button("Add Entire Library") { model.addToExportList([.library]) }
                        .disabled(model.isInExportList(.library) || model.tracks.isEmpty)
                    Button("Clear") { model.clearExportList(); selection = [] }
                        .disabled(model.exportList.isEmpty)
                    Spacer()
                    Button { model.runExportList() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty && !model.exportBackupDatabase)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .navigationTitle("Export List")
        .navigationSubtitle(subtitle(count: tracks.count))
        .task(id: TrackSet(tracks)) {
            let root = model.libraryRoot
            totalBytes = nil
            totalBytes = await Task.detached(priority: .utility) {
                tracks.reduce(Int64(0)) { sum, t in
                    sum + ((try? FileManager.default.attributesOfItem(atPath: t.fileURL(root: root).path)[.size] as? NSNumber)?.int64Value ?? 0)
                }
            }.value
        }
    }

    private func subtitle(count: Int) -> String {
        guard count > 0 else { return "" }
        guard let totalBytes else { return songCount(count) }
        return "\(songCount(count)) · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }

    private func remove(_ items: Set<ExportItem>) {
        model.removeFromExportList(items)
        selection.subtract(items)
    }

    /// Identifies the tracks being sized, so the total is only recomputed when they change.
    private struct TrackSet: Equatable {
        let ids: [Int64]
        init(_ tracks: [Track]) { ids = tracks.map(\.id) }
    }
}

struct ExportItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ExportItem

    var body: some View {
        let count = model.tracks(for: item).count
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.subtext).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail(count: count)).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item {
        case .library: "music.note.house"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .track: "music.note"
        case .playlist: "music.note.list"
        case .smartPlaylist: "gearshape"
        }
    }

    private var title: String {
        switch item {
        case .library: return "Entire Library"
        case .album(let album, _): return album.isEmpty ? "Unknown Album" : album
        case .artist(let name): return name.isEmpty ? "Unknown Artist" : name
        case .track(let id): return model.trackByID[id].map { $0.title.isEmpty ? ($0.path as NSString).lastPathComponent : $0.title } ?? "Removed Song"
        case .playlist(let id): return model.playlists.first { $0.id == id }?.name ?? "Deleted Playlist"
        case .smartPlaylist(let id): return model.smartPlaylists.first { $0.id == id }?.name ?? "Deleted Playlist"
        }
    }

    private func detail(count: Int) -> String {
        switch item {
        case .library: return songCount(count)
        case .album(_, let artist): return "Album · \(artist.isEmpty ? "Unknown Artist" : artist) · \(songCount(count))"
        case .artist: return "Artist · \(songCount(count))"
        case .track(let id):
            guard let t = model.trackByID[id] else { return "No longer in the library" }
            return "Song · " + [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " — ")
        case .playlist: return "Playlist · \(songCount(count))"
        case .smartPlaylist: return "Smart Playlist · \(songCount(count))"
        }
    }
}

/// Progress for playlist exports and the Export List, then a summary of what the Export List copied.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let state = model.exportState
            if let error = state?.error {
                Text("Export to “\(state?.title ?? "")” Failed").font(.headline)
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close") { model.exportState = nil }.keyboardShortcut(.defaultAction)
                }
            } else if let summary = state?.summary {
                Text("Exported to “\(state?.title ?? "")”").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines(summary), id: \.self) { Text($0) }
                }
                .font(.callout)
                HStack {
                    if let dest = state?.destination {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
                    }
                    if state?.ejectableVolume != nil {
                        Button("Eject") { model.ejectExportDestination() }
                    }
                    Spacer()
                    Button("Done") { model.exportState = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            } else {
                Text("Exporting to “\(state?.title ?? "")”").font(.headline)
                ProgressView(value: Double(state?.done ?? 0), total: Double(max(state?.total ?? 1, 1)))
                HStack {
                    Text("\(state?.done ?? 0) of \(state?.total ?? 0) \(state?.destination != nil ? "files" : "tracks")")
                        .font(.caption).foregroundStyle(.subtext)
                    Spacer()
                    if state?.destination != nil {
                        Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        // Escape cancels a running export instead of hiding it.
        .interactiveDismissDisabled(model.exportState?.summary == nil && model.exportState?.error == nil)
    }

    private func lines(_ s: LibraryExportSummary) -> [String] {
        var out: [String] = []
        let size = ByteCountFormatter.string(fromByteCount: s.bytesCopied, countStyle: .file)
        out.append(s.copied == 0 ? "No new songs to copy." : "Copied \(songCount(s.copied)) (\(size)).")
        if s.skipped > 0 { out.append("\(songCount(s.skipped).capitalizedFirst) already there, left untouched.") }
        if s.covers > 0 { out.append("Added \(s.covers) album cover\(s.covers == 1 ? "" : "s").") }
        if s.playlists > 0 { out.append("Wrote \(s.playlists) playlist file\(s.playlists == 1 ? "" : "s").") }
        if s.databaseBackedUp { out.append("Backed up the library database (library.sqlite).") }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// "Add to Export List" for a context menu, disabled once the item is already there.
struct AddToExportListButton: View {
    @Environment(AppModel.self) private var model
    let items: [ExportItem]

    init(_ items: [ExportItem]) { self.items = items }
    init(tracks: [Track]) { items = tracks.map { .track($0.id) } }
    init(album: AlbumSummary) { items = [.album(album: album.album, artist: album.artist)] }

    var body: some View {
        Button("Add to Export List", systemImage: "externaldrive.badge.plus") { model.addToExportList(items) }
            .disabled(items.allSatisfy(model.isInExportList))
    }
}
