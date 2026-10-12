import MusicLibraryCore
import SwiftUI

struct SyncTab: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let sync = model.sync
        NavigationStack {
            List {
                if case .pairing(let code) = sync.status {
                    pairing(code)
                } else if !sync.isPaired {
                    Section {
                        Text("Sync music from Music Library on your Mac over Wi-Fi: your whole library shows up here to browse, and the Mac sends the albums, artists and playlists you choose, here or on the Mac.")
                            .foregroundStyle(.secondary)
                        Button("Pair with a Mac", systemImage: "link") { sync.startPairing() }
                    } footer: {
                        Text("The iPhone and the Mac need to be on the same Wi-Fi network.")
                    }
                } else {
                    paired(sync)
                }
                if let error = sync.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if !model.requests.isEmpty {
                    Section {
                        ForEach(model.requests.reversed()) { r in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title(r.item))
                                    Text(r.include ? "Download" : "Removed; the Mac stops syncing it").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: r.include ? "arrow.down.circle" : "minus.circle")
                            }
                        }
                    } header: {
                        Text("Waiting for the Mac")
                    } footer: {
                        Text("These go to \(sync.macName ?? "the Mac") at the next sync.")
                    }
                }
                if let date = sync.lastSync, let summary = sync.lastSummary {
                    Section("Last sync") {
                        LabeledContent("When") { Text(date, style: .relative) + Text(" ago") }
                        Text(SyncText.summary(summary)).foregroundStyle(.secondary)
                    }
                }
                if sync.isPaired {
                    Section {
                        if case .pairing = sync.status {} else {
                            Button("Pair Again", systemImage: "link") { sync.startPairing() }
                        }
                        Button("Unpair", systemImage: "link.badge.minus", role: .destructive) { sync.unpair() }
                    }
                }
            }
            .navigationTitle("Sync")
        }
    }

    @ViewBuilder
    private func pairing(_ code: String) -> some View {
        Section {
            VStack(spacing: 12) {
                Text(SyncPairing.display(code))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                Text("On the Mac, open Music Library, choose iPhone in the sidebar, pick this iPhone and enter this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ProgressView()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Button("Cancel", role: .cancel) { model.sync.cancelPairing() }
        } header: {
            Text("Pairing code")
        } footer: {
            Text("Keep this screen open until the Mac says it's paired.")
        }
    }

    @ViewBuilder
    private func paired(_ sync: PhoneSync) -> some View {
        Section {
            Label("Paired with \(sync.macName ?? "your Mac")", systemImage: "laptopcomputer.and.iphone")
            if case .syncing = sync.status {} else {
                if sync.macPeer != nil {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
                } else {
                    Label("Looking for \(sync.macName ?? "the Mac"). Open Music Library on it, on the same Wi-Fi.", systemImage: "wifi")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            switch sync.status {
            case .syncing(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Syncing…").font(.headline)
                    ProgressView(value: progress.fraction)
                    Text(SyncText.progress(progress)).font(.caption).foregroundStyle(.secondary)
                    if let current = progress.current {
                        Text((current as NSString).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            case .waiting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("The Mac can also start the sync while this tab is open.").foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        } footer: {
            Text("Keep the app open while syncing: iOS pauses it in the background. Download or remove music from album, artist and playlist pages; the iPhone syncs with the Mac as soon as it's around.")
        }
    }
}

enum SyncText {
    static func summary(_ s: SyncSummary) -> String {
        var parts: [String] = []
        parts.append(s.copied == 0 ? "Nothing new to copy" : "Copied \(s.copied) \(s.copied == 1 ? "file" : "files") (\(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)))")
        if s.deleted > 0 { parts.append("removed \(s.deleted)") }
        if s.plays > 0 { parts.append("sent \(s.plays) \(s.plays == 1 ? "play" : "plays")") }
        if s.likes > 0 { parts.append("sent \(s.likes) \(s.likes == 1 ? "like" : "likes")") }
        if s.databaseUpdated { parts.append("library updated") }
        if let n = s.purchases, n > 0 { parts.append("sent \(n) ownership \(n == 1 ? "change" : "changes")") }
        if s.missing > 0 { parts.append("\(s.missing) missing on the Mac") }
        return parts.joined(separator: ", ") + "."
    }

    static func progress(_ p: SyncProgress) -> String {
        let bytes = "\(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))"
        return p.totalFiles == 0 ? "Comparing with the Mac…" : "\(p.files) of \(p.totalFiles) files · \(bytes)"
    }
}

extension SyncTab {
    /// "Album · Artist", a playlist's name…
    func title(_ item: ExportItem) -> String {
        let library = model.library
        switch item {
        case .library: return "Entire library"
        case .album(let album, let artist): return "\(album.isEmpty ? "Unknown Album" : album) · \(artist)"
        case .artist(let name): return name.isEmpty ? "Unknown Artist" : name
        case .track(let id): return library?.track(id: id).map { "\($0.title) · \($0.artist)" } ?? "A song"
        case .playlist(let id): return library?.playlists.first { $0.id == id }?.playlist.name ?? "A playlist"
        case .smartPlaylist(let id): return library?.smartPlaylists.first { $0.id == id }?.name ?? "A smart playlist"
        case .likedSongs: return "Liked Songs"
        }
    }
}
