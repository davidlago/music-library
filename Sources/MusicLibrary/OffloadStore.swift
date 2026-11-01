import Foundation
import MusicLibraryCore

/// Offloading music from the Mac to the iCloud backup (`docs/icloud-plan.md` §7b, D17–D20): Offload from This Mac,
/// Download to This Mac and Keep on This Mac (rules like the iPhone list's, user defaults `iCloudKeepOnMac`), the
/// automatic setting (`iCloudOffloadAfter`), run after a backup at most once a day (`iCloudLastOffload`), Offload Now,
/// and downloading a song before it plays or before anything needs its file. Offloaded songs stay in the library; only
/// their files leave the Mac, and only once the backup holds them as they are here.
@MainActor @Observable
final class OffloadStore {
    private enum Keys {
        static let threshold = "iCloudOffloadAfter"
        static let keepOnMac = "iCloudKeepOnMac"
        static let lastRun = "iCloudLastOffload"
        /// The first offload explained that iCloud holds the only copy now (D18e).
        static let explained = "iCloudOffloadExplained"
    }

    /// Offload albums not played in this long (D19).
    var threshold: OffloadThreshold {
        didSet { UserDefaults.standard.set(threshold.rawValue, forKey: Keys.threshold) }
    }
    /// Albums, artists, playlists and songs that never leave this Mac.
    private(set) var keepOnMac: SyncSelection {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(keepOnMac), forKey: Keys.keepOnMac) }
    }
    var hasExplained: Bool {
        didSet { UserDefaults.standard.set(hasExplained, forKey: Keys.explained) }
    }
    /// The songs whose files are only in iCloud, from the library (`load`).
    private(set) var offloaded: [Int64: OffloadedTrack] = [:]
    private(set) var offloadedBytes: Int64 = 0
    private(set) var lastRun: Date? {
        didSet { UserDefaults.standard.set(lastRun, forKey: Keys.lastRun) }
    }
    /// Songs being downloaded now, and how far along.
    private(set) var downloading: Set<Int64> = []
    private(set) var downloadProgress: (done: Int, total: Int)?
    private(set) var isOffloading = false
    /// What went wrong with the last offload or download.
    var lastError: String?

    /// What Offload Now or Offload from This Mac would do, waiting for the user's yes.
    struct Confirmation: Identifiable {
        let id = UUID()
        var plan: OffloadPlan
        /// Offload Now, as opposed to songs picked by hand.
        var isAutomatic: Bool
    }
    var confirmation: Confirmation?

    /// The open library; nil while none is.
    @ObservationIgnored var context: () -> (root: URL, database: Database)? = { nil }
    @ObservationIgnored var tracks: (ExportItem) -> [Track] = { _ in [] }
    @ObservationIgnored var allTracks: () -> [Track] = { [] }
    /// When each song was last played (plays on the iPhone count once they reach the Mac).
    @ObservationIgnored var lastPlayed: () -> [Int64: Date] = { [:] }
    /// The song playing and the queue's songs (never offloaded automatically), and just the song playing.
    @ObservationIgnored var queued: () -> Set<Int64> = { [] }
    @ObservationIgnored var playing: () -> Set<Int64> = { [] }
    /// The backup in iCloud; nil when signed out or without iCloud.
    @ObservationIgnored var backupStore: () async -> FolderCloudStore? = { nil }
    /// Whether the backup is on and holds music, so offloading has something to rely on.
    @ObservationIgnored var backsUpMusic: () -> Bool = { false }
    /// Files left the Mac or came back: the library reloads and the backup notices.
    @ObservationIgnored var onChanged: () -> Void = {}

    /// Downloads in flight, shared by everyone waiting for the same song.
    @ObservationIgnored private var inFlight: [Int64: Task<String?, Never>] = [:]

    static let automaticInterval: TimeInterval = 86400

    init() {
        let defaults = UserDefaults.standard
        threshold = defaults.string(forKey: Keys.threshold).flatMap(OffloadThreshold.init(rawValue:)) ?? .off
        keepOnMac = defaults.data(forKey: Keys.keepOnMac).flatMap { try? JSONDecoder().decode(SyncSelection.self, from: $0) } ?? SyncSelection()
        hasExplained = defaults.bool(forKey: Keys.explained)
        lastRun = defaults.object(forKey: Keys.lastRun) as? Date
    }

    /// Reads which songs are offloaded (after every library reload). Songs whose files are back count as downloaded.
    func load(_ database: Database?, root: URL) {
        guard let database else { offloaded = [:]; offloadedBytes = 0; return }
        try? database.settleOffloaded(root: root)
        offloaded = (try? database.offloadedTracks()) ?? [:]
        offloadedBytes = offloaded.values.reduce(0) { $0 + $1.size }
    }

    func isOffloaded(_ track: Track) -> Bool { offloaded[track.id] != nil }
    func isOffloaded(_ item: ExportItem) -> Bool { tracks(item).contains(where: isOffloaded) }
    /// Every one of the item's songs is only in iCloud.
    func isAllOffloaded(_ item: ExportItem) -> Bool {
        let songs = tracks(item)
        return !songs.isEmpty && songs.allSatisfy(isOffloaded)
    }

    // MARK: Keep on This Mac

    func isKept(_ item: ExportItem) -> Bool { keepOnMac.contains(item, tracks: tracks) }

    func keep(_ items: [ExportItem], _ keep: Bool) {
        for item in items { keepOnMac.apply(item, include: keep, tracks: { Set(self.tracks($0).map(\.id)) }) }
    }

    /// The songs Keep on This Mac covers now (artists and playlists as they are today).
    private func keptIDs() -> Set<Int64> { Set(keepOnMac.resolve(tracks).map(\.id)) }

    /// Drops albums, artists and songs that left the library. Only with a library loaded.
    func dropMissing() {
        guard !allTracks().isEmpty else { return }
        var pruned = keepOnMac
        pruned.dropMissing(tracks: { Set(self.tracks($0).map(\.id)) })
        if pruned != keepOnMac { keepOnMac = pruned }
    }

    // MARK: Offloading

    /// The songs' files on the Mac and the backup's listing, off the main thread.
    private nonisolated static func inputs(_ tracks: [Track], root: URL, store: FolderCloudStore) async throws
        -> (local: [String: CloudBackupFile], entries: [CloudEntry]) {
        try await Task.detached(priority: .utility) {
            let local = Dictionary(CloudBackupPlan.files(tracks: [], collectionCovers: [], music: tracks, root: root).map { ($0.path, $0) },
                                   uniquingKeysWith: { a, _ in a })
            return (local, try store.entries(under: "Music"))
        }.value
    }

    /// The albums the setting would offload now; nil without iCloud or with the setting off.
    func automaticPlan(now: Date = Date()) async -> OffloadPlan? {
        guard let cutoff = threshold.cutoff(before: now), let context = context(), let store = await backupStore() else { return nil }
        let all = allTracks()
        guard let (local, entries) = try? await Self.inputs(all.filter { !isOffloaded($0) }, root: context.root, store: store) else { return nil }
        let downloaded = (try? context.database.offloadDownloadDates()) ?? [:]
        return OffloadPlan(automatic: all, local: local, entries: entries, offloaded: Set(offloaded.keys), lastPlayed: lastPlayed(),
                           downloaded: downloaded, kept: keptIDs(), protected: queued().union(playing()), cutoff: cutoff, now: now)
    }

    /// Offload Now: works out what the setting offloads and asks first, with what it frees.
    func offloadNow() {
        Task {
            guard let plan = await automaticPlan() else { lastError = "iCloud isn't available."; return }
            confirmation = Confirmation(plan: plan, isAutomatic: true)
        }
    }

    /// Offload from This Mac on albums, artists, playlists or songs: the songs the backup holds as they are here
    /// (not the one playing). The first time, it asks first (D18e).
    func offload(_ items: [ExportItem]) {
        let songs = items.flatMap(tracks).filter { !isOffloaded($0) }
        guard !songs.isEmpty, let context = context() else { return }
        Task {
            guard let store = await backupStore(),
                  let (local, entries) = try? await Self.inputs(songs, root: context.root, store: store) else {
                lastError = "iCloud isn't available."
                return
            }
            let plan = OffloadPlan(chosen: songs, local: local, entries: entries, offloaded: Set(offloaded.keys), protected: playing())
            if plan.albums.isEmpty {
                lastError = plan.notInBackup > 0
                    ? "\(plan.notInBackup == 1 ? "This song isn't" : "These songs aren't") in the iCloud backup yet, so \(plan.notInBackup == 1 ? "it stays" : "they stay") on this Mac. Back up their music first."
                    : nil
                return
            }
            if hasExplained { run(plan) } else { confirmation = Confirmation(plan: plan, isAutomatic: false) }
        }
    }

    /// After a backup: the setting's albums, at most once a day, without asking (the user chose the setting).
    func runAutomatically(now: Date = Date()) {
        guard threshold != .off, backsUpMusic(), !isOffloading, hasExplained else { return }
        if let lastRun, now.timeIntervalSince(lastRun) < Self.automaticInterval { return }
        lastRun = now
        Task {
            guard let plan = await automaticPlan(now: now), !plan.albums.isEmpty else { return }
            run(plan)
        }
    }

    /// Deletes the plan's files from the Mac, each checked against the backup again just before.
    func run(_ plan: OffloadPlan) {
        guard !isOffloading, let context = context() else { return }
        hasExplained = true
        isOffloading = true
        lastError = nil
        let rows = plan.tracks
        Task {
            defer { isOffloading = false }
            guard let store = await backupStore() else { lastError = "iCloud isn't available."; return }
            do {
                let result = try await Task.detached(priority: .utility) {
                    try CloudBackup.offload(rows, database: context.database, root: context.root, store: store)
                }.value
                if !result.skipped.isEmpty {
                    lastError = "\(result.skipped.count) \(result.skipped.count == 1 ? "song" : "songs") changed since the last backup, so \(result.skipped.count == 1 ? "it stays" : "they stay") on this Mac until the next one."
                }
            } catch {
                lastError = error.localizedDescription
            }
            onChanged()
        }
    }

    // MARK: Downloading

    /// Download to This Mac: brings the items' offloaded songs back for good.
    func download(_ items: [ExportItem]) { download(tracks: items.flatMap(tracks)) }

    func download(tracks: [Track]) {
        let songs = tracks.filter(isOffloaded)
        guard !songs.isEmpty else { return }
        Task {
            do { try await ensureLocal(songs) } catch { lastError = error.localizedDescription }
        }
    }

    /// Makes sure the songs' files are on the Mac, downloading the offloaded ones first (D20): before playing, and
    /// before anything that reads or rewrites the files (a new cover in the files, a rip check, an export). Throws
    /// when one can't be downloaded (offline, no room, not in the backup).
    func ensureLocal(_ songs: [Track]) async throws {
        let rows = songs.compactMap { offloaded[$0.id] }.filter { inFlight[$0.trackID] == nil }
        var waiting = songs.compactMap { inFlight[$0.id] }
        if !rows.isEmpty {
            guard let context = context() else { throw OffloadFailure(message: "No library is open.") }
            let ids = rows.map(\.trackID)
            let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                Task { @MainActor in self?.downloadProgress = (done, total) }
            }
            let task = Task<String?, Never> { [weak self] in
                guard let self else { return "No library is open." }
                guard let store = await self.backupStore() else { return "iCloud isn't available, so the song can't be downloaded." }
                self.downloading.formUnion(ids)
                defer {
                    self.downloading.subtract(ids)
                    if self.downloading.isEmpty { self.downloadProgress = nil }
                    for id in ids { self.inFlight[id] = nil }
                }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await CloudBackup.download(rows, database: context.database, root: context.root, store: store, progress: report)
                    }.value
                    self.onChanged()
                    if let missing = result.skipped.first, let row = rows.first(where: { $0.trackID == missing }) {
                        return OffloadError.notInBackup(row.path).localizedDescription
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            for id in ids { inFlight[id] = task }
            waiting.append(task)
        }
        for task in waiting {
            if let failure = await task.value { throw OffloadFailure(message: failure) }
        }
    }

    /// Downloads a song ahead of playing it (the queue's next one); failures are left for when it plays.
    func prefetch(_ track: Track) {
        guard isOffloaded(track), inFlight[track.id] == nil else { return }
        Task { try? await ensureLocal([track]) }
    }

    struct OffloadFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
