import AppKit
import MusicLibraryCore
import SwiftUI

/// Settings ▸ iCloud (only in builds with an iCloud container): what's backed up, the status and Back Up Now.
struct ICloudSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingScope = false
    @State private var confirmingReplace = false

    var body: some View {
        let cloud = model.cloud
        Form {
            Section {
                Picker("Back up", selection: Binding(get: { cloud.scope }, set: { choose($0) })) {
                    Text("Off").tag(CloudBackupScope.off)
                    Text("Library and covers").tag(CloudBackupScope.library)
                }
                Text("The library database (songs, plays, likes, playlists and your physical collection), album and collection covers, and artist photos. Your music files stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let estimate = cloud.estimate {
                    LabeledContent("Size", value: "About \(Self.bytes(estimate))")
                }
            } header: {
                Text("iCloud Backup")
            }
            if cloud.scope != .off {
                Section("Status") {
                    status(cloud)
                    HStack {
                        Button("Back Up Now") { cloud.backUpNow() }.disabled(cloud.isPublishing)
                        if let folder = cloud.folder {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await cloud.refreshEstimate()
            while !Task.isCancelled {
                await cloud.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Back Up to iCloud?", isPresented: $confirmingScope) {
            Button("Back Up") { cloud.scope = .library }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The library database, covers and artist photos\(cloud.estimate.map { " (about \(Self.bytes($0)))" } ?? "") go to your iCloud account. Your music files stay on this Mac.\n\nEarlier copies of the database are kept too: the last 10, one a day for two weeks and one a week for two months.")
        }
        .alert("Replace the Backup in iCloud?", isPresented: $confirmingReplace) {
            Button("Replace", role: .destructive) { cloud.replaceOtherBackup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iCloud holds a backup of another library. Replacing it removes that library's database copies; covers and photos it shares with this library are overwritten.")
        }
    }

    private func choose(_ scope: CloudBackupScope) {
        if scope != .off, model.cloud.scope == .off, model.cloud.lastBackup == nil {
            confirmingScope = true
        } else {
            model.cloud.scope = scope
        }
    }

    @ViewBuilder
    private func status(_ cloud: CloudBackupStore) -> some View {
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
            LabeledContent("Uploading", value: "\(cloud.uploads.files) \(cloud.uploads.files == 1 ? "file" : "files"), \(Self.bytes(cloud.uploads.bytes))")
        }
        if cloud.snapshotCount > 0 {
            LabeledContent("Database copies", value: "\(cloud.snapshotCount)")
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

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
