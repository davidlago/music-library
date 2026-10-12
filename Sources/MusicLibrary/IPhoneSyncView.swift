import MusicLibraryCore
import SwiftUI

/// The iPhone page: paired phones (and ones nearby asking to pair), the list the phone keeps, and syncing it.
struct IPhoneSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ExportItem>()
    @State private var codes: [String: String] = [:]
    @State private var totalBytes: Int64?

    var body: some View {
        let store = model.iPhone
        let tracks = model.iPhoneTracks
        VStack(spacing: 0) {
            phones(store, songs: tracks.count)
            Divider()
            if store.list.isEmpty {
                ContentUnavailableView("Nothing to Sync Yet", systemImage: "iphone",
                                       description: Text("Add albums, artists, playlists or songs with Add to iPhone in their menus. The iPhone keeps exactly this list."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.list) { ExportItemRow(item: $0).tag($0) }
                }
                .contextMenu(forSelectionType: ExportItem.self) { items in
                    Button("Remove from iPhone List", systemImage: "minus.circle") { store.remove(items) }
                }
                .onDeleteCommand { store.remove(selection) }
                .themedScrollBackground()
            }
            Divider()
            HStack {
                Text(footer(songs: tracks.count)).foregroundStyle(.subtext)
                Spacer()
                Text("The iPhone keeps exactly this list: what you remove here is removed from it at the next sync.")
                    .font(.caption).foregroundStyle(.subtext)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .navigationTitle("iPhone")
        .onAppear { store.startBrowsing() }
        .onDisappear { store.stopBrowsing() }
        .task(id: tracks.map(\.id)) {
            let root = model.libraryRoot
            totalBytes = nil
            totalBytes = await Task.detached(priority: .utility) {
                tracks.reduce(Int64(0)) { $0 + ($1.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0) }
            }.value
        }
        .alert("Remove songs from the iPhone?", isPresented: Binding(get: { store.pendingDeletes != nil }, set: { if !$0 { store.answerDeletes(false) } })) {
            Button("Remove from iPhone", role: .destructive) { store.answerDeletes(true) }
            Button("Keep Them", role: .cancel) { store.answerDeletes(false) }
        } message: {
            let n = store.pendingDeletes ?? 0
            Text("\(n) \(n == 1 ? "file" : "files") on the iPhone aren't in this list. Syncing makes the iPhone match the list, so they'd be removed. Keep them to sync without removing anything this time.")
        }
    }

    @ViewBuilder
    private func phones(_ store: SyncStore, songs: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.phones) { phone in
                phoneRow(phone, store: store, songs: songs)
            }
            ForEach(store.pairingPeers) { peer in
                pairRow(peer, store: store)
            }
            if store.phones.isEmpty && store.pairingPeers.isEmpty {
                Label("To pair, open Music Library on the iPhone, go to its Sync tab and tap Pair with a Mac. The iPhone and this Mac need to be on the same Wi-Fi network.",
                      systemImage: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(.subtext)
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func phoneRow(_ phone: SyncStore.PairedPhone, store: SyncStore, songs: Int) -> some View {
        let peer = store.peer(for: phone)
        return HStack(spacing: 12) {
            Image(systemName: "iphone").font(.title).foregroundStyle(.subtext).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.name).font(.headline)
                if case .syncing(phone.id, let progress) = store.activity {
                    Text(progressText(progress)).font(.caption).foregroundStyle(.subtext)
                } else if peer != nil {
                    Label("Ready to sync", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                        .labelStyle(.titleAndIcon).imageScale(.small)
                } else {
                    Text("Not found. Open the Sync tab in Music Library on the iPhone.").font(.caption).foregroundStyle(.subtext)
                }
                if let date = phone.lastSync {
                    (Text("Last synced ") + Text(date, style: .relative) + Text(" ago" + (phone.lastSummary.map { ": " + summaryText($0) } ?? "")))
                        .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                }
            }
            Spacer()
            if case .syncing(phone.id, let progress) = store.activity {
                ProgressView(value: progress.fraction).frame(width: 160)
                Button("Cancel") { store.cancel() }
            } else {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.syncIPhone(phone) }
                    .disabled(peer == nil || store.isBusy || songs == 0)
                Menu {
                    Button("Unpair", role: .destructive) { store.unpair(phone) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func pairRow(_ peer: SyncPeer, store: SyncStore) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.title).foregroundStyle(.subtext).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.headline)
                Text("Wants to pair. Enter the code it shows.").font(.caption).foregroundStyle(.subtext)
            }
            Spacer()
            TextField("Code", text: Binding(get: { codes[peer.id] ?? "" }, set: { codes[peer.id] = $0 }))
                .font(.system(.body, design: .monospaced))
                .frame(width: 140)
                .onSubmit { store.pair(peer, code: codes[peer.id] ?? "") }
            if case .pairing(peer.id) = store.activity {
                ProgressView().controlSize(.small)
            } else {
                Button("Pair") { store.pair(peer, code: codes[peer.id] ?? "") }
                    .disabled(store.isBusy || SyncPairing.normalize(codes[peer.id] ?? "") == nil)
            }
        }
    }

    private func footer(songs: Int) -> String {
        let size = totalBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return "\(songs) \(songs == 1 ? "song" : "songs")\(size)"
    }

    private func progressText(_ p: SyncProgress) -> String {
        guard p.totalFiles > 0 else { return "Comparing with the iPhone…" }
        let f = ByteCountFormatter()
        return "Copying \(p.files) of \(p.totalFiles) files · \(f.string(fromByteCount: p.bytes)) of \(f.string(fromByteCount: p.totalBytes))"
    }

    private func summaryText(_ s: SyncSummary) -> String {
        var parts = [s.copied == 0 ? "nothing new to copy" : "copied \(s.copied) \(s.copied == 1 ? "file" : "files")"]
        if s.deleted > 0 { parts.append("removed \(s.deleted)") }
        if s.plays > 0 { parts.append("\(s.plays) \(s.plays == 1 ? "play" : "plays") added") }
        if s.likes > 0 { parts.append("\(s.likes) \(s.likes == 1 ? "like" : "likes") updated") }
        if s.missing > 0 { parts.append("\(s.missing) missing here") }
        return parts.joined(separator: ", ")
    }
}

/// "Add to iPhone" for a context menu, disabled once the item is already on the iPhone list.
struct AddToIPhoneButton: View {
    @Environment(AppModel.self) private var model
    let items: [ExportItem]

    var body: some View {
        Button("Add to iPhone", systemImage: "iphone") { model.iPhone.add(items) }
            .disabled(items.allSatisfy(model.iPhone.contains))
    }
}
