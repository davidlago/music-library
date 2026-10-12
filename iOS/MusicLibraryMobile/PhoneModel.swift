import Foundation
import MusicLibraryCore
import Network
import Observation
import UIKit

/// The library on the phone: finds it in Documents, loads its snapshot off the main thread, and reloads it when
/// it changes (an export dragged in through Finder's Files tab now, a sync later). Also connects the player to
/// Last.fm and keeps the play queue across launches.
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
        player.onTrackStart = { [weak self] track in
            self?.scrobbler.trackStarted(track)
            self?.savePlayerState()
        }
        player.onProgress = { [weak self] track, position, playing in
            self?.scrobbler.progress(track, position: position, playing: playing)
        }
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
