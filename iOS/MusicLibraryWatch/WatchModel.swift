import Foundation
import MusicLibraryGlance
import Observation
import WatchConnectivity
import WidgetKit

/// The watch's view of the iPhone app: the summary (`Glance`) it last sent, kept in the app group for the
/// complications, the covers it shows, and commands for the iPhone's player. The iPhone does the playing; the watch is
/// a remote and a glance at the stats.
@Observable
final class WatchModel {
    static let shared = WatchModel()

    private(set) var glance: Glance?
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
    @ObservationIgnored private let delegate = SessionDelegate()
    /// Covers asked for and not answered yet.
    @ObservationIgnored private var requested = Set<String>()

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    private init() {
        glance = store.read()
        delegate.onGlance = { [weak self] data in self?.receive(data) }
        delegate.onReachability = { [weak self] reachable in self?.reachabilityChanged(reachable) }
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
        guard let session, session.activationState == .activated, session.isReachable, let glance else { return }
        let missing = glance.coverNames.filter { !store.hasCover($0) && !requested.contains($0) }.sorted()
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
        session.sendMessage([GlanceMessage.refresh: true], replyHandler: { @Sendable [weak self] reply in
            let data = reply[GlanceMessage.glance] as? Data
            Task { @MainActor in if let data { self?.receive(data) } }
        }, errorHandler: nil)
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
    nonisolated(unsafe) var onReachability: (@MainActor (Bool) -> Void)?

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
}
