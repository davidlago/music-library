import Foundation
import MusicLibraryGlance
import Observation
import WatchConnectivity
import WidgetKit

/// The watch's view of the iPhone app: the summary (`Glance`) it last sent, kept in the app group for the
/// complications, the shelf index for finding a CD or record by its label, the covers they show, and commands for the
/// iPhone's player. The iPhone does the playing; the watch is a remote and a glance at the stats.
@Observable
final class WatchModel {
    static let shared = WatchModel()

    private(set) var glance: Glance?
    /// Every labeled CD and record, sent by the iPhone as a file, so Find works while it's away. Nil until one
    /// arrives (and always from iPhones before the collection).
    private(set) var shelf: GlanceShelf?
    /// The iPhone app can be reached right now (commands need it).
    private(set) var reachable = false
    /// A command waiting for the iPhone's answer.
    private(set) var pending: GlanceCommand?
    /// The last command's failure, shown until the next one.
    var message: String?
    /// Bumped when covers arrive, so views load them again.
    private(set) var coverRevision = 0

    /// The complications read the same folder; without the app group (an unsigned build) covers go in Caches.
    @ObservationIgnored let store = GlanceStore.shared ?? GlanceStore(directory: URL.cachesDirectory.appendingPathComponent("Glance", isDirectory: true))
    @ObservationIgnored private let delegate: SessionDelegate
    /// Covers asked for and not answered yet.
    @ObservationIgnored private var requested = Set<String>()
    /// The shelf's `contentHash`, sent with `refresh` so the iPhone sends the index again when it has another.
    @ObservationIgnored private var shelfHash = ""
    /// The saved shelf has been read at launch (or one arrived first), so `shelfHash` is the one to send.
    @ObservationIgnored private var shelfLoaded = false
    /// `refresh` was asked for before that: it's sent once the shelf has been read.
    @ObservationIgnored private var refreshWaiting = false
    /// Where Find was: the series and the last number looked up in each, in a file in the store (not user defaults).
    private(set) var find: FindState
    @ObservationIgnored private var findSave: Task<Void, Never>?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    private init() {
        delegate = SessionDelegate(store: store)
        glance = store.read()
        find = FindState.read(from: store.directory)
        delegate.onGlance = { [weak self] data in self?.receive(data) }
        delegate.onShelf = { [weak self] shelf in self?.receive(shelf) }
        delegate.onReachability = { [weak self] reachable in self?.reachabilityChanged(reachable) }
        // The index can be up to 2 MB: read off the main thread.
        let store = store
        Task.detached(priority: .userInitiated) { [weak self] in
            let shelf = store.readShelf()
            await self?.loaded(shelf)
        }
        guard let session else { return }
        session.delegate = delegate
        session.activate()
    }

    // MARK: Receiving

    private func receive(_ data: Data) {
        guard let new = GlanceStore.decode(data) else { return }
        if let glance, new.generatedAt < glance.generatedAt { return }
        let changed = glance.map { !new.sameContent(as: $0) } ?? true
        glance = new
        try? store.write(new)
        if changed { WidgetCenter.shared.reloadAllTimelines() }
        store.pruneCovers(keeping: new.coverNames)
        requestMissingCovers()
    }

    /// The shelf saved at launch, unless one was received while it was being read (that one is newer: it replaced
    /// the file). Then the `refresh` that waited for its hash goes out.
    private func loaded(_ saved: GlanceShelf?) {
        if !shelfLoaded, let saved {
            shelf = saved
            shelfHash = saved.contentHash
        }
        shelfLoaded = true
        if refreshWaiting {
            refreshWaiting = false
            refresh()
        }
    }

    /// A shelf index just received (and already saved by the delegate). The iPhone sends one only when it differs
    /// from this watch's, so the last to arrive is the one to show, whatever the clocks say.
    private func receive(_ new: GlanceShelf) {
        shelf = new
        shelfHash = new.contentHash
        shelfLoaded = true
    }

    private func reachabilityChanged(_ reachable: Bool) {
        self.reachable = reachable
        if reachable {
            refresh()
            requestMissingCovers()
        }
    }

    /// Asks the iPhone for the covers the summary shows that aren't here, a few per message (replies have a size
    /// limit), while it's reachable; the rest are asked for when it is again.
    private func requestMissingCovers() {
        guard let glance else { return }
        requestCovers(glance.coverNames)
    }

    /// A shelf item's cover is on screen (the Find page): it's kept when the summary changes, among the shelf covers
    /// looked up most recently, and asked for while the iPhone is reachable.
    func showShelfCover(_ name: String) {
        store.rememberShelfCover(name)
        requestCovers([name])
    }

    private func requestCovers(_ names: Set<String>) {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let missing = names.filter { !store.hasCover($0) && !requested.contains($0) }.sorted()
        for start in stride(from: 0, to: missing.count, by: GlanceMessage.coversPerMessage) {
            let names = Array(missing[start..<min(start + GlanceMessage.coversPerMessage, missing.count)])
            requested.formUnion(names)
            session.sendMessage([GlanceMessage.covers: names], replyHandler: { @Sendable [weak self] reply in
                let covers = (reply[GlanceMessage.coverData] as? [String: Data]) ?? [:]
                Task { @MainActor in self?.receiveCovers(covers, asked: names) }
            }, errorHandler: { @Sendable [weak self] _ in
                Task { @MainActor in self?.requested.subtract(names) }
            })
        }
    }

