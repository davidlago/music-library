import AppKit
import MusicLibraryCore
import SwiftUI

/// Something picked for export. Resolved to tracks when exporting, so playlists export their current contents.
/// The Export List page. With a destination chosen it splits in two: what's being added on the left, what the
/// destination already holds on the right, with what the export will actually copy highlighted on both sides.
struct ExportListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ExportItem>()
    @State private var totalBytes: Int64?
    @State private var preview: ExportPreview?
    @State private var previewError: String?
    @State private var scanning = false
    /// Bumped to rescan the destination (refresh button, drives mounting and unmounting).
    @State private var refreshToken = 0

    var body: some View {
        let tracks = model.exportListTracks
        VStack(spacing: 0) {
            ExportDestinationBar(scanning: scanning) { refreshToken += 1 }
            Divider()
            if model.exportDestination == nil {
                picks(preview: nil)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ExportPaneHeader(title: "Adding", systemImage: "plus.circle",
                                         detail: addingDetail(tracks.count))
                        Divider()
                        picks(preview: preview?.isAvailable == true ? preview : nil)
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    DestinationContentsView(preview: preview, error: previewError, scanning: scanning)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            ExportListFooter(preview: preview?.isAvailable == true ? preview : nil, hasTracks: !tracks.isEmpty)
        }
        .navigationTitle("Export List")
        .navigationSubtitle(subtitle(count: tracks.count))
        .task(id: TrackSet(tracks)) {
            let root = model.libraryRoot
            totalBytes = nil
            totalBytes = await Task.detached(priority: .utility) {
                tracks.reduce(Int64(0)) { $0 + ($1.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0) }
            }.value
        }
        .task(id: PreviewKey(destination: model.exportDestination, tracks: TrackSet(tracks), artistImages: model.exportBackupDatabase,
                             revision: model.exportRevision, libraryVersion: model.libraryVersion, collectionVersion: model.collectionVersion,
                             refresh: refreshToken)) {
            guard let dest = model.exportDestination else { preview = nil; previewError = nil; return }
            let root = model.libraryRoot, artistImages = model.exportBackupDatabase
            // The database backup refers to the collection's own covers, so they go with it.
            let covers = artistImages ? model.collectionCoverPaths() : []
            scanning = true
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ExportPreview.make(tracks: tracks, libraryRoot: root, destination: dest, artistImages: artistImages,
                                                collectionCovers: covers) }
            }.value
            guard !Task.isCancelled else { return }
            scanning = false
            switch result {
            case .success(let p): preview = p; previewError = nil
            case .failure(let e): preview = nil; previewError = e.localizedDescription
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshToken += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshToken += 1 }
    }

    /// The picked items; each expands to its songs, marked as going to be copied or already at the destination.
    private func picks(preview: ExportPreview?) -> some View {
        List(selection: $selection) {
            ForEach(model.exportList) { item in
                let tracks = model.tracks(for: item)
                DisclosureGroup {
                    ForEach(tracks) { t in ExportTrackRow(track: t, incomingSize: preview?.incoming[t.path], known: preview != nil) }
                } label: {
                    HStack {
                        ExportItemRow(item: item)
                        Spacer(minLength: 8)
                        if let preview { ExportItemStatus(tracks: tracks, preview: preview) }
                    }
                }
                .tag(item)
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
    }

    private func addingDetail(_ count: Int) -> String {
        guard count > 0 else { return "Nothing picked yet" }
        guard let preview, preview.isAvailable else { return songCount(count) }
        let new = preview.plan.files.count
        return new == 0 ? "\(songCount(count)), all already there" : "\(songCount(count)), \(new.formatted()) new"
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

    /// Identifies the tracks being sized, so totals are only recomputed when they change.
    private struct TrackSet: Equatable {
        let ids: [Int64]
        init(_ tracks: [Track]) { ids = tracks.map(\.id) }
    }

    private struct PreviewKey: Equatable {
        var destination: URL?
        var tracks: TrackSet
        var artistImages: Bool
        var revision: Int
        var libraryVersion: Int
        var collectionVersion: Int
        var refresh: Int
    }
}

/// The saved destination, with buttons to change it, reveal it and rescan it.
struct ExportDestinationBar: View {
    @Environment(AppModel.self) private var model
    let scanning: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.subtext)
            if let dest = model.exportDestination {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dest.lastPathComponent).font(.headline)
                    Text(dest.path).font(.caption).foregroundStyle(.subtext).lineLimit(1).truncationMode(.middle)
                }
                if !model.exportDestinationAvailable && !scanning {
                    Text("Not connected").font(.caption.weight(.medium)).foregroundStyle(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().strokeBorder(.orange.opacity(0.6)))
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("No destination").font(.headline)
                    Text("Choose your music player, USB drive or backup folder.").font(.caption).foregroundStyle(.subtext)
                }
            }
            Spacer()
            if scanning { ProgressView().controlSize(.small) }
            if let dest = model.exportDestination {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the destination again")
                Button { NSWorkspace.shared.activateFileViewerSelecting([dest]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                    .disabled(!model.exportDestinationAvailable)
            }
            Button(model.exportDestination == nil ? "Choose Destination…" : "Change…") { model.chooseExportDestination() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ExportPaneHeader: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 34)
    }
}

