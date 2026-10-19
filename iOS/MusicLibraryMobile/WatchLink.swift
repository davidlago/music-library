import Foundation
import MusicLibraryGlance
import WatchConnectivity

/// The iPhone's end of the watch connection: sends the summary (`Glance`) as the application context (and as a
/// message while the watch app is open, which is quicker), answers the watch's requests for covers with small
/// JPEGs, and runs the watch's commands on the player. A command from the watch wakes the app in the background if needed.
///
/// The shelf index (`GlanceShelf`, for Find by Label on the watch) is too big for the application context, so it goes
/// as a file transfer, only when it changed since the last one sent, or when a watch's `refresh` says it has another.
final class WatchLink: NSObject {
    /// Runs a command; set by the model.
    var perform: ((GlanceCommand) async -> GlanceCommandResult)?
    /// The summary to send when the watch asks for it.
    var current: () -> Glance? = { nil }
    /// The shelf index to send, and where its covers come from.
    var currentShelf: () -> GlanceFeed.Shelf? = { nil }
    private let store: GlanceStore
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    /// The song and play state last pushed for the complications.
    private var complicationState: (song: Int64?, playing: Bool)?
    /// Copies of the shelf index being transferred (WatchConnectivity reads the file until the transfer ends, and the
    /// app group's copy is replaced on every change).
    nonisolated private static let shelfOutbox = URL.cachesDirectory.appendingPathComponent("WatchShelf", isDirectory: true)
    /// The `contentHash` of the shelf index last handed to WatchConnectivity for this watch. Kept across launches, so
    /// an unchanged index isn't sent at each one; forgotten when a transfer fails or the watch changes.
    nonisolated private static let sentShelfKey = "watchShelfHash"
    private var sentShelfHash: String? {
        get { UserDefaults.standard.string(forKey: Self.sentShelfKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sentShelfKey) }
    }

    init(store: GlanceStore) {
        self.store = store
        super.init()
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// The summary and, if the watch may not have it, the shelf index.
    private func sendAll() {
        if let glance = current() { send(glance) }
        if let shelf = currentShelf()?.index { sendShelf(shelf) }
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

    /// Sends the shelf index as a file when the watch may not have it: it changed since the last one sent, or
    /// `force` (the watch said it has another). One already on its way isn't sent twice; older ones are cancelled.
    func sendShelf(_ shelf: GlanceShelf, force: Bool = false) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let hash = shelf.contentHash
        guard force || hash != sentShelfHash else { return }
        let outstanding = session.outstandingFileTransfers.filter {
            $0.file.metadata?[GlanceMessage.fileKind] as? String == GlanceMessage.shelfKind
        }
        if outstanding.contains(where: { $0.file.metadata?[GlanceMessage.fileHash] as? String == hash }) {
            sentShelfHash = hash
            return
        }
        outstanding.forEach { $0.cancel() }
        guard let data = try? GlanceStore.encodeShelf(shelf), data.count <= GlanceShelf.maxBytes else { return }
        let fm = FileManager.default, url = Self.shelfOutbox.appendingPathComponent("shelf-\(hash).json")
        do {
            // Copies of cancelled transfers go; the name is ours (a hex hash), never the watch's.
            for old in (try? fm.contentsOfDirectory(at: Self.shelfOutbox, includingPropertiesForKeys: nil)) ?? [] where old != url {
                try? fm.removeItem(at: old)
            }
            try fm.createDirectory(at: Self.shelfOutbox, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        session.transferFile(url, metadata: [GlanceMessage.fileKind: GlanceMessage.shelfKind,
                                             GlanceMessage.shelfVersion: GlanceShelf.currentVersion,
                                             GlanceMessage.fileHash: hash])
        sentShelfHash = hash
    }

    /// A watch's `refresh`: sends the index again when the watch has another ("" when it has none yet). A watch app
    /// that doesn't say (nil) is one from before the collection, which can't read the index: it isn't sent.
    private func checkShelf(watchHas hash: String?) {
        guard let hash, let shelf = currentShelf()?.index, hash != shelf.contentHash else { return }
        sendShelf(shelf, force: true)
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

    /// The covers the watch asked for, made smaller for it (only ones the summary or the shelf index shows).
    private func covers(_ names: [String]) async -> [String: Data] {
        let shelf = currentShelf()
        let shown = (current()?.coverNames ?? []).union(shelf?.index.coverNames ?? [])
        let wanted = Set(names.prefix(GlanceMessage.coversPerMessage)).filter(shown.contains)
        let store = store
        return await Task.detached(priority: .utility) {
            var out: [String: Data] = [:]
            for name in wanted {
                guard let url = GlanceFeed.coverFile(name, store: store, shelf: shelf) else { continue }
                out[name] = GlanceFeed.thumbnail(url, maxPixel: 160, quality: 0.7)
            }
            return out
        }.value
    }

    private func handle(command: GlanceCommand?, refresh: Bool, shelfHash: String?, covers names: [String]?) async -> [String: Any] {
        var reply: [String: Any] = [:]
        if refresh { checkShelf(watchHas: shelfHash) }
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
        /// The `contentHash` of the shelf index the watch has.
        var shelfHash: String?
        var covers: [String]?

        init(_ message: [String: Any]) {
            command = GlanceMessage.decode(GlanceCommand.self, from: message[GlanceMessage.command])
            refresh = message[GlanceMessage.refresh] as? Bool ?? false
            shelfHash = message[GlanceMessage.shelfHash] as? String
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
        Task { @MainActor in self.sendAll() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After switching to another watch: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in self.sentShelfHash = nil }
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            // Installed again later, the watch app starts without an index.
            guard installed else { self.sentShelfHash = nil; return }
            self.sendAll()
        }
    }

    /// The shelf index went (or failed): its copy goes, and a failed one is sent again with the next change or refresh.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL, hash = fileTransfer.file.metadata?[GlanceMessage.fileHash] as? String
        if url.deletingLastPathComponent().standardizedFileURL == Self.shelfOutbox.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        guard error != nil, let hash else { return }
        Task { @MainActor in if self.sentShelfHash == hash { self.sentShelfHash = nil } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let request = Request(message)
        Task { @MainActor in
            _ = await self.handle(command: request.command, refresh: request.refresh, shelfHash: request.shelfHash, covers: request.covers)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let request = Request(message), reply = Reply(send: replyHandler)
        Task { @MainActor in
            let payload = Payload(values: await self.handle(command: request.command, refresh: request.refresh,
                                                            shelfHash: request.shelfHash, covers: request.covers))
            reply.send(payload.values)
        }
    }

}
