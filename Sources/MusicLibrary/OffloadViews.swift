import MusicLibraryCore
import SwiftUI

/// Where a song's, album's or list's music is: a struck-through cloud when it's only in iCloud (it downloads when
/// played) or some of it is, like the not-digitized badge, an arrow while it downloads. Nothing when it's all on this
/// Mac.
struct ICloudMark: View {
    enum Placement: Equatable {
        case onMac
        case partly
        case iCloudOnly
        case downloading
    }

    let placement: Placement

    var body: some View {
        Group {
            switch placement {
            case .onMac:
                EmptyView()
            case .partly:
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .help("Some songs not on this Mac: in iCloud only, they download when you play them")
                    .accessibilityLabel("Partly in iCloud only")
            case .iCloudOnly:
                Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                    .help("Not on this Mac: in iCloud only, downloads when you play it")
                    .accessibilityLabel("In iCloud only")
            case .downloading:
                Image(systemName: "arrow.down.circle.dotted").foregroundStyle(AppColor.accent)
                    .help("Downloading from iCloud")
                    .accessibilityLabel("Downloading from iCloud")
            }
        }
        .font(.caption)
    }
}

extension OffloadStore {
    /// Where these songs' music is, for `ICloudMark`.
    func placement(_ songs: [Track]) -> ICloudMark.Placement {
        var inCloud = 0
        for song in songs where offloaded[song.id] != nil {
            if downloading.contains(song.id) { return .downloading }
            inCloud += 1
        }
        return inCloud == 0 ? .onMac : inCloud == songs.count ? .iCloudOnly : .partly
    }
}

/// Offload from This Mac, Download to This Mac and Keep on This Mac for a context menu (next to Add to iCloud).
struct OffloadButtons: View {
    @Environment(AppModel.self) private var model
    let items: [ExportItem]

    var body: some View {
        let offload = model.offload, cloud = model.cloud
        if cloud.isAvailable {
            if items.contains(where: offload.isOffloaded) {
                Button("Download to This Mac", systemImage: "icloud.and.arrow.down") { offload.download(items) }
            }
            if cloud.scope.includesMusic {
                if !items.allSatisfy(offload.isAllOffloaded) {
                    Button("Offload from This Mac", systemImage: "icloud") { offload.offload(items) }
                }
                if items.allSatisfy(offload.isKept) {
                    Button("Don't Keep on This Mac", systemImage: "pin.slash") { offload.keep(items, false) }
                } else {
                    Button("Keep on This Mac", systemImage: "pin") { offload.keep(items, true) }
                }
            }
        }
    }
}

/// The album page's line about songs only in iCloud, with Download to This Mac.
struct AlbumOffloadNote: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let offload = model.offload
        let inCloud = tracks.filter(offload.isOffloaded)
        if !inCloud.isEmpty {
            HStack(spacing: 8) {
                ICloudMark(placement: inCloud.count == tracks.count ? .iCloudOnly : .partly)
                Text(inCloud.count == tracks.count ? "In iCloud only" : "\(inCloud.count) of \(tracks.count) songs in iCloud only")
                    .font(.callout).foregroundStyle(.secondary)
                if !offload.downloading.isDisjoint(with: inCloud.map(\.id)) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download to This Mac") { offload.download(tracks: inCloud) }
                    .buttonStyle(.link)
                }
            }
        }
    }
}

extension View {
    /// Asks before Offload Now, and before the first offload by hand (iCloud holds the only copy then, D18e); shows
    /// what went wrong. Shown once, by `ContentView`.
    func offloadConfirmation(_ model: AppModel) -> some View {
        let offload = model.offload
        return alert(offload.confirmation.map { Self.offloadTitle($0) } ?? "",
                     isPresented: Binding(get: { model.offload.confirmation != nil }, set: { if !$0 { model.offload.confirmation = nil } }),
                     presenting: offload.confirmation) { confirmation in
            if confirmation.plan.albums.isEmpty {
                Button("OK", role: .cancel) {}
            } else {
                Button("Offload") { offload.run(confirmation.plan) }
                Button("Cancel", role: .cancel) {}
            }
        } message: { confirmation in
            Text(Self.offloadMessage(confirmation, threshold: offload.threshold, firstTime: !offload.hasExplained))
        }
        .alert("iCloud", isPresented: Binding(get: { model.offload.lastError != nil }, set: { if !$0 { model.offload.lastError = nil } })) {
            Button("OK") { offload.lastError = nil }
        } message: { Text(offload.lastError ?? "") }
    }

    private static func offloadTitle(_ confirmation: OffloadStore.Confirmation) -> String {
        if confirmation.plan.albums.isEmpty { return "Nothing to Offload" }
        return confirmation.isAutomatic ? "Offload \(albumCount(confirmation.plan.albums.count)) from This Mac?" : "Offload from This Mac?"
    }

    private static func albumCount(_ n: Int) -> String { "\(n.formatted()) \(n == 1 ? "Album" : "Albums")" }