/// How much of an item the export will copy: everything, part of it, or nothing because it's already there.
struct ExportItemStatus: View {
    let tracks: [Track]
    let preview: ExportPreview

    var body: some View {
        let sizes = tracks.compactMap { preview.incoming[$0.path] }
        if tracks.isEmpty {
            EmptyView()
        } else if sizes.isEmpty {
            Label("Already there", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.subtext).labelStyle(.titleAndIcon)
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
            ExportBadge(text: sizes.count == tracks.count ? "All new · \(bytes)" : "+\(sizes.count) new · \(bytes)")
        }
    }
}

struct ExportTrackRow: View {
    let track: Track
    /// The size to copy, or nil when the destination already has the song.
    let incomingSize: Int64?
    /// False while the destination hasn't been read (or there's none), so no status is shown.
    let known: Bool

    var body: some View {
        HStack(spacing: 8) {
            if known {
                Image(systemName: incomingSize == nil ? "checkmark.circle" : "arrow.up.circle.fill")
                    .foregroundStyle(incomingSize == nil ? AnyShapeStyle(.subtext) : AnyShapeStyle(.tint))
                    .help(incomingSize == nil ? "Already at the destination" : "Will be copied")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title).lineLimit(1)
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let incomingSize {
                Text(ByteCountFormatter.string(fromByteCount: incomingSize, countStyle: .file))
                    .font(.caption).foregroundStyle(.subtext).monospacedDigit()
            }
        }
        .opacity(known && incomingSize == nil ? 0.55 : 1)
    }
}

struct ExportBadge: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(theme.accent).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(theme.accent.opacity(0.15)))
    }
}

