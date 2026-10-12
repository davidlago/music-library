import Foundation
import MusicLibraryCore
import Network
import Observation
import UIKit

/// The library on the phone: finds it in Documents, loads its snapshot off the main thread, and reloads it when
/// it changes (a sync, or an export dragged in through Finder's Files tab). The snapshot lists the whole library;
/// only the songs whose files are here play, and the rest can be asked for (`requests`, sent at each sync, which
/// starts as soon as the Mac is around). Also connects the player to Last.fm, keeps the play queue across launches,
/// and records plays, likes and ownership changes for the Mac (`outbox`, sent at each sync).
@Observable
final class PhoneModel {
    /// Whether an album, artist or list's songs are on the phone.
    enum Availability: Equatable {
        case onPhone
        case partial(present: Int, total: Int)
        case notOnPhone
        /// Nothing to have (an empty list).
        case empty
    }

    enum State {
        case loading
        /// No `library.sqlite` in Documents.
        case missing
        case loaded(LibrarySnapshot)
        case failed(String)
    }

    private(set) var state: State = .loading
    let player = PhonePlayer()
    /// Shared with the Mac app: the same scrobble rules, queue (kept while offline) and account handling.
    let scrobbler = Scrobbler(openURL: { UIApplication.shared.open($0) })
    let sync = PhoneSync()
    let concerts = PhoneConcerts()
    /// Plays, likes and ownership changes since the last sync.
    @ObservationIgnored let outbox = SyncOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sync-outbox.json"))
    /// Downloads and removals not yet applied by the Mac.
    @ObservationIgnored let requestQueue = SyncRequestQueue(url: URL.applicationSupportDirectory.appendingPathComponent("sync-requests.json"))
    /// Liked songs and when: the copy's, with the likes and unlikes made on the phone since the last sync.
    private(set) var likedDates: [Int64: Date] = [:]
    /// Owned albums by `SearchIndex.albumKey`: the copy's, with the changes made on the phone since the last sync.
    private(set) var purchases: [String: AlbumPurchase] = [:]
    /// The copy's listening history with the phone's plays since the last sync, and their totals.
    private(set) var plays: [Play] = []
    private(set) var playTotals: [Int64: PlayTotal] = [:]
    /// By `LibrarySnapshot.artistKey` (album artist).
    private(set) var artistPlayTotals: [String: PlayTotal] = [:]
    /// What the phone asked for that the Mac hasn't applied yet, oldest first.
    private(set) var requests: [SyncRequest] = []
    /// Songs asked for and not here yet.
    private(set) var pendingDownloads: Set<Int64> = []

    /// The song whose details are shown (Song Info).
    var infoTrack: Track?

    /// Bumped when the library, the history or ownership changes (Insights recompute).
    private(set) var libraryVersion = 0
    private(set) var historyVersion = 0
    private(set) var purchasesVersion = 0
    private(set) var libraryStats: LibraryStats?
    private(set) var listeningStats: ListeningStats?
    private(set) var ownershipStats: OwnershipStats?
    @ObservationIgnored private var statsVersion = -1
    @ObservationIgnored private var listeningKey: (period: ListeningStats.Period, library: Int, history: Int, at: Date)?
    @ObservationIgnored private var ownershipKey: (library: Int, purchases: Int, history: Int)?

    @ObservationIgnored private var currentPlay: (track: Track, startedAt: Date, tracker: ListenTracker)?
    @ObservationIgnored private var loadedStamp: Stamp?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restoredPlayerState = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    var library: LibrarySnapshot? {
        if case .loaded(let s) = state { return s }
        return nil
    }

