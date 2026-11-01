import Foundation
import MusicLibraryCore

/// The iCloud backup (`docs/icloud-plan.md` §5): what to back up (user defaults `iCloudBackupScope`; with "chosen
/// music", the list in `iCloudBackupSelection` and `iCloudBackupIncludesIPhone`, D15), when (two minutes after the
/// library last changed, at most every 15 minutes, again after a publish that didn't finish, and Back Up Now), and its
/// status. Hidden in builds without an iCloud container (`isAvailable`).
@MainActor @Observable
final class CloudBackupStore {
    private enum Keys {
        static let scope = "iCloudBackupScope"
        static let lastBackup = "iCloudLastBackup"
        /// The last publish failed or didn't finish, so one runs soon after launch.
        static let pending = "iCloudBackupPending"
        static let selection = "iCloudBackupSelection"
        static let includesIPhone = "iCloudBackupIncludesIPhone"
    }

    /// About how much each scope puts in iCloud.
    struct Estimate: Equatable {
        var library: Int64
        var chosenMusic: Int64
        var allMusic: Int64
        /// What the iPhone list puts on the paired phones, whether or not it's included.
        var iPhoneSongs: Int
        var iPhoneMusic: Int64

        func bytes(_ scope: CloudBackupScope) -> Int64 {
            switch scope {
            case .off: 0
            case .library: library
            case .chosen: library + chosenMusic
            case .everything: library + allMusic
            }
        }
    }

    enum Problem: Equatable {
        case signedOut
        case otherLibrary(macName: String, snapshotAt: Date)
        case failed(String)
    }

    /// What iCloud still has to upload, and why it can't when it says.
    struct Uploads: Equatable {
        var files = 0
        var bytes: Int64 = 0
        var error: String?
    }

    let containerID = CloudContainer.identifier()
    var isAvailable: Bool { containerID != nil }