/// The destination's album folders, library data and playlists, including what the export will add.
struct DestinationContentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let preview: ExportPreview?
    let error: String?
    let scanning: Bool
    @AppStorage("exportShowOnlyChanges") private var onlyChanges = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ExportPaneHeader(title: "On \(model.exportDestination?.lastPathComponent ?? "Destination")",
                                 systemImage: "externaldrive", detail: detail)
                Toggle("Only changes", isOn: $onlyChanges).toggleStyle(.checkbox).controlSize(.small).fixedSize()
                    .padding(.trailing, 14)
                    .help("Show only the album folders this export adds to or creates")
            }
            Divider()
            content
        }
    }

    private var detail: String {
        guard let preview, preview.isAvailable else { return "" }
        var parts = ["\(songCount(preview.existingFiles)) in \(preview.existingAlbums.formatted()) album\(preview.existingAlbums == 1 ? "" : "s")"]
        if let free = preview.availableCapacity { parts.append("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't Read the Destination", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxHeight: .infinity)
        } else if let preview {
            if !preview.isAvailable {
                ContentUnavailableView("Destination Not Available", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text("Connect the drive, or choose another destination."))
                    .frame(maxHeight: .infinity)
            } else {
                list(preview)
            }
        } else {
            ProgressView("Reading the destination…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ preview: ExportPreview) -> some View {
        let folders = onlyChanges ? preview.folders.filter { $0.incomingFiles > 0 || $0.incomingCover } : preview.folders
        let byArtist = Dictionary(grouping: folders, by: \.artist)
        let artists = folders.map(\.artist).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        return List {
            libraryData(preview)
            ForEach(artists, id: \.self) { artist in
                Section(artist.isEmpty ? "Music" : artist) {
                    ForEach(byArtist[artist] ?? []) { f in
                        DestinationFolderRow(folder: f)
                            .listRowBackground(f.incomingFiles > 0 || f.incomingCover ? theme.accent.opacity(0.10) : Color.clear)
                    }
                }
            }
        }
        .themedScrollBackground()
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView(onlyChanges ? "No Changes" : "No Music Yet", systemImage: "music.note",
                                       description: Text(onlyChanges ? "Everything picked is already at the destination." : "Nothing in a Music folder here yet."))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func libraryData(_ preview: ExportPreview) -> some View {
        let playlistsToWrite = model.exportPlaylistsToWrite.count
        let backup = model.exportBackupDatabase
        if preview.database != nil || !preview.playlists.isEmpty || preview.artistImageCount > 0 || playlistsToWrite > 0 || backup {
            Section("Library Data") {
                if preview.database != nil || backup {
                    DestinationDataRow(systemImage: "cylinder.split.1x2", title: "Library database",
                                       detail: preview.database.map { db in
                                           "Backed up \(db.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "") · \(ByteCountFormatter.string(fromByteCount: db.size, countStyle: .file))"
                                       } ?? "Not backed up yet",
                                       badge: backup ? (preview.database == nil ? "New" : "Will be replaced") : nil)
                }
                if preview.artistImageCount > 0 || !preview.plan.artistImages.isEmpty {
                    DestinationDataRow(systemImage: "person.crop.square", title: "Artist photos",
                                       detail: "\(preview.artistImageCount.formatted()) photo\(preview.artistImageCount == 1 ? "" : "s")",
                                       badge: preview.plan.artistImages.isEmpty ? nil : "+\(preview.plan.artistImages.count) new or updated")
                }
                if !preview.plan.collectionCovers.isEmpty {
                    DestinationDataRow(systemImage: "books.vertical", title: "Collection covers",
                                       detail: "The covers of your copies that have their own",
                                       badge: "+\(preview.plan.collectionCovers.count) new")
                }
                if !preview.playlists.isEmpty || playlistsToWrite > 0 {
                    DestinationDataRow(systemImage: "music.note.list", title: "Playlists",
                                       detail: preview.playlists.isEmpty ? "None yet" : preview.playlists.map { ($0 as NSString).deletingPathExtension }.joined(separator: ", "),
                                       badge: playlistsToWrite > 0 ? "\(playlistsToWrite) to write" : nil)
                }
            }
        }
    }
}

struct DestinationFolderRow: View {
    let folder: ExportPreview.Folder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isNew ? "folder.badge.plus" : "folder")
                .foregroundStyle(folder.isNew ? AnyShapeStyle(.tint) : AnyShapeStyle(.subtext))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.album.isEmpty ? "Loose files" : folder.album).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge { ExportBadge(text: badge) }
        }
    }

    private var detail: String {
        if folder.isNew { return "Not on the destination yet" }
        var parts = ["\(songCount(folder.existingFiles))", ByteCountFormatter.string(fromByteCount: folder.existingBytes, countStyle: .file)]
        if !folder.hasCover && !folder.incomingCover { parts.append("no cover") }
        return parts.joined(separator: " · ")
    }

    private var badge: String? {
        let size = ByteCountFormatter.string(fromByteCount: folder.incomingBytes, countStyle: .file)
        if folder.isNew { return "New · \(songCount(folder.incomingFiles)) · \(size)" }
        if folder.incomingFiles > 0 { return "+\(folder.incomingFiles) · \(size)" }
        return folder.incomingCover ? "+ cover" : nil
    }
}

struct DestinationDataRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let badge: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.subtext).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.subtext).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let badge { ExportBadge(text: badge) }
        }
    }
}

