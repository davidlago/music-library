import Foundation
import MusicLibraryCore

/// The iCloud backup (`docs/icloud-plan.md` §5): what to back up (user defaults `iCloudBackupScope`), when (two
/// minutes after the library last changed, at most every 15 minutes, again after a publish that didn't finish, and
/// Back Up Now), and its status. Hidden in builds without an iCloud container (`isAvailable`).
@MainActor @Observable
final class CloudBackupStore {
    private enum Keys {
        static let scope = "iCloudBackupScope"
        static let lastBackup = "iCloudLastBackup"
        /// The last publish failed or didn't finish, so one runs soon after launch.
        static let pending = "iCloudBackupPending"
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
    /// About how much "Library and covers" takes in iCloud.
    private(set) var estimate: Int64?

    /// The open library; nil while none is.
    @ObservationIgnored var context: () -> (root: URL, database: Database)? = { nil }
    @ObservationIgnored var identity: () -> CloudBackupIdentity = { CloudBackupIdentity(macID: "", macName: "Mac", appVersion: AppInfo.version) }
    @ObservationIgnored private var store: FolderCloudStore?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var needsPublish: Bool {
        didSet { UserDefaults.standard.set(needsPublish, forKey: Keys.pending) }
    }
    @ObservationIgnored private var replacingOther = false
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
        let scope = scope, identity = identity(), replacing = replacingOther
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
                let result = try await Task.detached(priority: .utility) {
                    try await CloudBackup.publish(database: context.database, root: context.root, store: store, identity: identity,
                                                  scope: scope, scratch: scratch, replacingOther: replacing)
                }.value
                publishedChanges = changes
                replacingOther = false
                if result.isCurrent { lastBackup = result.snapshotAt }
                needsPublish = !result.isCurrent
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
        estimate = await Task.detached(priority: .utility) {
            CloudBackup.estimatedSize(database: context.database, root: context.root, scope: .library)
        }.value
    }

    /// The backup's folder in the container, for Show in Finder.
    var folder: URL? { store?.root }
}