    init() {
        sync.onLibraryChanged = { [weak self] in self?.reload() }
        sync.pendingEvents = { [weak self] in
            guard let self else { return ([], [], nil) }
            return (outbox.events, requestQueue.requests, library?.libraryID)
        }
        recoverInterruptedPlay()
        sync.onEventsDelivered = { [weak self] events, requests in
            self?.outbox.remove(events)
            self?.requestQueue.remove(requests)
            self?.refreshOverlays()
        }
        sync.storeConcerts = { [weak self] settings in self?.concerts.adopt(settings) }
        sync.isLastFMConnected = { [weak self] in
            if case .connected = self?.scrobbler.status { return true }
            return false
        }
        sync.adoptLastFM = { [weak self] account in
            guard let self, !sync.isLastFMConnected() else { return }
            scrobbler.adopt(apiKey: account.apiKey, sharedSecret: account.sharedSecret,
                            session: LastFMSession(key: account.sessionKey, username: account.username))
        }
        player.onTrackStart = { [weak self] track in
            self?.scrobbler.trackStarted(track)
            self?.startPlay(track)
            self?.savePlayerState()
        }
        player.onProgress = { [weak self] track, position, playing in
            self?.scrobbler.progress(track, position: position, playing: playing)
            self?.advancePlay(track, position: position, playing: playing)
        }
        player.onPlaybackEnded = { [weak self] in self?.finishPlay() }
        // Scrobbles made offline go out as soon as the phone is back online.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.scrobbler.flush() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    // MARK: Library

    /// What a reload compares: the library folder, its database and its Music folder (new albums copied in).
    struct Stamp: Equatable, Sendable {
        var root: URL
        var database: Date?
        var music: Date?

        nonisolated static func current(in documents: URL) -> Stamp? {
            guard let root = LibrarySnapshot.findRoot(in: documents) else { return nil }
            func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            return Stamp(root: root, database: modified(LibraryLocation.databaseURL(root: root)),
                         music: modified(root.appendingPathComponent("Music", isDirectory: true)))
        }
    }

    func reloadIfChanged() {
        let stamp = Stamp.current(in: URL.documentsDirectory)
        if case .loaded = state, stamp == loadedStamp { return }
        reload()
    }

    func reload() {
        generation += 1
        let generation = generation
        let documents = URL.documentsDirectory
        if library == nil { state = .loading }
        Task.detached(priority: .userInitiated) {
            let (state, stamp) = Self.load(documents: documents)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.state = state
                self.loadedStamp = stamp
                if case .loaded(let library) = state {
                    self.player.library = library
                    self.restorePlayerState(library)
                }
                self.libraryVersion += 1
                self.refreshOverlays()
            }
        }
    }

    nonisolated private static func load(documents: URL) -> (State, Stamp?) {
        guard let stamp = Stamp.current(in: documents) else { return (.missing, nil) }
        // Tens of GB of music shouldn't go into iCloud backups; the Mac has the library.
        var root = stamp.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        do {
            return (.loaded(try LibrarySnapshot(root: stamp.root)), stamp)
        } catch {
            return (.failed(error.localizedDescription), stamp)
        }
    }

    // MARK: Overlays

    /// The copy's likes, ownership, history and requests with what happened on the phone since.
    private func refreshOverlays() {
        let events = outbox.events
        likedDates = SyncOutbox.liked(base: library?.likedDates ?? [:], events: events)
        refreshPurchases(events)
        refreshPlays(events)
        refreshRequests()
    }

