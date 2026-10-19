import MusicLibraryCore
import SwiftUI

/// The iPhone page: paired phones (and ones nearby asking to pair), the list the phone keeps (with what's been
/// taken off it, here or on the phone), and syncing it.
struct IPhoneSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<SyncSelection.Rule>()
    @State private var codes: [String: String] = [:]
    @State private var totalBytes: Int64?

    var body: some View {
        let store = model.iPhone
        // The list and what each phone's Collection on iPhone adds (with several phones, what any of them gets).
        let tracks = model.iPhoneTracks()
        VStack(spacing: 0) {
            phones(store, total: tracks.count)
            Divider()
            if store.selection.isEmpty {
                ContentUnavailableView(store.phones.contains { store.collectionScope(for: $0) != .off } ? "Nothing Else on the List" : "Nothing to Sync Yet",
                                       systemImage: "iphone",
                                       description: Text("Add albums, artists, playlists or songs with Add to iPhone in their menus, or tap Download on the iPhone. The iPhone keeps exactly this list, plus the digital copies its Owned Music on iPhone setting adds. Everything you own is always listed on the iPhone, with its covers."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    // Newest first: rules are added (and re-added) at the end, and a later one decides over an earlier one.
                    ForEach(store.selection.rules.reversed()) { rule in
                        HStack {
                            ExportItemRow(item: rule.item)
                            if !rule.include {
                                Spacer()
                                Label("Kept off the iPhone", systemImage: "minus.circle").font(.caption).foregroundStyle(.subtext)
                            }
                        }
                        .opacity(rule.include ? 1 : 0.75)
                        .tag(rule)
                    }
                }
                .contextMenu(forSelectionType: SyncSelection.Rule.self) { rules in
                    if rules.allSatisfy({ !$0.include }) {
                        Button("Put Back on iPhone", systemImage: "plus.circle") { store.remove(rules) }
                    } else {
                        Button("Remove from iPhone List", systemImage: "minus.circle") { store.remove(rules) }
                    }
                }
                .onDeleteCommand { store.remove(selection) }
                .themedScrollBackground()
            }
            Divider()
            HStack {
                Text(footer(songs: tracks.count)).foregroundStyle(.subtext)
                Spacer()
                Text("The iPhone keeps exactly this list: what you remove here is removed from it at the next sync. Downloads and removals made on the iPhone show up here too.")
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
    /// `total`: the songs any phone gets, which is the one phone's when there's only one.
    private func phones(_ store: SyncStore, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.phones) { phone in
                phoneRow(phone, store: store, songs: store.phones.count == 1 ? total : model.iPhoneTracks(for: phone).count)
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

    /// `songs`: what the list and its Collection on iPhone put on this phone.
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
                    Text("Sync from the iPhone, or open its Sync tab to sync from here.").font(.caption).foregroundStyle(.subtext)
                }
                if let date = phone.lastSync {
                    (Text("Last synced ") + Text(date, style: .relative) + Text(" ago" + (phone.lastSummary.map { ": " + summaryText($0) } ?? "")))
                        .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                }
                CollectionOnIPhoneRow(phone: phone, store: store)
            }
            Spacer()
            if case .syncing(phone.id, let progress) = store.activity {
                ProgressView(value: progress.fraction).frame(width: 160)
                Button("Cancel") { store.cancel() }
            } else {
                // A collection goes to the phone even with no songs (its items and covers).
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.syncIPhone(phone) }
                    .disabled(peer == nil || store.isBusy || (songs == 0 && model.collection.items.isEmpty))
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
        let scoped = model.iPhone.phones.contains { model.iPhone.collectionScope(for: $0) != .off }
        return "\(songs) \(songs == 1 ? "song" : "songs")\(size)\(scoped ? " with Owned Music on iPhone" : "")"
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
        if let n = s.purchases, n > 0 { parts.append("\(n) owned \(n == 1 ? "album" : "albums") updated") }
        if s.missing > 0 { parts.append("\(s.missing) missing here") }
        return parts.joined(separator: ", ")
    }
}

/// Owned Music on iPhone for one phone: Off, the digital copies of your CDs, of your records, or of everything you
/// own, added to its list (Remove from iPhone still wins; new rips join at the next sync), and what that
/// comes to: "Digital copies of 330 of your 399 CDs: 4,210 songs, 98 GB".
struct CollectionOnIPhoneRow: View {
    @Environment(AppModel.self) private var model
    let phone: SyncStore.PairedPhone
    let store: SyncStore
    @State private var bytes: Int64?

    var body: some View {
        let scope = store.collectionScope(for: phone)
        let songs = scope == .off ? [] : songs(scope)
        HStack(spacing: 8) {
            Picker("Owned Music on iPhone", selection: Binding(get: { scope }, set: { store.setCollectionScope($0, for: phone) })) {
                ForEach(CollectionSyncScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .controlSize(.small)
            .help("Also put the digital copies of what you own on this iPhone, besides the list below")
            if let summary = summary(scope, songs: songs.count) {
                Text(summary).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            }
        }
        .padding(.top, 2)
        .task(id: "\(scope.rawValue)|\(model.libraryVersion)|\(model.collectionVersion)") {
            let root = model.libraryRoot, list = songs
            bytes = nil
            guard !list.isEmpty else { return }
            bytes = await Task.detached(priority: .utility) {
                list.reduce(Int64(0)) { $0 + ($1.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0) }
            }.value
        }
    }

    /// The songs the scope adds, each once.
    private func songs(_ scope: CollectionSyncScope) -> [Track] {
        var seen = Set<Int64>()
        return model.collection.syncItems(scope).flatMap(model.tracks(for:)).filter { seen.insert($0.id).inserted }
    }

    private func summary(_ scope: CollectionSyncScope, songs: Int) -> String? {
        let items: [CollectionItem]
        let noun: String
        switch scope {
        case .off: return nil
        case .cds: items = model.collection.items.filter { $0.medium == .cd }; noun = "CDs"
        case .vinyl: items = model.collection.items.filter { $0.medium == .vinyl }; noun = "records"
        case .all: items = model.collection.items; noun = "CDs, records and downloads"
        }
        let digitized = items.filter { model.collection.digitalState($0).hasMusic }.count
        let size = bytes.map { ", " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return "Digital copies of \(digitized.formatted()) of your \(items.count.formatted()) \(noun): \(songCount(songs))\(size)"
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