    private func receiveCovers(_ covers: [String: Data], asked: [String]) {
        requested.subtract(asked)
        var saved = false
        for (name, data) in covers where asked.contains(name) && data.count < 500_000 {
            if (try? store.saveCover(data, name: name)) != nil { saved = true }
        }
        guard saved else { return }
        coverRevision += 1
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Asks the iPhone for its latest summary (when the app comes to the front).
    func refresh() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        // Without the saved shelf's hash the iPhone would send the whole index again.
        guard shelfLoaded else {
            refreshWaiting = true
            return
        }
        session.sendMessage([GlanceMessage.refresh: true, GlanceMessage.shelfHash: shelfHash], replyHandler: { @Sendable [weak self] reply in
            let data = reply[GlanceMessage.glance] as? Data
            Task { @MainActor in if let data { self?.receive(data) } }
        }, errorHandler: nil)
    }

    // MARK: Find

    /// Notes the series and number on screen; saved a moment after the crown stops.
    func setFind(_ state: FindState) {
        guard state != find else { return }
        find = state
        findSave?.cancel()
        let directory = store.directory
        findSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            state.write(to: directory)
        }
    }

    // MARK: Commands

    func send(_ command: GlanceCommand) {
        guard let session, session.activationState == .activated else { return }
        guard session.isReachable else {
            message = "Open Music Library on your iPhone, or bring it closer."
            return
        }
        message = nil
        pending = command
        applyOptimistically(command)
        guard let data = GlanceMessage.encode(command) else { return }
        session.sendMessage([GlanceMessage.command: data], replyHandler: { @Sendable [weak self] reply in
            let result = GlanceMessage.decode(GlanceCommandResult.self, from: reply[GlanceMessage.result])
            let glance = reply[GlanceMessage.glance] as? Data
            Task { @MainActor in self?.finish(command, result: result, glance: glance) }
        }, errorHandler: { @Sendable [weak self] error in
            let text = error.localizedDescription
            Task { @MainActor in self?.finish(command, result: .failed(text), glance: nil) }
        })
    }

    /// Play and pause show at once; the iPhone's answer confirms it.
    private func applyOptimistically(_ command: GlanceCommand) {
        guard var playing = glance?.nowPlaying else { return }
        switch command {
        case .playPause:
            playing.position = playing.position(at: Date())
            playing.updatedAt = Date()
            playing.isPlaying.toggle()
        case .toggleLike:
            playing.liked.toggle()
        default:
            return
        }
        glance?.nowPlaying = playing
    }

    private func finish(_ command: GlanceCommand, result: GlanceCommandResult?, glance data: Data?) {
        if pending == command { pending = nil }
        if let result, !result.ok { message = result.message }
        if let data { receive(data) }
    }

    /// Waits (briefly) for what the iPhone sent while the app was in the background to arrive.
    nonisolated static func waitForPendingContent() async {
        for _ in 0..<20 {
            guard WCSession.isSupported(), WCSession.default.hasContentPending else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// WatchConnectivity calls back on a background queue (so the closures given to it above are `@Sendable`, not
/// main-actor isolated): values are taken out there and handled on the main actor.
private final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    // Set once on the main actor before the session is activated, then only read.
    nonisolated(unsafe) var onGlance: (@MainActor (Data) -> Void)?
    nonisolated(unsafe) var onShelf: (@MainActor (GlanceShelf) -> Void)?
    nonisolated(unsafe) var onReachability: (@MainActor (Bool) -> Void)?
    nonisolated let store: GlanceStore

    init(store: GlanceStore) {
        self.store = store
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext[GlanceMessage.glance] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            if let context { self.onGlance?(context) }
            self.onReachability?(reachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.onReachability?(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[GlanceMessage.glance] as? Data else { return }
        Task { @MainActor in self.onGlance?(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[GlanceMessage.glance] as? Data else { return }
        Task { @MainActor in self.onGlance?(data) }
    }

    /// Complication transfers: the song or play state changed while the app wasn't open.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[GlanceMessage.glance] as? Data else { return }
        Task { @MainActor in self.onGlance?(data) }
    }

    /// The shelf index. Its file is deleted when this returns, so it's checked and saved here, under the store's fixed
    /// name (never the sender's): only a shelf of the version this watch reads, at most `GlanceShelf.maxBytes`.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        guard metadata[GlanceMessage.fileKind] as? String == GlanceMessage.shelfKind,
              metadata[GlanceMessage.shelfVersion] as? Int == GlanceShelf.currentVersion,
              let size = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= GlanceShelf.maxBytes,
              let data = try? Data(contentsOf: file.fileURL), let shelf = GlanceStore.decodeShelf(data) else { return }
        guard (try? store.writeShelf(shelf)) != nil else { return }
        Task { @MainActor in self.onShelf?(shelf) }
    }
}

/// Where the Find page was: the series shown and the last number looked up in each (0 before the first).
struct FindState: Codable, Equatable {
    static let fileName = "watch-find.json"

    var series = "cd"
    var cd = 0
    var vinyl = 0

    /// "cd" or "vinyl", whatever was saved.
    var seriesKey: String { series == "vinyl" ? "vinyl" : "cd" }

    func last(in series: String) -> Int { series == "vinyl" ? vinyl : cd }

    func with(series: String) -> FindState {
        var state = self
        state.series = series
        return state
    }

    func with(last number: Int, in series: String) -> FindState {
        var state = self
        if series == "vinyl" { state.vinyl = number } else { state.cd = number }
        return state
    }

    static func read(from directory: URL) -> FindState {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let state = try? JSONDecoder().decode(FindState.self, from: data) else { return FindState() }
        return state
    }

    func write(to directory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
