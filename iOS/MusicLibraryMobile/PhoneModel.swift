import Foundation
import MusicLibraryCore
import MusicLibraryGlance
import Network
import Observation
import UIKit

/// The library on the phone: finds it in Documents, loads its snapshot off the main thread, and reloads it when
/// it changes (a sync, or an export dragged in through Finder's Files tab). The snapshot lists the whole library;
/// only the songs whose files are here play, and the rest can be asked for (`requests`, sent at each sync, which
/// starts as soon as the Mac is around). Also connects the player to Last.fm, keeps the play queue across launches,
/// and records plays and likes for the Mac (`outbox`, sent at each sync). Shows the collection (CDs, records and
/// downloads you own, with or without songs) read-only: it's edited on the Mac. Keeps the widgets' and the watch's
/// summary up to date (`glance`, `watch`) and runs their commands (`perform`).
///
/// Until there's a library of your own, it can show the sample library (`showSample`): fictional albums inside the
/// app, opened read-only. What happens in it (likes, plays, the queue) is kept apart (`sampleOutbox`,
/// its own player state), never sent to the Mac or Last.fm, and dropped once your own library arrives.
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
    /// The library from the Mac's iCloud backup, when the app has an iCloud container.
    let cloud = PhoneCloud()
    let concerts = PhoneConcerts()
    /// The Radio DJ, on once the Mac has handed over a Claude API key.
    let radioDJ = PhoneRadioDJ()
    /// Plays and likes since the last sync (and ownership changes from versions that could edit it here).
    @ObservationIgnored let outbox = SyncOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sync-outbox.json"))
    /// The same, for the sample library; never sent anywhere.
    @ObservationIgnored let sampleOutbox = SyncOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sample-outbox.json"))
    /// Downloads and removals not yet applied by the Mac.
    @ObservationIgnored let requestQueue = SyncRequestQueue(url: URL.applicationSupportDirectory.appendingPathComponent("sync-requests.json"))
    /// Liked songs and when: the copy's, with the likes and unlikes made on the phone since the last sync.
    private(set) var likedDates: [Int64: Date] = [:]
    /// Everything you own: the copy's collection, with the ownership changes versions before 1.18 left in the outbox
    /// (`CollectionLegacy.overlay`, the rules the Mac applies them by).
    private(set) var collection = MusicCollection.empty
    /// The collection, searchable (`LibrarySearch`).
    private(set) var collectionIndex = CollectionIndex.empty
    /// Library albums by `SearchIndex.albumKey`.
    private(set) var albumsByKey: [String: AlbumSummary] = [:]
    /// The copy's listening history with the phone's plays since the last sync, and their totals.
    private(set) var plays: [Play] = []
    private(set) var playTotals: [Int64: PlayTotal] = [:]
    /// By `LibrarySnapshot.artistKey` (album artist).
    private(set) var artistPlayTotals: [String: PlayTotal] = [:]
    /// By `SearchIndex.albumKey`.
    private(set) var albumPlayTotals: [String: PlayTotal] = [:]
    /// What the phone asked for that the Mac hasn't applied yet, oldest first.
    private(set) var requests: [SyncRequest] = []
    /// Songs asked for and not here yet.
    private(set) var pendingDownloads: Set<Int64> = []
    /// Songs the Mac's selection puts on the phone that the Mac has only in iCloud (offloaded there): the last Wi-Fi
    /// sync didn't send them, so they come from iCloud (D20). Application Support `icloud-only.json`.
    private var iCloudOnly: Set<Int64> = PhoneModel.loadICloudOnly() {
        didSet { Self.saveICloudOnly(iCloudOnly) }
    }

    /// The song whose details are shown (Song Info).
    var infoTrack: Track?
    /// The Sync screen is showing (a sheet over the tabs); the phone listens for the Mac only while it is.
    var showsSync = false
    /// An album a widget opened (`SearchIndex.albumKey`), pushed on the Collection tab once the library has loaded.
    var pendingAlbumKey: String?
    /// A collection item a widget opened (`GlanceLink.item(id:)`), pushed on the Collection tab once the library has loaded.
    var pendingItemID: String?
    /// A link to open as if a widget had been tapped (Siri and Shortcuts), handled by `RootView`.
    var pendingLink: GlanceLink?

    /// The summary the widgets and the watch show, and the watch connection.
    @ObservationIgnored let glance: GlanceFeed
    @ObservationIgnored let watch: WatchLink

    /// Bumped when the library, the history or the collection changes (Insights recompute).
    private(set) var libraryVersion = 0
    private(set) var historyVersion = 0
    private(set) var collectionVersion = 0
    private(set) var libraryStats: LibraryStats?
    private(set) var listeningStats: ListeningStats?
    private(set) var collectionStats: CollectionStats?
    @ObservationIgnored private var statsVersion = -1
    @ObservationIgnored private var listeningKey: (period: ListeningStats.Period, library: Int, history: Int, at: Date)?
    /// The last 7 days, for Listen Now, kept apart from `listeningStats` so Insights keeps its own period.
    private(set) var weekListening: ListeningStats?
    @ObservationIgnored private var weekListeningKey: (library: Int, history: Int, at: Date)?
    @ObservationIgnored private var collectionKey: (library: Int, collection: Int, history: Int)?

    @ObservationIgnored private var currentPlay: (track: Track, startedAt: Date, tracker: ListenTracker)?
    @ObservationIgnored private var loadedStamp: Stamp?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var restoredPlayerState = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    /// The app's model; widget buttons (`PlaybackCommandCenter`) can need it before SwiftUI has created the app.
    static let shared = PhoneModel()

    var library: LibrarySnapshot? {
        if case .loaded(let s) = state { return s }
        return nil
    }

    /// The library shown is the sample library.
    private(set) var isSample = false

    /// Where the changes made on the phone go: the Mac's outbox, or the sample library's.
    private var activeOutbox: SyncOutbox { isSample ? sampleOutbox : outbox }

    /// The sample library in the app bundle.
    nonisolated static var sampleRoot: URL? { Bundle.main.url(forResource: "SampleLibrary", withExtension: "bundle") }

    /// Shows the sample library while there's no library of your own (until `hideSample` or the first sync).
    private var wantsSample: Bool {
        get { UserDefaults.standard.bool(forKey: "showsSampleLibrary") }
        set { UserDefaults.standard.set(newValue, forKey: "showsSampleLibrary") }
    }

    init() {
        let glance = GlanceFeed()
        self.glance = glance
        watch = WatchLink(store: glance.store)
        sync.onLibraryChanged = { [weak self] in self?.reload() }
        cloud.onLibraryChanged = { [weak self] in self?.reload() }
        cloud.isSyncing = { [weak self] in self?.sync.isBusy ?? false }
        cloud.outgoing = { [weak self] in
            // The sample library's changes never go to the Mac.
            guard let self, !isSample, let id = library?.libraryID else { return nil }
            return PhoneCloud.Outgoing(libraryID: id, events: outbox.events, requests: requestQueue.requests)
        }
        cloud.phone = { [weak self] in (self?.sync.deviceID ?? "", self?.sync.deviceName ?? "") }
        cloud.downloads = { [weak self] in
            guard let self, let library, !isSample else { return [] }
            return library.tracks.filter { pendingDownloads.contains($0.id) || (iCloudOnly.contains($0.id) && !library.isPresent($0)) }
        }
        cloud.macReachable = { [weak self] in self?.sync.macPeer != nil || self?.sync.isBusy == true }
        sync.onSyncStarted = { [weak self] in self?.cloud.stopFetching() }
        sync.onSyncFinished = { [weak self] summary in
            guard let self else { return }
            iCloudOnly = Set(summary.iCloudOnly ?? [])
            // With the Mac nearby too: it couldn't send these.
            if !iCloudOnly.isEmpty { cloud.fetchDownloads(evenWithMac: true) }
        }
        cloud.onApplied = { [weak self] ids in
            self?.outbox.remove(ids)
            self?.requestQueue.remove(ids)
            self?.refreshOverlays()
        }
        sync.pendingEvents = { [weak self] in
            // The sample library's changes never go to the Mac; the Mac's wait until your own library is back.
            guard let self, !isSample else { return ([], [], nil) }
            return (outbox.events, requestQueue.requests, library?.libraryID)
        }
        recoverInterruptedPlay()
        sync.onEventsDelivered = { [weak self] events, requests in
            self?.outbox.remove(events)
            self?.requestQueue.remove(requests)
            self?.refreshOverlays()
        }
        sync.storeConcerts = { [weak self] settings in self?.concerts.adopt(settings) }
        sync.storeRadioDJ = { [weak self] settings in self?.radioDJ.adopt(settings) }
        sync.radioDJUsage = { [weak self] in self?.radioDJ.usage }
        radioDJ.location = { [weak self] in self?.radioDJLocation }
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
            // A DJ preview stops when your own music starts.
            self?.radioDJ.previews.stop()
            if self?.isSample == false { self?.scrobbler.trackStarted(track) }
            self?.startPlay(track)
            self?.savePlayerState()
        }
        player.onProgress = { [weak self] track, position, playing in
            if self?.isSample == false { self?.scrobbler.progress(track, position: position, playing: playing) }
            self?.advancePlay(track, position: position, playing: playing)
        }
        player.onPlaybackEnded = { [weak self] in self?.finishPlay() }
        player.onStateChange = { [weak self] in self?.glance.setNeedsUpdate(full: false) }
        glance.inputs = { [weak self] in self?.glanceInputs }
        glance.onChange = { [weak self] in self?.watch.send($0) }
        glance.onShelfChange = { [weak self] in self?.watch.sendShelf($0) }
        watch.current = { [weak self] in self?.glance.current }
        watch.currentShelf = { [weak self] in self?.glance.shelf }
        watch.perform = { [weak self] in await self?.perform($0) ?? .failed("Music Library isn't ready on the iPhone.") }
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
        let stamp = Stamp.current(in: URL.documentsDirectory) ?? (wantsSample ? Self.sampleRoot.map { Stamp(root: $0) } : nil)
        if case .loaded = state, stamp == loadedStamp { return }
        reload()
    }

    func reload() {
        generation += 1
        let generation = generation
        let documents = URL.documentsDirectory
        let sample = wantsSample
        if library == nil { state = .loading }
        loading = Task.detached(priority: .userInitiated) {
            let (state, stamp, isSample) = Self.load(documents: documents, sample: sample)
            var albumsByKey: [String: AlbumSummary] = [:]
            if case .loaded(let library) = state {
                albumsByKey = Dictionary(library.albums.map { (SearchIndex.albumKey(album: $0.album, artist: $0.artist), $0) },
                                         uniquingKeysWith: { first, _ in first })
            }
            await MainActor.run {
                guard generation == self.generation else { return }
                if isSample != self.isSample { self.switchLibraries(toSample: isSample) }
                // Your own library is here (maybe it arrived while the app wasn't running): the sample is done.
                if !isSample, stamp != nil { self.forgetSample() }
                self.state = state
                self.loadedStamp = stamp
                if case .loaded(let library) = state {
                    self.player.library = library
                    self.restorePlayerState(library)
                }
                self.albumsByKey = albumsByKey
                self.libraryVersion += 1
                self.refreshOverlays()
            }
        }
    }

    // MARK: Sample library

    func showSample() {
        wantsSample = true
        reload()
    }

    /// Hides the sample library and forgets what happened in it.
    func hideSample() {
        wantsSample = false
        reload()
    }

    /// Between the sample library and your own, nothing carries over: the queue is emptied, and leaving the sample
    /// drops its likes, plays and queue.
    private func switchLibraries(toSample: Bool) {
        finishPlay()
        player.clear()
        restoredPlayerState = false
        isSample = toSample
        if !toSample { forgetSample() }
    }

    private func forgetSample() {
        wantsSample = false
        sampleOutbox.remove(Set(sampleOutbox.events.map(\.id)))
        try? FileManager.default.removeItem(at: Self.playerStateURL(sample: true))
    }

    /// Loads the library if it isn't yet: a widget button or the watch can start the app in the background, where
    /// it never becomes active.
    private func ensureLoaded() async {
        guard library == nil else { return }
        if loading == nil { reload() }
        await loading?.value
    }

    nonisolated private static func load(documents: URL, sample: Bool) -> (State, Stamp?, isSample: Bool) {
        guard let stamp = Stamp.current(in: documents) else {
            guard sample, let root = sampleRoot else { return (.missing, nil, false) }
            do {
                return (.loaded(try LibrarySnapshot(root: root, datesRelativeToNow: true)), Stamp(root: root), true)
            } catch {
                return (.failed(error.localizedDescription), nil, false)
            }
        }
        // Tens of GB of music shouldn't go into iCloud backups; the Mac has the library.
        var root = stamp.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        do {
            return (.loaded(try LibrarySnapshot(root: stamp.root)), stamp, false)
        } catch {
            return (.failed(error.localizedDescription), stamp, false)
        }
    }

    // MARK: Overlays

    /// The copy's likes, ownership, history and requests with what happened on the phone since.
    private func refreshOverlays() {
        let events = activeOutbox.events
        likedDates = SyncOutbox.liked(base: library?.likedDates ?? [:], events: events)
        refreshCollection(events)
        refreshPlays(events)
        refreshRequests()
    }

    /// The copy's collection with the ownership changes still in the outbox. Only phones before 1.18 made those, so
    /// usually there are none and the copy's collection is used as it is.
    private func refreshCollection(_ events: [SyncEvent]) {
        let (collection, index) = library.map { Self.overlaid($0, events: events) } ?? (.empty, .empty)
        self.collection = collection
        collectionIndex = index
        collectionVersion += 1
        glance.setNeedsUpdate()
        LabelShortcuts.update(for: collection)
    }

    nonisolated static func overlaid(_ library: LibrarySnapshot, events: [SyncEvent]) -> (MusicCollection, CollectionIndex) {
        let changes = events.filter { if case .purchase = $0.kind { true } else { false } }
        guard !changes.isEmpty else { return (library.collection, library.collectionIndex) }
        let stored = library.collection.items.filter { $0.origin == .stored }
        let items = CollectionLegacy.overlay(events: changes, on: stored) { id in
            library.track(id: id).map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) }
        }
        let collection = MusicCollection(items: items, songPurchases: library.songPurchases, tracks: library.tracks,
                                         unreadable: library.labelUnreadable)
        return (collection, CollectionIndex(collection: collection, tracks: library.tracks, albumInfos: library.albumInfos,
                                            index: library.index))
    }

    private func refreshPlays(_ events: [SyncEvent]) {
        var plays = library?.plays ?? []
        var totals = library?.playTotals ?? [:]
        for e in events {
            guard case .play(let listened, let counted) = e.kind, library?.track(id: e.trackID) != nil else { continue }
            plays.append(Play(trackId: e.trackID, startedAt: e.at, listened: listened, counted: counted))
            totals[e.trackID] = (totals[e.trackID] ?? PlayTotal()) + PlayTotal(plays: counted ? 1 : 0, listened: listened, lastPlayed: e.at)
        }
        var artists: [String: PlayTotal] = [:], albums: [String: PlayTotal] = [:]
        if let library {
            for (id, total) in totals {
                guard let t = library.track(id: id) else { continue }
                let key = LibrarySnapshot.artistKey(t.effectiveAlbumArtist)
                artists[key] = (artists[key] ?? PlayTotal()) + total
                let albumKey = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
                albums[albumKey] = (albums[albumKey] ?? PlayTotal()) + total
            }
        }
        self.plays = plays
        playTotals = totals
        artistPlayTotals = artists
        albumPlayTotals = albums
        historyVersion += 1
        glance.setNeedsUpdate()
    }

    // MARK: Likes and plays

    func isLiked(_ track: Track) -> Bool { likedDates[track.id] != nil }

    /// Liked songs, most recently liked first.
    var likedTracks: [Track] {
        guard let library else { return [] }
        return likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { library.track(id: $0.key) }
    }

    func toggleLike(_ track: Track) {
        activeOutbox.append(SyncEvent(track: track, at: Date(), kind: .like(!isLiked(track))))
        likedDates = SyncOutbox.liked(base: library?.likedDates ?? [:], events: activeOutbox.events)
        cloud.changesPending()
        glance.setNeedsUpdate()
    }

    func artistPlayTotal(_ name: String) -> PlayTotal { artistPlayTotals[LibrarySnapshot.artistKey(name)] ?? PlayTotal() }

    // MARK: Collection

    func item(id: String) -> CollectionItem? { collection.item(id: id) }

    /// The items with a label, once the library has loaded (Siri can start the app in the background); nil without a
    /// library.
    func items(labeled sticker: Sticker) async -> [CollectionItem]? {
        await ensureLoaded()
        guard library != nil else { return nil }
        return collection.items(at: sticker)
    }

    /// The labels on items in the collection, in order (Siri's phrase values), once the library has loaded.
    func labelsInUse() async -> [Sticker] {
        await ensureLoaded()
        return Set(collection.items.compactMap(\.sticker)).sorted()
    }

    /// How a library album's cover shows the copies you own.
    func copyMark(for album: AlbumSummary) -> CopyMark {
        collection.mark(albumKey: SearchIndex.albumKey(album: album.album, artist: album.artist))
    }

    /// How an item's own cover shows it.
    func copyMark(for item: CollectionItem) -> CopyMark { collection.mark(item: item) }

    /// The library album holding an item's digital copy, when it has songs.
    func album(for item: CollectionItem) -> AlbumSummary? { albumsByKey[item.albumKey] }

    /// What to ask the Mac for to get an item's songs: its library album.
    func exportItem(for item: CollectionItem) -> ExportItem? {
        album(for: item).map { .album(album: $0.album, artist: $0.artist) }
    }

    /// CDs and records (the shelf's; downloads are digital already) with a digital copy whose songs aren't all
    /// on this iPhone, one per album, in shelf order.
    var readyToDownload: [CollectionItem] {
        guard library != nil, !isSample else { return [] }
        var seen = Set<String>()
        return collection.items.filter { item in
            guard item.medium.isPhysical, collection.digitalState(item).hasMusic, !seen.contains(item.albumKey) else { return false }
            let tracks = collection.libraryTracks(item)
            guard !tracks.isEmpty, availability(tracks) != .onPhone else { return false }
            seen.insert(item.albumKey)
            return true
        }
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
    func download(_ item: ExportItem) { download([item]) }

    /// Asks for all of these at once: from the Mac when it's reachable, else from iCloud when the songs are backed up
    /// there, else they wait (D16). The request goes to the Mac either way, so its list keeps them.
    func download(_ items: [ExportItem]) {
        guard !isSample, !items.isEmpty else { return }
        for item in items { requestQueue.add(SyncRequest(item: item, include: true)) }
        refreshRequests()
        sync.requestSync()
        cloud.fetchDownloads()
    }

    private static var iCloudOnlyURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("icloud-only.json")
    }

    private static func loadICloudOnly() -> Set<Int64> {
        guard let data = try? Data(contentsOf: iCloudOnlyURL), data.count <= 8 << 20 else { return [] }
        return Set((try? JSONDecoder().decode([Int64].self, from: data)) ?? [])
    }

    private static func saveICloudOnly(_ ids: Set<Int64>) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids.sorted()).write(to: iCloudOnlyURL, options: .atomic)
    }

    /// Music can be downloaded: from a paired Mac, or from iCloud.
    var canDownload: Bool { sync.isPaired || cloud.isUsable }

    /// Deletes the item's songs from the phone now (covers stay, so it can still be browsed) and asks the Mac to
    /// stop syncing them.
    func remove(_ item: ExportItem) {
        guard let library, !isSample else { return }
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
        requests = isSample ? [] : requestQueue.requests
        cloud.changesPending()
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

    /// The last 7 days for Listen Now, computed off the main thread unless it's up to date (refreshed after a few
    /// minutes like `loadListening`).
    func loadWeekListening() {
        if let k = weekListeningKey, k.library == libraryVersion, k.history == historyVersion,
           Date().timeIntervalSince(k.at) < 300 { return }
        guard let library else { return }
        let key = (library: libraryVersion, history: historyVersion, at: Date())
        weekListeningKey = key
        let plays = plays
        Task.detached(priority: .utility) {
            let stats = ListeningStats(plays: plays, tracks: library.tracks, period: .week, now: key.at)
            await MainActor.run {
                guard self.weekListeningKey?.at == key.at else { return }
                self.weekListening = stats
            }
        }
    }

    /// The album Listen Now leads with: the one playing, else the one played last, else the one added last.
    var listenNowAlbum: AlbumSummary? {
        guard let library else { return nil }
        if let t = player.currentTrack,
           let a = library.album(forKey: SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)) {
            return a
        }
        if let key = albumPlayTotals.compactMap({ k, v in v.lastPlayed.map { (k, $0) } }).max(by: { $0.1 < $1.1 })?.0,
           let a = library.album(forKey: key) {
            return a
        }
        let added = library.tracks.max { $0.addedAt < $1.addedAt }
        return added.flatMap { library.album(forKey: SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist)) }
    }

    /// Albums by when they were last played, most recent first.
    func recentlyPlayedAlbums(limit: Int, excluding key: String? = nil) -> [AlbumSummary] {
        guard let library else { return [] }
        return albumPlayTotals.compactMap { k, total in total.lastPlayed.map { (k, $0) } }
            .filter { $0.0 != key }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .compactMap { library.album(forKey: $0.0) }
    }

    /// The Owned pane: computed off the main thread when the library, the collection or the history changed.
    func loadCollectionStats() {
        let key = (library: libraryVersion, collection: collectionVersion, history: historyVersion)
        if let k = collectionKey, k == key, collectionStats != nil { return }
        guard let library else { return }
        collectionKey = key
        let collection = collection, totals = playTotals
        Task.detached(priority: .userInitiated) {
            let stats = Self.collectionStats(collection: collection, library: library, playTotals: totals)
            await MainActor.run {
                guard let k = self.collectionKey, k == key else { return }
                self.collectionStats = stats
            }
        }
    }

    nonisolated static func collectionStats(collection: MusicCollection, library: LibrarySnapshot,
                                            playTotals: [Int64: PlayTotal]) -> CollectionStats {
        CollectionStats(collection: collection, tracks: library.tracks, playTotals: playTotals, albumInfos: library.albumInfos)
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
        activeOutbox.append(event)
        refreshPlays(activeOutbox.events)
        cloud.changesPending()
    }

    private var currentPlayEvent: SyncEvent? {
        guard let play = currentPlay, play.tracker.listened >= 1 else { return nil }
        return SyncEvent(track: play.track, at: play.startedAt, kind: .play(listened: play.tracker.listened, counted: play.tracker.hasScrobbled))
    }

    /// iOS may end the app in the background without warning, so the play in progress is kept here when it goes to
    /// the background, and saved at the next launch if the app didn't get to finish it.
    nonisolated static var interruptedPlayURL: URL { URL.applicationSupportDirectory.appendingPathComponent("interrupted-play.json") }

    func noteInterruptedPlay() {
        // It would be recovered into the Mac's outbox.
        guard !isSample, let event = currentPlayEvent, let data = try? JSONEncoder().encode(event) else { return }
        try? data.write(to: Self.interruptedPlayURL, options: .atomic)
    }

    private func recoverInterruptedPlay() {
        guard let data = try? Data(contentsOf: Self.interruptedPlayURL) else { return }
        try? FileManager.default.removeItem(at: Self.interruptedPlayURL)
        if let event = try? JSONDecoder().decode(SyncEvent.self, from: data) { outbox.append(event) }
    }

    // MARK: Widgets and the watch

    private var glanceInputs: GlanceFeed.Inputs? {
        guard let library else {
            // Hiding the sample library leaves nothing to show; the widgets shouldn't keep showing it.
            guard case .missing = state else { return nil }
            return GlanceFeed.Inputs(root: URL.documentsDirectory, tracks: [], present: [], plays: [], likedDates: [:],
                                     collection: .empty, playTotals: [:], playing: nil)
        }
        let playing = player.currentTrack.map { t in
            Glance.Playing(track: t, isPlaying: player.isPlaying, position: player.currentTime,
                           duration: player.duration > 0 ? player.duration : t.duration, next: player.nextTrack)
        }
        return GlanceFeed.Inputs(root: library.root, tracks: library.tracks, present: library.presentIDs, plays: plays,
                                 likedDates: likedDates, collection: collection, playTotals: playTotals, playing: playing)
    }

    /// Runs a command from a widget button or the watch.
    func perform(_ command: GlanceCommand) async -> GlanceCommandResult {
        await ensureLoaded()
        guard let library else { return .failed("Nothing has synced to the iPhone yet.") }
        switch command {
        case .playPause:
            guard player.currentTrack != nil else { return .failed("Nothing is queued on the iPhone.") }
            player.togglePlayPause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .toggleLike:
            guard let track = player.currentTrack else { return .failed("Nothing is playing.") }
            toggleLike(track)
        case .playAlbum(var key):
            // A collection item's link: its album.
            if let id = GlanceLink.album(key: key).itemID {
                guard let item = collection.item(id: id) else { return .failed("You don't own that anymore.") }
                key = item.albumKey
            }
            guard let album = albumsByKey[key] ?? library.album(forKey: key) else {
                // On the shelf, with no songs in the library (a CD not ripped yet, a record).
                return .failed(collection.copies(albumKey: key).isEmpty ? "That album isn't in your digital collection anymore." : "No digital copy")
            }
            let tracks = library.playable(library.tracks(album: album))
            guard !tracks.isEmpty else { return .failed("“\(album.album)” isn't on the iPhone.") }
            player.play(queue: tracks, source: album.album)
        case .playSong(let id):
            guard let track = library.track(id: id), library.isPresent(track) else { return .failed("That song isn't on the iPhone.") }
            let album = library.album(of: track).map { library.playable(library.tracks(album: $0)) } ?? [track]
            player.play(queue: album, startAt: album.firstIndex { $0.id == id } ?? 0, source: track.album)
        case .shuffleLiked:
            let tracks = library.playable(likedTracks).shuffled()
            guard !tracks.isEmpty else { return .failed("No liked songs are on the iPhone.") }
            player.play(queue: tracks, source: "Liked Songs")
        case .shuffleAll:
            let tracks = library.presentTracks.shuffled()
            guard !tracks.isEmpty else { return .failed("No music is on the iPhone yet.") }
            player.play(queue: tracks, source: "On This iPhone")
        }
        // The app may be in the background, where iOS can end it without warning.
        savePlayerState()
        await glance.updateNow()
        return .done
    }

    // MARK: Player state

    /// The queue and position, saved at each song change and when the app goes to the background, and put back
    /// (paused) the first time the library loads.
    nonisolated static func playerStateURL(sample: Bool) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(sample ? "sample-player-state.json" : "player-state.json")
    }

    func savePlayerState() {
        guard library != nil else { return }
        let url = Self.playerStateURL(sample: isSample)
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
        guard let data = try? Data(contentsOf: Self.playerStateURL(sample: isSample)),
              let snapshot = try? JSONDecoder().decode(PlayQueue.Snapshot.self, from: data) else { return }
        player.restore(snapshot) { id in library.track(id: id).flatMap { library.isPresent($0) ? $0 : nil } }
    }
}
