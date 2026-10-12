import Foundation
import MusicLibraryCore
import Network
import Observation
import UIKit

/// The library on the phone: finds it in Documents, loads its snapshot off the main thread, and reloads it when
/// it changes (a sync, or an export dragged in through Finder's Files tab). Also connects the player to Last.fm,
/// keeps the play queue across launches, and records plays and likes for the Mac (`outbox`, sent at each sync).
@Observable
final class PhoneModel {
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
    /// Plays and likes since the last sync.
    @ObservationIgnored let outbox = SyncOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sync-outbox.json"))
    /// Liked songs and when: the copy's, with the likes and unlikes made on the phone since the last sync.
    private(set) var likedDates: [Int64: Date] = [:]

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
            guard let self else { return ([], nil) }
            return (outbox.events, library?.libraryID)
        }
        recoverInterruptedPlay()
        sync.onEventsDelivered = { [weak self] ids in
            self?.outbox.remove(ids)
            self?.refreshLikes()
        }
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
                self.refreshLikes()
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

    // MARK: Likes and plays

    func isLiked(_ track: Track) -> Bool { likedDates[track.id] != nil }

    /// Liked songs on the phone, most recently liked first.
    var likedTracks: [Track] {
        guard let library else { return [] }
        return likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { library.track(id: $0.key) }
    }

    func toggleLike(_ track: Track) {
        outbox.append(SyncEvent(track: track, at: Date(), kind: .like(!isLiked(track))))
        refreshLikes()
    }

    private func refreshLikes() {
        likedDates = SyncOutbox.liked(base: library?.likedDates ?? [:], events: outbox.events)
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
        player.restore(snapshot) { library.track(id: $0) }
    }
}
