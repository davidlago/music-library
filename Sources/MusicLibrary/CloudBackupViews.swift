import MusicLibraryCore
import SwiftUI

/// Settings ▸ iCloud (only in builds with an iCloud container): what's backed up, the status and Back Up Now.
struct ICloudSettings: View {
    @Environment(AppModel.self) private var model
    @State private var pendingScope: CloudBackupScope?
    @State private var confirmingReplace = false

    var body: some View {
        let cloud = model.cloud
        Form {
            Section {
                Picker("Back up", selection: Binding(get: { cloud.scope }, set: { choose($0) })) {
                    ForEach(CloudBackupScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(Self.explanation(cloud.scope)).font(.caption).foregroundStyle(.secondary)
                if cloud.scope == .chosen {
                    Toggle("Include what's on my iPhone", isOn: Binding(get: { cloud.includesIPhone }, set: { cloud.includesIPhone = $0 }))
                    if let estimate = cloud.estimate, estimate.iPhoneSongs > 0 {
                        Text("The iPhone list, with Owned Music on iPhone, comes to \(songCount(estimate.iPhoneSongs)), \(Self.bytes(estimate.iPhoneMusic)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Including it lets the iPhone download those songs from iCloud. Use Add to iCloud in the menus of albums, artists, playlists and songs to choose more, and see the list on the iCloud page.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show the iCloud Page") { model.sidebar = .iCloud }
                }
                if let estimate = cloud.estimate, cloud.scope != .off {
                    LabeledContent("Size", value: "About \(Self.bytes(estimate.bytes(cloud.scope)))")
                }
            } header: {
                Text("iCloud Backup")
            }
            Section("Restore") {
                Text("Get your library back as it was on a day the backup kept: into a new folder, with the music the backup holds, or just its database into the library that's open.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore from iCloud…") { model.restoreFromICloud() }
            }
            if cloud.scope != .off {
                Section("Status") {
                    ICloudStatus(cloud: cloud, confirmingReplace: $confirmingReplace)
                    Button("Back Up Now") { cloud.backUpNow() }.disabled(cloud.isPublishing)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(cloud.scope)|\(cloud.includesIPhone)|\(cloud.selection.rules.count)") {
            await cloud.refreshEstimate()
            while !Task.isCancelled {
                await cloud.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert(pendingScope.map(Self.confirmationTitle) ?? "", isPresented: Binding(get: { pendingScope != nil }, set: { if !$0 { pendingScope = nil } })) {
            Button("Back Up") { if let scope = pendingScope { cloud.scope = scope } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let scope = pendingScope { Text(confirmation(scope)) }
        }
        .alert("Replace the Backup in iCloud?", isPresented: $confirmingReplace) {
            Button("Replace", role: .destructive) { cloud.replaceOtherBackup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iCloud holds a backup of another library. Replacing it removes that library's database copies; covers, photos and music it shares with this library are overwritten.")
        }
    }

    /// Asks before the first backup and before backing up more music than now.
    private func choose(_ scope: CloudBackupScope) {
        let cloud = model.cloud
        let grows = scope.includesMusic && (cloud.estimate.map { $0.bytes(scope) > $0.bytes(cloud.scope) } ?? true)
        if scope != .off, cloud.scope == .off || grows {
            pendingScope = scope
        } else {
            cloud.scope = scope
        }
    }

    private static func confirmationTitle(_ scope: CloudBackupScope) -> String {
        scope.includesMusic ? "Back Up Music to iCloud?" : "Back Up to iCloud?"
    }

    private func confirmation(_ scope: CloudBackupScope) -> String {
        let cloud = model.cloud
        let iPhoneNote = cloud.includesIPhone ? cloud.estimate.map { ", including the \(songCount($0.iPhoneSongs)) on your iPhone's list" } ?? "" : ""
        let size = model.cloud.estimate.map { " (about \(Self.bytes($0.bytes(scope))))" } ?? ""
        let what = switch scope {
        case .chosen: "The library database, covers, artist photos and the music you choose\(iPhoneNote)\(size) go to your iCloud account. The music's files stay on this Mac too; iCloud's copies don't take extra space here."
        case .everything: "The library database, covers, artist photos and all your music\(size) go to your iCloud account; check that your iCloud plan has room. The music's files stay on this Mac too; iCloud's copies don't take extra space here."
        default: "The library database, covers and artist photos\(size) go to your iCloud account. Your music files stay on this Mac."
        }
        return what + "\n\nEarlier copies of the database are kept too: the last 10, one a day for two weeks and one a week for two months. A first music backup can take days; it goes on in the background."
    }

    static func explanation(_ scope: CloudBackupScope) -> String {
        let library = "The library database (songs, plays, likes, playlists and your physical collection), album and collection covers, and artist photos"
        let removed = " Music you take out of the backup stays in iCloud for 30 days before it's deleted."
        switch scope {
        case .off: return "Nothing goes to iCloud."
        case .library: return library + ". Your music files stay on this Mac."
        case .chosen: return library + ", plus the music you choose (switching from Everything starts with all of it)." + removed
        case .everything: return library + ", plus every song's file." + removed
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension CloudBackupScope {
    var title: String {
        switch self {
        case .off: "Off"
        case .library: "Library and covers"
        case .chosen: "Library, covers and chosen music"
        case .everything: "Everything"
        }
    }
}

/// The last backup, what's still uploading or waiting to be copied, and problems, with what to do about them.
struct ICloudStatus: View {
    let cloud: CloudBackupStore
    @Binding var confirmingReplace: Bool
    @State private var confirmingDelete = false

    var body: some View {
        if cloud.isPublishing {
            Label { Text("Backing up…") } icon: { ProgressView().controlSize(.small) }
        } else if let lastBackup = cloud.lastBackup {
            LabeledContent("Last backup") {
                // Redrawn on a timer: a relative date doesn't update itself.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(lastBackup, format: .relative(presentation: .named))
                }
            }
        } else {
            LabeledContent("Last backup", value: "Never")
        }
        if cloud.uploads.files > 0 {
            LabeledContent("Uploading", value: "\(cloud.uploads.files) \(cloud.uploads.files == 1 ? "file" : "files"), \(ICloudSettings.bytes(cloud.uploads.bytes))")
        }
        if cloud.remaining > 0 {
            LabeledContent("Still to back up", value: "\(cloud.remaining.formatted()) \(cloud.remaining == 1 ? "file" : "files"), next in about 15 minutes")
        }
        if cloud.snapshotCount > 0 {
            LabeledContent("Database copies", value: "\(cloud.snapshotCount)")
        }
        if cloud.awaitingDeletion.files > 0 {
            LabeledContent {
                HStack {
                    Text("\(cloud.awaitingDeletion.files.formatted()) \(cloud.awaitingDeletion.files == 1 ? "file" : "files"), \(ICloudSettings.bytes(cloud.awaitingDeletion.bytes))")
                    Button("Delete Now…") { confirmingDelete = true }.disabled(cloud.isPublishing)
                }
            } label: {
                Text("Waiting to be deleted")
                Text("Music no longer backed up stays in iCloud for 30 days, in case you change your mind.")
            }
            .alert("Delete It from iCloud Now?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { cloud.deleteRemovedNow() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("What the backup no longer holds (\(ICloudSettings.bytes(cloud.awaitingDeletion.bytes))) is deleted from iCloud now instead of after 30 days, freeing that space. It can't be restored from the backup afterwards. Your Mac's own files aren't touched.")
            }
        }
        if let error = cloud.uploads.error {
            Label(error, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
        }
        switch cloud.problem {
        case .signedOut:
            Label("Sign in to iCloud in System Settings to back up.", systemImage: "icloud.slash").foregroundStyle(.orange)
        case .otherLibrary(let mac, let date):
            VStack(alignment: .leading, spacing: 6) {
                Label("iCloud holds a backup of another library, from \(mac) (\(date.formatted(date: .abbreviated, time: .shortened))). Nothing was backed up.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack {
                    Button("Replace It…") { confirmingReplace = true }
                    Button("Turn Off Backup") { cloud.scope = .off }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

/// The iCloud page (sidebar, while the backup is "chosen music"): the albums, artists, playlists and songs chosen,
/// with what's kept out, and what the iPhone adds.
struct ICloudBackupView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<SyncSelection.Rule>()
    @State private var totalBytes: Int64?
    @State private var confirmingReplace = false

    var body: some View {
        let cloud = model.cloud
        let tracks = cloud.chosenTracks()
        let fromIPhone = cloud.includesIPhone ? cloud.iPhoneTracks().count : 0
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if cloud.scope != .chosen {
                    Label(cloud.scope == .everything ? "Every song is backed up, so this list doesn't change anything until the backup is set to chosen music in Settings ▸ iCloud."
                          : "Music isn't backed up. Choose \"Library, covers and chosen music\" in Settings ▸ iCloud to back up this list.",
                          systemImage: "info.circle").foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Form { ICloudStatus(cloud: cloud, confirmingReplace: $confirmingReplace) }.formStyle(.columns)
                    Spacer()
                    Button("Back Up Now", systemImage: "icloud.and.arrow.up") { cloud.backUpNow() }
                        .disabled(cloud.isPublishing || cloud.scope == .off)
                }
                Toggle("Include what's on my iPhone", isOn: Binding(get: { cloud.includesIPhone }, set: { cloud.includesIPhone = $0 }))
                    .help("Also back up the songs picked for your paired iPhones, so they can be downloaded from iCloud")
                if cloud.includesIPhone {
                    Text(model.iPhone.phones.isEmpty ? "No iPhone is paired." : "The iPhone list adds \(songCount(fromIPhone)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            Divider()
            if cloud.selection.isEmpty {
                ContentUnavailableView("Nothing Chosen Yet", systemImage: "icloud",
                                       description: Text("Add albums, artists, playlists or songs with Add to iCloud in their menus. Your library database, covers and artist photos are always backed up."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    // Newest first: a later rule decides over an earlier one.
                    ForEach(cloud.selection.rules.reversed()) { rule in
                        HStack {
                            ExportItemRow(item: rule.item)
                            if !rule.include {
                                Spacer()
                                Label("Kept out of iCloud", systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .opacity(rule.include ? 1 : 0.75)
                        .tag(rule)
                    }
                }
                .contextMenu(forSelectionType: SyncSelection.Rule.self) { rules in
                    if rules.allSatisfy({ !$0.include }) {
                        Button("Put Back in iCloud", systemImage: "plus.circle") { cloud.remove(rules) }
                    } else {
                        Button("Remove from iCloud List", systemImage: "minus.circle") { cloud.remove(rules) }
                    }
                }
                .onDeleteCommand { cloud.remove(selection) }
            }
            Divider()
            HStack {
                Text(songCount(tracks.count) + (totalBytes.map { " · " + ICloudSettings.bytes($0) } ?? "")).foregroundStyle(.secondary)
                Spacer()
                Text("Music taken off the list stays in iCloud for 30 days before it's deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .navigationTitle("iCloud")
        .task(id: tracks.map(\.id)) {
            let root = model.libraryRoot
            totalBytes = nil
            totalBytes = await Task.detached(priority: .utility) {
                tracks.reduce(Int64(0)) { $0 + ($1.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:)) ?? 0) }
            }.value
        }
        .task {
            while !Task.isCancelled {
                await cloud.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Replace the Backup in iCloud?", isPresented: $confirmingReplace) {
            Button("Replace", role: .destructive) { cloud.replaceOtherBackup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iCloud holds a backup of another library. Replacing it removes that library's database copies; covers, photos and music it shares with this library are overwritten.")
        }
    }
}

/// "Add to iCloud" for a context menu, while the backup is "chosen music"; "Remove from iCloud" once all of it is in.
struct AddToICloudButton: View {
    @Environment(AppModel.self) private var model
    let items: [ExportItem]

    var body: some View {
        let cloud = model.cloud
        if cloud.isAvailable, cloud.scope == .chosen {
            if items.allSatisfy(cloud.contains) {
                Button("Remove from iCloud", systemImage: "icloud.slash") { cloud.keepOut(items) }
            } else {
                Button("Add to iCloud", systemImage: "icloud.and.arrow.up") { cloud.add(items) }
            }
        }
    }
}
