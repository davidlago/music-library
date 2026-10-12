import Foundation
import MusicLibraryGlance
import WatchConnectivity

/// The iPhone's end of the watch connection: sends the summary (`Glance`) as the application context (and as a
/// message while the watch app is open, which is quicker), answers the watch's requests for covers with small
/// JPEGs, and runs the watch's commands on the player. A command from the watch wakes the app in the background if needed.
final class WatchLink: NSObject {
    /// Runs a command; set by the model.
    var perform: ((GlanceCommand) async -> GlanceCommandResult)?
    /// The summary to send when the watch asks for it.
    var current: () -> Glance? = { nil }
    private let store: GlanceStore
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    /// The song and play state last pushed for the complications.
    private var complicationState: (song: Int64?, playing: Bool)?

    init(store: GlanceStore) {
        self.store = store
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ glance: Glance) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? GlanceStore.encode(glance) else { return }
        try? session.updateApplicationContext([GlanceMessage.glance: data])
        if session.isReachable {
            session.sendMessage([GlanceMessage.glance: data], replyHandler: nil, errorHandler: nil)
        } else {
            pushToComplications(glance, data: data, session: session)
        }
    }

    /// The application context reaches a watch app in the background only when watchOS gets to it, so a complication
    /// would show the song that was playing a while ago. With one on the watch face, a change of song or play/pause
    /// goes as a complication transfer, which wakes the watch app at once; there are about 50 a day, so some are left
    /// for later.
    private func pushToComplications(_ glance: Glance, data: Data, session: WCSession) {
        let state = (song: glance.nowPlaying?.song.id, playing: glance.nowPlaying?.isPlaying ?? false)
        guard session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 10,
              complicationState.map({ $0.song != state.song || $0.playing != state.playing }) ?? true else { return }
        complicationState = state
        session.transferCurrentComplicationUserInfo([GlanceMessage.glance: data])
    }

    /// The covers the watch asked for, made smaller for it (only ones the summary shows).
    private func covers(_ names: [String]) async -> [String: Data] {
        let shown = current()?.coverNames ?? []
        let urls = Set(names.prefix(GlanceMessage.coversPerMessage)).filter(shown.contains).compactMap { name in
            store.coverURL(name).map { (name, $0) }
        }
        return await Task.detached(priority: .utility) {
            var out: [String: Data] = [:]
            for (name, url) in urls { out[name] = GlanceFeed.thumbnail(url, maxPixel: 160, quality: 0.7) }
            return out
        }.value
    }

    private func handle(command: GlanceCommand?, refresh: Bool, covers names: [String]?) async -> [String: Any] {
        var reply: [String: Any] = [:]
        if let names { reply[GlanceMessage.coverData] = await covers(names) }
        if let command {
            let result = await perform?(command) ?? .failed("Music Library isn't ready on the iPhone.")
            reply[GlanceMessage.result] = GlanceMessage.encode(result)
        }
        if refresh || command != nil, let glance = current(), let data = try? GlanceStore.encode(glance) {
            reply[GlanceMessage.glance] = data
        }
        return reply
    }
}

/// WatchConnectivity calls back on a background queue: the values are taken out of the (non-Sendable) dictionaries
/// there and handled on the main actor.
extension WatchLink: WCSessionDelegate {
    nonisolated private struct Request: Sendable {
        var command: GlanceCommand?
        var refresh: Bool
        var covers: [String]?

        init(_ message: [String: Any]) {
            command = GlanceMessage.decode(GlanceCommand.self, from: message[GlanceMessage.command])
            refresh = message[GlanceMessage.refresh] as? Bool ?? false
            covers = message[GlanceMessage.covers] as? [String]
        }
    }

    /// The reply handler, which WatchConnectivity lets any thread call once.
    nonisolated private struct Reply: @unchecked Sendable {
        let send: ([String: Any]) -> Void
    }

    /// Sendable wrapper for the reply's property-list values.
    nonisolated private struct Payload: @unchecked Sendable {
        let values: [String: Any]
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in if let glance = self.current() { self.send(glance) } }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After switching to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isWatchAppInstalled else { return }
        Task { @MainActor in if let glance = self.current() { self.send(glance) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let request = Request(message)
        Task { @MainActor in _ = await self.handle(command: request.command, refresh: request.refresh, covers: request.covers) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let request = Request(message), reply = Reply(send: replyHandler)
        Task { @MainActor in
            let payload = Payload(values: await self.handle(command: request.command, refresh: request.refresh, covers: request.covers))
            reply.send(payload.values)
        }
    }

}