    static func offloadMessage(_ confirmation: OffloadStore.Confirmation, threshold: OffloadThreshold, firstTime: Bool) -> String {
        let plan = confirmation.plan
        guard !plan.albums.isEmpty else {
            return "Every album was played, added or downloaded in the last \(threshold.period), is kept on this Mac, is playing or queued, or isn't in the iCloud backup yet."
        }
        let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
        let what = confirmation.isAutomatic
            ? "\(plan.albums.count.formatted()) \(plan.albums.count == 1 ? "album" : "albums") not played in the last \(threshold.period) leave this Mac, about \(size)."
            : "\(plan.songs.formatted()) \(plan.songs == 1 ? "song" : "songs") leave this Mac, about \(size)."
        var message = what + " They stay in your library and download from iCloud when you play them."
        if firstTime { message += "\n\n" + OffloadStore.onlyCopyNote }
        return message
    }
}

extension OffloadStore {
    /// The first offload says this (D18e).
    static let onlyCopyNote = "Once offloaded, a song's only copy is in iCloud: there's no second copy on this Mac anymore. Export your music to a drive now and then (File ▸ Export List) to keep one."
}

extension OffloadThreshold {
    var title: String {
        switch self {
        case .off: "Off"
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "1 year"
        }
    }

    /// "3 months", for "not played in the last …".
    var period: String {
        switch self {
        case .off, .oneMonth: "month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .oneYear: "year"
        }
    }
}

/// Settings ▸ iCloud's offloading section (D19): the automatic setting, what's where, and Offload Now.
struct OffloadSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var pendingThreshold: OffloadThreshold?

    var body: some View {
        let offload = model.offload, cloud = model.cloud
        Section {
            Picker("Offload music not played in", selection: Binding(get: { offload.threshold }, set: { choose($0) })) {
                ForEach(OffloadThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!cloud.scope.includesMusic && offload.threshold == .off)
            if cloud.scope.includesMusic {
                Text("Albums not played in that time leave this Mac once they're in the backup, and download from iCloud when you play them. Albums you mark Keep on This Mac, and what's playing or queued, stay. Use Offload from This Mac and Download to This Mac in the menus of albums, artists, playlists and songs to choose yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Offloading needs the backup to hold your music: choose Everything, or chosen music for what you'd offload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("On this Mac", value: songCount(max(0, model.tracks.count - offload.offloaded.count)))
            if !offload.offloaded.isEmpty {
                LabeledContent("In iCloud only") {
                    HStack {
                        Text("\(songCount(offload.offloaded.count)), \(ICloudSettings.bytes(offload.offloadedBytes))")
                        Button("Download All to This Mac") { offload.download([.library]) }
                            .disabled(!offload.downloading.isEmpty)
                            .help("Bring every offloaded song back, before going back to a version without offloading, say")
                    }
                }
            }
            if let progress = offload.downloadProgress {
                LabeledContent("Downloading") {
                    HStack {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 120)
                        Text("\(progress.done) of \(progress.total)").monospacedDigit()
                    }
                }
            }
            HStack {
                Button("Offload Now…") { offload.offloadNow() }
                    .disabled(offload.threshold == .off || offload.isOffloading || !cloud.scope.includesMusic)
                if offload.isOffloading { ProgressView().controlSize(.small) }
                if let lastRun = offload.lastRun {
                    Text("Last checked \(lastRun.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Offloading from This Mac")
        }
        .alert("Offload Music Automatically?", isPresented: Binding(get: { pendingThreshold != nil }, set: { if !$0 { pendingThreshold = nil } })) {
            Button("Offload Automatically") {
                if let threshold = pendingThreshold {
                    offload.hasExplained = true
                    offload.threshold = threshold
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Albums not played in the last \(pendingThreshold?.period ?? "") leave this Mac after a backup, at most once a day, and download from iCloud when you play them.\n\n" + OffloadStore.onlyCopyNote)
        }
    }

    private func choose(_ threshold: OffloadThreshold) {
        if threshold != .off, !model.offload.hasExplained { pendingThreshold = threshold } else { model.offload.threshold = threshold }
    }
}

/// Set Up from iCloud (D21): a Mac with an empty library that finds a backup in iCloud can make that library its own.
struct ICloudSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cloud = model.cloud
        VStack(alignment: .leading, spacing: 14) {
            Label("Set Up from iCloud", systemImage: "icloud.and.arrow.down").font(.title2.weight(.semibold))
            if let backup = cloud.setupBackup {
                Text("iCloud holds the library from \(backup.macName), backed up \(backup.snapshotAt.formatted(date: .abbreviated, time: .shortened)): \(songCount(backup.tracks)).")
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Move My Library to This Mac").font(.headline)
                        Text("Your songs, plays, likes, playlists and physical collection come to this Mac, with the covers and artist photos. The music stays in iCloud and downloads when you play it, or with Download to This Mac on what you choose. This Mac backs the library up from now on, and \(backup.macName) stops backing it up.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            } else if cloud.moving == nil {
                Text("There's no library in iCloud to set this Mac up from.").foregroundStyle(.secondary)
            }
            if let moving = cloud.moving {
                ProgressView(value: Double(moving.done), total: Double(max(1, moving.total))) {
                    Text(moving.total == 0 ? "Getting the library…" : "Bringing down covers and photos: \(moving.done) of \(moving.total)")
                }
            }
            if let error = cloud.moveError {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(cloud.setupBackup == nil && cloud.moving == nil ? "Done" : "Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(cloud.moving != nil)
                if cloud.setupBackup != nil {
                    Button("Move to This Mac") { cloud.moveHere() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(cloud.moving != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: cloud.moving == nil) { _, done in
            if done, cloud.moveError == nil, cloud.setupBackup == nil { dismiss() }
        }
    }
}