    var scope: CloudBackupScope {
        didSet {
            UserDefaults.standard.set(scope.rawValue, forKey: Keys.scope)
            guard scope != oldValue else { return }
            stopCopying()
            problem = nil
            if scope != .off { needsPublish = true; lastChange = .distantPast }
        }
    }
    private(set) var lastBackup: Date? {
        didSet { UserDefaults.standard.set(lastBackup, forKey: Keys.lastBackup) }
    }
    private(set) var isPublishing = false
    private(set) var problem: Problem?
    private(set) var uploads = Uploads()
    private(set) var snapshotCount = 0
    /// Files the last publish didn't get to copy into iCloud (a first music backup spans many).
    private(set) var remaining = 0
    private(set) var estimate: Estimate?
    /// The chosen music: albums, artists, playlists and songs, each added or kept out (like the iPhone list).
    private(set) var selection: SyncSelection {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: Keys.selection)
            if scope == .chosen { stopCopying(); filesChanged() }
        }
    }
    /// With "chosen music", also what's picked for the paired iPhones, so the phone can download it from iCloud.
    var includesIPhone: Bool {
        didSet {
            UserDefaults.standard.set(includesIPhone, forKey: Keys.includesIPhone)
            if scope == .chosen { stopCopying(); filesChanged() }
        }
    }

    /// The open library; nil while none is.
    @ObservationIgnored var context: () -> (root: URL, database: Database)? = { nil }
    /// An item's songs as they are now, every song in the library, and what the iPhone list puts on the paired phones
    /// (none without one).
    @ObservationIgnored var tracks: (ExportItem) -> [Track] = { _ in [] }
    @ObservationIgnored var allTracks: () -> [Track] = { [] }
    @ObservationIgnored var iPhoneTracks: () -> [Track] = { [] }
    /// Applies Download / Remove requests a phone sent through iCloud; false when the iPhone list can't take them yet
    /// (the collection is still loading), so the batch waits.
    @ObservationIgnored var applyRequests: (_ phoneID: String, _ requests: [SyncRequest], _ sent: Date) -> Bool = { _, _, _ in true }
    /// A phone's plays or likes are in the library now.
    @ObservationIgnored var onPhoneChanges: () -> Void = {}
    @ObservationIgnored private var readingInbox = false
    @ObservationIgnored var identity: () -> CloudBackupIdentity = { CloudBackupIdentity(macID: "", macName: "Mac", appVersion: AppInfo.version) }
    @ObservationIgnored private var store: FolderCloudStore?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var needsPublish: Bool {
        didSet { UserDefaults.standard.set(needsPublish, forKey: Keys.pending) }
    }
    @ObservationIgnored private var replacingOther = false
    /// The publish running now, cancelled when what's backed up changes (it stops copying music it no longer should).
    @ObservationIgnored private var running: Task<CloudBackupResult, Error>?
    /// The database's change count when last seen and when the last publish started, and which database it was.
    @ObservationIgnored private var seenChanges = 0
    @ObservationIgnored private var publishedChanges = 0
    @ObservationIgnored private var database: ObjectIdentifier?
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var lastPublish = Date.distantPast

    static let quietPeriod: TimeInterval = 120
    static let minimumInterval: TimeInterval = 15 * 60

    init() {
        let defaults = UserDefaults.standard
        scope = defaults.string(forKey: Keys.scope).flatMap(CloudBackupScope.init(rawValue:)) ?? .off
        lastBackup = defaults.object(forKey: Keys.lastBackup) as? Date
        needsPublish = defaults.bool(forKey: Keys.pending)
        selection = defaults.data(forKey: Keys.selection).flatMap { try? JSONDecoder().decode(SyncSelection.self, from: $0) } ?? SyncSelection()
        // Off unless asked for: "chosen music" means what you chose, and the iPhone's list can be most of the library.
        includesIPhone = defaults.bool(forKey: Keys.includesIPhone)
    }

    // MARK: Chosen music

    /// Stops the music a running publish is copying; the next one (soon, since something changed) backs up the new
    /// choice and lists what's no longer wanted for removal.
    private func stopCopying() { running?.cancel() }

    /// The iPhone's songs, as rules before the list's own, so a song kept out of iCloud stays out.
    private var implicit: [ExportItem] { includesIPhone ? iPhoneTracks().map { .track($0.id) } : [] }

    /// The songs "chosen music" backs up, each once.
    func chosenTracks() -> [Track] { selection.resolve(tracks, implicit: implicit) }

    /// The songs the scope backs up.
    func music() -> [Track] {
        switch scope {
        case .off, .library: []
        case .chosen: chosenTracks()
        case .everything: allTracks()
        }
    }

    func add(_ items: [ExportItem]) {
        let implicit = implicit
        for item in items { selection.apply(item, include: true, tracks: { Set(self.tracks($0).map(\.id)) }, implicit: implicit) }
    }

    /// Keeps the items' songs out of iCloud, even where an artist, playlist or the iPhone puts them in.
    func keepOut(_ items: [ExportItem]) {
        let implicit = implicit
        for item in items { selection.apply(item, include: false, tracks: { Set(self.tracks($0).map(\.id)) }, implicit: implicit) }
    }

    /// Deletes rules from the list (a kept-out one deleted puts its songs back).
    func remove(_ rules: Set<SyncSelection.Rule>) { selection.rules.removeAll { rules.contains($0) } }

    func contains(_ item: ExportItem) -> Bool { selection.contains(item, tracks: tracks, implicit: implicit) }

    /// Drops albums, artists and songs that left the library. Only with a library loaded.
    func dropMissing() {
        guard !allTracks().isEmpty else { return }
        var pruned = selection
        pruned.dropMissing(tracks: { Set(self.tracks($0).map(\.id)) }, implicit: implicit)
        if pruned != selection { selection = pruned }
    }

    /// Starts watching the library for changes (every 30 s; the database counts its own).
    func start() {
        guard isAvailable, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Files changed that the database doesn't record, such as an album's new cover.
    func filesChanged() {
        needsPublish = true
        lastChange = Date()
    }

    private func tick() {
        readInbox()
        guard scope != .off, !isPublishing, let context = context() else { return }
        let id = ObjectIdentifier(context.database)
        if database != id {
            // Another library opened (or the first one): it may never have been backed up.
            if database != nil { needsPublish = true; lastChange = Date() }
            database = id
            seenChanges = context.database.changeCount
            publishedChanges = seenChanges
        }
        let changes = context.database.changeCount
        if changes != seenChanges { seenChanges = changes; lastChange = Date() }
        guard needsPublish || changes != publishedChanges else { return }
        let now = Date()
        guard now.timeIntervalSince(lastChange) >= Self.quietPeriod, now.timeIntervalSince(lastPublish) >= Self.minimumInterval else { return }
        publish()
    }

    func backUpNow() { publish() }

    // MARK: Inbox

    /// Applies what phones sent through iCloud (P6): plays and likes as a Wi-Fi sync does (each once, only from this
    /// library), and Download / Remove requests from paired phones; then deletes each batch. Also while publishing.
    private func readInbox() {
        guard scope != .off, !readingInbox, let context = context() else { return }
        readingInbox = true
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-Inbox", isDirectory: true)
        Task {
            defer { readingInbox = false }
            guard let store = await backupStore(),
                  let batches = try? await Task.detached(priority: .utility, operation: { try await CloudInbox.pending(in: store, scratch: scratch) }).value,
                  !batches.isEmpty else { return }
            var changed = false
            for (path, batch) in batches {
                if let batch {
                    if let result = try? context.database.applySyncEvents(batch.events, libraryID: batch.libraryID),
                       result.plays + result.likes + result.purchases > 0 {
                        changed = true
                    }
                    if !batch.requests.isEmpty, batch.libraryID == context.database.libraryID(),
                       !applyRequests(batch.phoneID, batch.requests, batch.writtenAt) {
                        continue
                    }
                }
                try? store.remove(path)
            }
            if changed { onPhoneChanges() }
        }
    }

    /// Replaces another library's backup with this one (asked first).
    func replaceOtherBackup() {
        replacingOther = true
        publish()
    }

    private func publish() {
        guard let containerID, scope != .off, !isPublishing, let context = context() else { return }
        isPublishing = true
        problem = nil
        let changes = context.database.changeCount
        let scope = scope, identity = identity(), replacing = replacingOther, music = music()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-iCloud", isDirectory: true)
        let known = store
        Task {
            defer { isPublishing = false }
            lastPublish = Date()
            guard let store = await Self.resolve(known, containerID: containerID) else {
                problem = .signedOut
                needsPublish = true
                return
            }
            self.store = store
            do {
                let run = Task.detached(priority: .utility) {
                    try await CloudBackup.publish(database: context.database, root: context.root, store: store, identity: identity,
                                                  scope: scope, music: music, scratch: scratch, replacingOther: replacing)
                }
                running = run
                defer { running = nil }
                let result = try await run.value
                publishedChanges = changes
                replacingOther = false
                if result.isCurrent { lastBackup = result.snapshotAt }
                remaining = result.remaining
                needsPublish = !result.isCurrent || result.remaining > 0 || result.waiting > 0
            } catch CloudBackupError.otherLibrary(let mac, let date) {
                problem = .otherLibrary(macName: mac, snapshotAt: date)
            } catch {
                problem = .failed(error.localizedDescription)
                needsPublish = true
            }
            await refreshStatus()
        }
    }

    private nonisolated static func resolve(_ known: FolderCloudStore?, containerID: String) async -> FolderCloudStore? {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        if let known { return known }
        return await Task.detached(priority: .utility) { CloudContainer.backupStore(identifier: containerID) }.value
    }

    /// The backup in iCloud, for a restore; nil when signed out or without iCloud.
    func backupStore() async -> FolderCloudStore? {
        guard let containerID else { return nil }
        let found = await Self.resolve(store, containerID: containerID)
        if let found { store = found }
        return found
    }

    /// What's still uploading, the snapshots, and whether signed in to iCloud.
    func refreshStatus() async {
        guard let containerID else { return }
        guard let store = await Self.resolve(store, containerID: containerID) else {
            if scope != .off { problem = .signedOut }
            return
        }
        self.store = store
        if problem == .signedOut { problem = nil }
        let entries = (try? await Task.detached(priority: .utility) { try store.entries() }.value) ?? []
        let waiting = entries.filter { !$0.isUploaded }
        uploads = Uploads(files: waiting.count, bytes: waiting.reduce(0) { $0 + $1.size },
                          error: entries.lazy.compactMap(\.uploadError).first)
        snapshotCount = entries.filter { CloudSnapshots.date(ofPath: $0.path) != nil }.count
    }

    func refreshEstimate() async {
        guard let context = context() else { return }
        let chosen = chosenTracks(), all = allTracks(), phone = iPhoneTracks()
        estimate = await Task.detached(priority: .utility) {
            func size(_ tracks: [Track]) -> Int64 {
                tracks.reduce(0) { $0 + ($1.resolvedFileURL(root: context.root).flatMap(LibraryExporter.size(of:)) ?? 0) }
            }
            return Estimate(library: CloudBackup.estimatedSize(database: context.database, root: context.root),
                            chosenMusic: size(chosen), allMusic: size(all), iPhoneSongs: phone.count, iPhoneMusic: size(phone))
        }.value
    }
}