/// Options, a summary of what will be copied, and the buttons.
struct ExportListFooter: View {
    @Environment(AppModel.self) private var model
    let preview: ExportPreview?
    let hasTracks: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Write playlist files (.m3u) to a Playlists folder", isOn: $model.exportPlaylistFiles)
                .help("Playlists in the list also get an .m3u file that points at the exported songs. These files are replaced on every export.")
            Toggle("Back up the library database and artist photos (replaces library.sqlite at the destination)", isOn: $model.exportBackupDatabase)
                .help("Saves a snapshot of your library database, with playlists and listening history, to the root of the destination, and copies new or updated artist photos so they don't need downloading again.")
            summary
            HStack {
                Button("Add Entire Library") { model.addToExportList([.library]) }
                    .disabled(model.isInExportList(.library) || model.tracks.isEmpty)
                Button("Clear") { model.clearExportList() }
                    .disabled(model.exportList.isEmpty)
                Spacer()
                if let dest = model.exportDestination {
                    Button { model.runExportList() } label: { Label("Export to “\(dest.lastPathComponent)”", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExport)
                } else {
                    Button("Choose Destination…") { model.chooseExportDestination() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
    }

    private var canExport: Bool {
        guard model.exportDestinationAvailable, model.exportState == nil else { return false }
        guard let preview else { return hasTracks || model.exportBackupDatabase }
        if let free = preview.availableCapacity, preview.plan.bytesNeeded > free { return false }
        return !preview.plan.files.isEmpty || !preview.plan.covers.isEmpty || model.exportBackupDatabase || !model.exportPlaylistsToWrite.isEmpty
    }

    @ViewBuilder
    private var summary: some View {
        if let preview {
            let plan = preview.plan
            let bytes = ByteCountFormatter.string(fromByteCount: plan.bytesNeeded, countStyle: .file)
            HStack(spacing: 6) {
                if let free = preview.availableCapacity, plan.bytesNeeded > free {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Not enough space: \(bytes) needed, \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free.")
                        .foregroundStyle(.red)
                } else if plan.files.isEmpty && plan.covers.isEmpty && plan.artistImages.isEmpty && plan.collectionCovers.isEmpty {
                    Image(systemName: "checkmark.circle").foregroundStyle(.subtext)
                    Text(hasTracks ? "Every picked song is already at the destination." : "Pick something to export.").foregroundStyle(.subtext)
                } else {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)
                    Text(copyLine(plan) + " (\(bytes))").fontWeight(.medium)
                    if plan.skipped > 0 { Text("· \(songCount(plan.skipped)) already there").foregroundStyle(.subtext) }
                }
            }
            .font(.callout)
        } else {
            Text("Songs are copied into Music/Artist/Album like your library. Files already at the destination are never overwritten, and nothing is deleted.")
                .font(.caption).foregroundStyle(.subtext)
        }
    }

    private func copyLine(_ plan: LibraryExporter.Plan) -> String {
        var parts: [String] = []
        if !plan.files.isEmpty { parts.append(songCount(plan.files.count)) }
        if !plan.covers.isEmpty { parts.append("\(plan.covers.count) album cover\(plan.covers.count == 1 ? "" : "s")") }
        if !plan.artistImages.isEmpty { parts.append("\(plan.artistImages.count) artist photo\(plan.artistImages.count == 1 ? "" : "s")") }
        if !plan.collectionCovers.isEmpty {
            parts.append("\(plan.collectionCovers.count) collection cover\(plan.collectionCovers.count == 1 ? "" : "s")")
        }
        return "Will copy " + ListFormatter.localizedString(byJoining: parts)
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
        case .likedSongs: "heart.fill"
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
        case .likedSongs: return AppModel.likedSongsName
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
        case .playlist, .likedSongs: return "Playlist · \(songCount(count))"
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
        if s.artistImages > 0 { out.append("Copied \(s.artistImages) artist photo\(s.artistImages == 1 ? "" : "s").") }
        if s.collectionCovers > 0 { out.append("Copied \(s.collectionCovers) collection cover\(s.collectionCovers == 1 ? "" : "s").") }
        if s.playlists > 0 { out.append("Wrote \(s.playlists) playlist file\(s.playlists == 1 ? "" : "s").") }
        if s.databaseBackedUp { out.append("Backed up the library database (library.sqlite).") }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// "Add to Export List" (and "Add to iPhone") for a context menu, each disabled once the item is already there.
struct AddToExportListButton: View {
    @Environment(AppModel.self) private var model
    let items: [ExportItem]

    init(_ items: [ExportItem]) { self.items = items }
    init(tracks: [Track]) { items = tracks.map { .track($0.id) } }
    init(album: AlbumSummary) { items = [.album(album: album.album, artist: album.artist)] }

    var body: some View {
        Button("Add to Export List", systemImage: "externaldrive.badge.plus") { model.addToExportList(items) }
            .disabled(items.allSatisfy(model.isInExportList))
        AddToIPhoneButton(items: items)
    }
}
