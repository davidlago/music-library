import AppKit
import MusicLibraryCore
import SwiftUI

/// Restore from iCloud… (File menu, Settings ▸ iCloud): the backup's database copies, newest first, restored into a
/// new folder (music, covers and photos with it) or, the database alone, into the open library. Also reads a backup
/// folder copied out by hand.
struct ICloudRestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case loading
        case ready
        case restoring(done: Int, of: Int)
        case restoredFolder(URL, CloudRestoreResult)
        case restoredDatabase(before: URL)
        case failed(String)
    }

    @State private var store: FolderCloudStore?
    @State private var snapshots: [CloudSnapshotListing] = []
    @State private var details: [String: CloudSnapshotDetails] = [:]
    @State private var selection: String?
    @State private var phase = Phase.loading
    @State private var confirmingDatabase = false
    @State private var work: Task<Void, Never>?
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-Restore", isDirectory: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore from iCloud").font(.title2.bold())
                Text(store.map { $0.coordinated ? "Copies of your library's database in iCloud, newest first." : "The backup in \($0.root.path)." }
                     ?? "Copies of your library's database in iCloud, newest first.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(20)
        .frame(width: 600, height: 460)
        .interactiveDismissDisabled(isRestoring)
        .task { await load(nil) }
        .onDisappear { work?.cancel() }
        .alert("Restore the Database Only?", isPresented: $confirmingDatabase) {
            Button("Restore", role: .destructive) { restoreDatabase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This library's songs, plays, likes, playlists and physical collection go back to how they were \(selectedDate.map { "on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "then"). The current database is kept in the library folder as library-before-restore-….sqlite. Music files aren't touched; songs whose files aren't there show as missing.")
        }
    }

    private var isRestoring: Bool {
        if case .restoring = phase { return true }
        return false
    }

    private var selectedDate: Date? { snapshots.first { $0.path == selection }?.date }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("Can't Restore", systemImage: "exclamationmark.icloud", description: Text(message))
        case .restoring(let done, let total):
            VStack(spacing: 10) {
                ProgressView(value: total == 0 ? 0 : Double(done), total: Double(max(total, 1))).frame(width: 340)
                Text(total == 0 ? "Copying the database…" : "Copying \(done.formatted()) of \(total.formatted()) files…")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Files only in iCloud are downloaded first.").font(.caption).foregroundStyle(.tertiary)
            }
        case .restoredFolder(let root, let result):
            ContentUnavailableView {
                Label("Library Restored", systemImage: "checkmark.icloud")
            } description: {
                Text("\(result.files.formatted()) files (\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))) and the database are in \(root.lastPathComponent)."
                     + (result.missing.isEmpty ? "" : " \(result.missing.count.formatted()) songs and covers weren't in the backup and show as missing."))
            } actions: {
                Button("Open Restored Library") {
                    model.setLibraryRoot(root)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .restoredDatabase(let before):
            ContentUnavailableView {
                Label("Database Restored", systemImage: "checkmark.icloud")
            } description: {
                Text("The database from before is kept as \(before.lastPathComponent) in the library folder.")
            } actions: {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([before]) }
            }
        case .ready:
            if snapshots.isEmpty {
                ContentUnavailableView("No Backups Yet", systemImage: "icloud",
                                       description: Text(store?.coordinated == false ? "That folder doesn't hold a backup: it should have backup.json and a Snapshots folder."
                                                         : "Turn on the backup in Settings ▸ iCloud first."))
            } else {
                List(snapshots, selection: $selection) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.date.formatted(date: .complete, time: .shortened))
                            Text(summary(details[snapshot.path])).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snapshot.isCurrent { Text("Latest").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(snapshot.path)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if case .ready = phase {
                Button("Use a Backup Folder…") { chooseBackupFolder() }
                    .help("A copy of the backup's Music Library folder, for example on another disk")
            } else if case .failed = phase {
                Button("Use a Backup Folder…") { chooseBackupFolder() }
            }
            Spacer()
            switch phase {
            case .restoring:
                Button("Cancel") { work?.cancel() }
            case .ready:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore Database Only…") { confirmingDatabase = true }
                    .disabled(selection == nil || model.database == nil || model.cloud.isPublishing)
                    .help("Put this copy's database in place of the open library's, keeping your music files")
                Button("Restore to New Folder…") { restoreToFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            default:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ details: CloudSnapshotDetails?) -> String {
        guard let details else { return "Reading…" }
        var parts: [String] = []
        if let n = details.tracks { parts.append(songCount(n)) }
        if let n = details.items, n > 0 { parts.append("\(n.formatted()) in your physical collection") }
        if let n = details.plays, n > 0 { parts.append("\(n.formatted()) \(n == 1 ? "play" : "plays")") }
        if let n = details.likes, n > 0 { parts.append("\(n.formatted()) liked") }
        return parts.isEmpty ? "Can't be read" : parts.joined(separator: " · ")
    }

    // MARK: Loading

    /// The backup in iCloud, or (`folder`) one copied out by hand.
    private func load(_ folder: URL?) async {
        phase = .loading
        snapshots = []; details = [:]; selection = nil
        let found: FolderCloudStore?
        if let folder {
            found = try? FolderCloudStore(root: folder)
        } else {
            found = await model.cloud.backupStore()
        }
        guard let found else {
            phase = .failed(FileManager.default.ubiquityIdentityToken == nil ? "Sign in to iCloud in System Settings to restore from it."
                            : "The backup in iCloud can't be reached right now.")
            return
        }
        store = found
        do {
            snapshots = try await Task.detached(priority: .userInitiated) { try CloudRestore.snapshots(in: found) }.value
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        selection = snapshots.first?.path
        phase = .ready
        let scratch = scratch
        for snapshot in snapshots {
            guard !Task.isCancelled else { return }
            let read = try? await Task.detached(priority: .utility) {
                try await CloudRestore.details(of: snapshot.path, in: found, scratch: scratch)
            }.value
            details[snapshot.path] = read ?? CloudSnapshotDetails()
        }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Backup"
        panel.message = "Choose a copy of the backup's Music Library folder (it holds backup.json and Snapshots)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work?.cancel()
        work = Task { await load(url) }
    }

    // MARK: Restoring

    private func restoreToFolder() {
        guard let store, let snapshot = selection else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        panel.message = "Choose an empty folder for the restored library. Your current library isn't touched."
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let target = root.standardizedFileURL.path + "/"
        for used in [model.libraryRoot, store.root] where target.hasPrefix(used.standardizedFileURL.path + "/")
            || (used.standardizedFileURL.path + "/").hasPrefix(target) {
            phase = .failed("Choose a folder outside your library and the backup.")
            return
        }
        phase = .restoring(done: 0, of: 0)
        let scratch = scratch
        work = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await CloudRestore.restore(snapshot, from: store, to: root, scratch: scratch) { done, total in
                        Task { @MainActor in if case .restoring = phase { phase = .restoring(done: done, of: total) } }
                    }
                }.value
                phase = .restoredFolder(root, result)
            } catch is CancellationError {
                phase = .failed("The restore was cancelled. \(root.lastPathComponent) holds what was copied so far, without the database; choose an empty folder to start again.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func restoreDatabase() {
        guard let store, let snapshot = selection, let database = model.database else { return }
        let root = model.libraryRoot, scratch = scratch
        phase = .restoring(done: 0, of: 0)
        work = Task {
            do {
                let before = try await Task.detached(priority: .userInitiated) {
                    try await CloudRestore.restoreDatabase(snapshot, from: store, into: database, root: root, scratch: scratch)
                }.value
                model.databaseRestored()
                phase = .restoredDatabase(before: before)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