    private func refreshPurchases(_ events: [SyncEvent]) {
        let library = library
        purchases = SyncOutbox.purchases(base: library?.purchases ?? [:], events: events) { id in
            library?.track(id: id).map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) }
        }
        purchasesVersion += 1
    }

    private func refreshPlays(_ events: [SyncEvent]) {
        var plays = library?.plays ?? []
        var totals = library?.playTotals ?? [:]
        for e in events {
            guard case .play(let listened, let counted) = e.kind, library?.track(id: e.trackID) != nil else { continue }
            plays.append(Play(trackId: e.trackID, startedAt: e.at, listened: listened, counted: counted))
            totals[e.trackID] = (totals[e.trackID] ?? PlayTotal()) + PlayTotal(plays: counted ? 1 : 0, listened: listened, lastPlayed: e.at)
        }
        var artists: [String: PlayTotal] = [:]
        if let library {
            for (id, total) in totals {
                guard let t = library.track(id: id) else { continue }
                let key = LibrarySnapshot.artistKey(t.effectiveAlbumArtist)
                artists[key] = (artists[key] ?? PlayTotal()) + total
            }
        }
        self.plays = plays
        playTotals = totals
        artistPlayTotals = artists
        historyVersion += 1
    }

    // MARK: Likes and plays

    func isLiked(_ track: Track) -> Bool { likedDates[track.id] != nil }

    /// Liked songs, most recently liked first.
    var likedTracks: [Track] {
        guard let library else { return [] }
        return likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { library.track(id: $0.key) }
    }

    func toggleLike(_ track: Track) {
        outbox.append(SyncEvent(track: track, at: Date(), kind: .like(!isLiked(track))))
        likedDates = SyncOutbox.liked(base: library?.likedDates ?? [:], events: outbox.events)
    }

    func artistPlayTotal(_ name: String) -> PlayTotal { artistPlayTotals[LibrarySnapshot.artistKey(name)] ?? PlayTotal() }

    // MARK: Ownership

    func purchase(for album: AlbumSummary) -> AlbumPurchase? { purchases[SearchIndex.albumKey(album: album.album, artist: album.artist)] }

    /// Records that you own the album (with nil, that you don't); the change goes to the Mac at the next sync.
    func setPurchase(_ purchase: AlbumPurchase?, for album: AlbumSummary) {
        guard self.purchase(for: album) != purchase, let track = library?.tracks(album: album).first else { return }
        outbox.append(SyncEvent(track: track, at: Date(), kind: .purchase(purchase)))
        refreshPurchases(outbox.events)
    }

    // MARK: Availability, downloads and removals

    func availability(_ tracks: [Track]) -> Availability {
        guard let library, !tracks.isEmpty else { return .empty }
        let present = tracks.reduce(0) { $0 + (library.isPresent($1) ? 1 : 0) }
        if present == tracks.count { return .onPhone }
        return present == 0 ? .notOnPhone : .partial(present: present, total: tracks.count)
    }

    func availability(_ item: ExportItem) -> Availability { availability(library?.tracks(for: item) ?? []) }

    /// The songs that can be played, in the same order.
    func playable(_ tracks: [Track]) -> [Track] { library?.playable(tracks) ?? [] }

    func isPresent(_ track: Track) -> Bool { library?.isPresent(track) ?? false }

    /// Some of these songs were asked for and haven't arrived.
    func isDownloadPending(_ tracks: [Track]) -> Bool { tracks.contains { pendingDownloads.contains($0.id) } }

    /// Asks the Mac for the item's songs; a sync starts as soon as the Mac is around.
    func download(_ item: ExportItem) {
        requestQueue.add(SyncRequest(item: item, include: true))
        refreshRequests()
        sync.requestSync()
    }

    /// Deletes the item's songs from the phone now (covers stay, so it can still be browsed) and asks the Mac to
    /// stop syncing them.
    func remove(_ item: ExportItem) {
        guard let library else { return }
        let paths = library.tracks(for: item).filter(library.isPresent).map(\.path)
        if player.currentTrack.map({ t in paths.contains(t.path) }) == true { player.pause() }
        requestQueue.add(SyncRequest(item: item, include: false))
        do {
            try SyncReceiver(root: library.root).delete(paths)
        } catch {
            sync.report(error: "Couldn't remove all of it: \(error.localizedDescription)")
        }
        refreshRequests()
        reload()
        sync.requestSync()
    }

    private func refreshRequests() {
        requests = requestQueue.requests
        guard let library else { pendingDownloads = []; return }
        var pending = Set<Int64>()
        for r in requests {
            let ids = library.tracks(for: r.item).filter { !library.isPresent($0) }.map(\.id)
            if r.include { pending.formUnion(ids) } else { pending.subtract(ids) }
        }
        pendingDownloads = pending
    }

    // MARK: Insights

    /// Library stats for the whole library (files not on the phone count with their estimated size).
    func loadLibraryStats() {
        guard let library, statsVersion != libraryVersion || libraryStats == nil else { return }
        let version = libraryVersion
        Task.detached(priority: .userInitiated) {
            let root = library.root
            let present = library.presentIDs
            var covers: [String: Bool] = [:]
            let stats = LibraryStats(tracks: library.tracks, hasCover: { t in
                let dir = (t.path as NSString).deletingLastPathComponent
                if let known = covers[dir] { return known }
                let has = t.coverURL(root: root).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                covers[dir] = has
                return has
            }, fileSize: { t in
                present.contains(t.id) ? t.resolvedFileURL(root: root).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) } : nil
            })
            await MainActor.run {
                guard self.libraryVersion == version else { return }
                self.libraryStats = stats
                self.statsVersion = version
            }
        }
    }

    func loadListening(_ period: ListeningStats.Period) {
        if let k = listeningKey, k.period == period, k.library == libraryVersion, k.history == historyVersion,
           Date().timeIntervalSince(k.at) < 300 { return }
        guard let library else { return }
        let key = (period: period, library: libraryVersion, history: historyVersion, at: Date())
        listeningKey = key
        let plays = plays
        Task.detached(priority: .userInitiated) {
            let stats = ListeningStats(plays: plays, tracks: library.tracks, period: period, now: key.at)
            await MainActor.run {
                guard self.listeningKey?.at == key.at else { return }
                self.listeningStats = stats
            }
        }
    }

    func loadOwnership() {
        let key = (library: libraryVersion, purchases: purchasesVersion, history: historyVersion)
        if let k = ownershipKey, k == key, ownershipStats != nil { return }
        guard let library else { return }
        ownershipKey = key
        let owned = purchases, totals = playTotals
        Task.detached(priority: .userInitiated) {
            let stats = OwnershipStats(tracks: library.tracks, purchases: owned, playTotals: totals)
            await MainActor.run {
                guard let k = self.ownershipKey, k == key else { return }
                self.ownershipStats = stats
            }
        }
    }

    // The same rules as the Mac's listening history: a play is saved once something was heard, and counts when it
    // met the scrobble rule.
    private func startPlay(_ track: Track) {
        finishPlay()
        currentPlay = (track, Date(), ListenTracker(duration: track.duration))
    }

    private func advancePlay(_ track: Track, position: Double, playing: Bool) {
        guard currentPlay?.track.id == track.id else { return }
        _ = currentPlay?.tracker.advance(to: position, playing: playing)
    }

    /// Saves the play in progress, if any listening happened (when the next song starts or the queue ends).
    func finishPlay() {
        try? FileManager.default.removeItem(at: Self.interruptedPlayURL)
        guard let event = currentPlayEvent else { return }
        currentPlay = nil
        outbox.append(event)
        refreshPlays(outbox.events)
    }

    private var currentPlayEvent: SyncEvent? {
        guard let play = currentPlay, play.tracker.listened >= 1 else { return nil }
        return SyncEvent(track: play.track, at: play.startedAt, kind: .play(listened: play.tracker.listened, counted: play.tracker.hasScrobbled))
    }

    /// iOS may end the app in the background without warning, so the play in progress is kept here when it goes to
    /// the background, and saved at the next launch if the app didn't get to finish it.
    nonisolated static var interruptedPlayURL: URL { URL.applicationSupportDirectory.appendingPathComponent("interrupted-play.json") }

    func noteInterruptedPlay() {
        guard let event = currentPlayEvent, let data = try? JSONEncoder().encode(event) else { return }
        try? data.write(to: Self.interruptedPlayURL, options: .atomic)
    }

    private func recoverInterruptedPlay() {
        guard let data = try? Data(contentsOf: Self.interruptedPlayURL) else { return }
        try? FileManager.default.removeItem(at: Self.interruptedPlayURL)
        if let event = try? JSONDecoder().decode(SyncEvent.self, from: data) { outbox.append(event) }
    }

    // MARK: Player state

    /// The queue and position, saved at each song change and when the app goes to the background, and put back
    /// (paused) the first time the library loads.
    nonisolated static var playerStateURL: URL { URL.applicationSupportDirectory.appendingPathComponent("player-state.json") }

    func savePlayerState() {
        let url = Self.playerStateURL
        guard let snapshot = player.snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {}
    }

    private func restorePlayerState(_ library: LibrarySnapshot) {
        guard !restoredPlayerState else { return }
        restoredPlayerState = true
        guard let data = try? Data(contentsOf: Self.playerStateURL),
              let snapshot = try? JSONDecoder().decode(PlayQueue.Snapshot.self, from: data) else { return }
        player.restore(snapshot) { id in library.track(id: id).flatMap { library.isPresent($0) ? $0 : nil } }
    }
}
