import AppKit
import Foundation
import MusicLibraryCore
import SwiftUI

enum SidebarItem: Hashable {
    case songs, albums, artists, insights, musicDNA, importQueue, exportList
    case playlist(Int64)
    case smartPlaylist(Int64)
    case cd(String)
}

struct SmartPlaylistDraft: Identifiable {
    var id: Int64?
    var name: String
    var query: String
}

struct ExportState: Equatable {
    var title: String
    var done = 0
    var total = 0
    var error: String?
    /// Set when an export to the library layout finishes; playlist exports close the sheet instead.
    var summary: LibraryExportSummary?
    var destination: URL?
    /// The removable drive holding `destination`, offered for ejecting when the export is done.
    var ejectableVolume: URL?
}

@MainActor @Observable
final class AppModel {
    private enum Keys {
        static let root = "libraryRoot"
        static let contact = "musicBrainzContact"
        static let acoustID = "acoustIDKey"
        static let autoMatch = "autoMatch"
        static let matchRate = "matchOutputRate"
        static let matchBitDepth = "matchOutputBitDepth"
        static let ejectAfterRip = "ejectAfterRip"
        static let recentSearches = "recentSearches"
        static let theme = "theme"
        static let dnaDepth = "musicDNADepth"
        static let exportList = "exportList"
        static let exportDatabase = "exportBackupDatabase"
        static let exportPlaylistFiles = "exportPlaylistFiles"
        static let exportDestination = "exportDestination"
        static let showsQueue = "showsQueue"
    }

    var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: Keys.theme)
            applyAppearance()
        }
    }
    var theme: Theme { Theme.named(themeID) }

    var sidebar: SidebarItem? = .songs {
        didSet {
            guard sidebar != oldValue else { return }
            nowPlayingExpanded = false
            navigationPath = NavigationPath()
            // Picking a sidebar item leaves the search results page.
            if !searchText.isEmpty { searchText = "" }
        }
    }
    var nowPlayingExpanded = false
    /// The queue in the window's inspector.
    var showsQueue = UserDefaults.standard.bool(forKey: Keys.showsQueue) {
        didSet { UserDefaults.standard.set(showsQueue, forKey: Keys.showsQueue) }
    }
    /// Albums and artists pushed onto the content area.
    var navigationPath = NavigationPath()
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            if !searchText.isEmpty { nowPlayingExpanded = false }
            navigationPath = NavigationPath()
            searchAutocorrect = true
            runSearch()
        }
    }
    /// Cleared when the user asks for their exact text after a spelling correction.
    private(set) var searchAutocorrect = true
    private(set) var searchResults = SearchResults()
    private(set) var recentSearches: [String]
    /// All tracks in library order.
    private(set) var tracks: [Track] = []
    /// Rebuilt in the background whenever the library changes.
    private(set) var index = SearchIndex.empty
    /// Bumped whenever `index` is replaced, so views can refresh derived data.
    private(set) var libraryVersion = 0
    private(set) var smartPlaylists: [SmartPlaylist] = []
    /// Who worked with whom, rebuilt with the search index.
    private(set) var collaborations = CollaborationGraph.empty
    /// Tracks by ID, for looking up graph and history results.
    private(set) var trackByID: [Int64: Track] = [:]
    /// The person at the center of Music DNA, and the ones visited before (for Back).
    private(set) var dnaCenter: String?
    private(set) var dnaHistory: [String] = []
    var dnaDepth: Int { didSet { UserDefaults.standard.set(dnaDepth, forKey: Keys.dnaDepth) } }
    /// Listening history per track.
    private(set) var playTotals: [Int64: PlayTotal] = [:]
    /// Listening history per album artist (keyed by `ArtistInfoStore.key`).
    private(set) var artistPlayTotals: [String: PlayTotal] = [:]
    /// Listening history per album (keyed by `AlbumInfoStore.key`).
    private(set) var albumPlayTotals: [String: PlayTotal] = [:]
    /// When each album last got a track added (keyed by `AlbumInfoStore.key`).
    private(set) var albumAddedDates: [String: Date] = [:]
    private(set) var smartPlaylistCounts: [Int64: Int] = [:]
    var smartPlaylistDraft: SmartPlaylistDraft?
    private(set) var stats: LibraryStats?
    private(set) var statsVersion = -1
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    /// Listening stats for the period last asked for.
    private(set) var listening: ListeningStats?
    /// Bumped whenever a listen is recorded.
    private(set) var historyVersion = 0
    @ObservationIgnored private var listeningRequest: (period: ListeningStats.Period, library: Int, history: Int, at: Date)?
    @ObservationIgnored private var listeningTask: Task<Void, Never>?
    private(set) var albums: [AlbumSummary] = []
    private(set) var artists: [ArtistSummary] = []
    private(set) var playlists: [Playlist] = []
    private(set) var totalTracks = 0
    private(set) var libraryRoot: URL
    private(set) var database: Database?
    private(set) var tools = ToolLocator()
    var errorMessage: String?
    var renamingPlaylistID: Int64?
    var exportState: ExportState?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// What "Export…" on the Export List page copies (albums, songs, artists, playlists).
    private(set) var exportList: [ExportItem] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(exportList), forKey: Keys.exportList) }
    }
    var exportBackupDatabase: Bool { didSet { UserDefaults.standard.set(exportBackupDatabase, forKey: Keys.exportDatabase) } }
    var exportPlaylistFiles: Bool { didSet { UserDefaults.standard.set(exportPlaylistFiles, forKey: Keys.exportPlaylistFiles) } }
    /// Where the Export List is copied to (e.g. a USB music player), kept between launches.
    private(set) var exportDestination: URL? {
        didSet { UserDefaults.standard.set(exportDestination?.path, forKey: Keys.exportDestination) }
    }
    /// Bumped when an export ends, so views showing the destination's contents rescan it.
    private(set) var exportRevision = 0

    var mbContact: String { didSet { UserDefaults.standard.set(mbContact, forKey: Keys.contact); applyContact() } }
    var acoustIDKey: String { didSet { KeychainStore.app.set(acoustIDKey, for: Keys.acoustID) } }
    var autoMatch: Bool { didSet { UserDefaults.standard.set(autoMatch, forKey: Keys.autoMatch) } }
    var ejectAfterRip: Bool { didSet { UserDefaults.standard.set(ejectAfterRip, forKey: Keys.ejectAfterRip) } }
    var matchOutputRate: Bool {
        didSet {
            UserDefaults.standard.set(matchOutputRate, forKey: Keys.matchRate)
            player.matchOutputRate = matchOutputRate
            if !matchOutputRate {
                player.outputState = nil
                let matcher = outputMatcher
                Task.detached { matcher.restoreAll() }
            }
        }
    }
    var matchOutputBitDepth: Bool {
        didSet {
            UserDefaults.standard.set(matchOutputBitDepth, forKey: Keys.matchBitDepth)
            player.matchOutputBitDepth = matchOutputBitDepth
        }
    }

    @ObservationIgnored let musicBrainz: MusicBrainzClient
    @ObservationIgnored let coverArt = CoverArtClient()
    @ObservationIgnored let outputMatcher = OutputMatcher()
    @ObservationIgnored let player: Player
    @ObservationIgnored let scrobbler = Scrobbler()
    @ObservationIgnored let artistInfo = ArtistInfoStore()
    @ObservationIgnored let albumInfo = AlbumInfoStore()
    @ObservationIgnored private var currentPlay: (track: Track, startedAt: Date, tracker: ListenTracker)?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var importer: ImportController!
    @ObservationIgnored private(set) var cd: CDController!
    @ObservationIgnored private var keyMonitor: Any?

    init() {
        let defaults = UserDefaults.standard
        let root = defaults.string(forKey: Keys.root).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryLocation.defaultRoot
        libraryRoot = root
        mbContact = defaults.string(forKey: Keys.contact) ?? ""
        acoustIDKey = KeychainStore.app.migratedString(for: Keys.acoustID, from: defaults, key: Keys.acoustID) ?? ""
        autoMatch = defaults.object(forKey: Keys.autoMatch) == nil ? true : defaults.bool(forKey: Keys.autoMatch)
        musicBrainz = MusicBrainzClient(contact: defaults.string(forKey: Keys.contact) ?? "")
        recentSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []
        themeID = defaults.string(forKey: Keys.theme) ?? Theme.system.id
        dnaDepth = min(3, max(1, defaults.object(forKey: Keys.dnaDepth) == nil ? 2 : defaults.integer(forKey: Keys.dnaDepth)))
        exportList = defaults.data(forKey: Keys.exportList).flatMap { try? JSONDecoder().decode([ExportItem].self, from: $0) } ?? []
        exportBackupDatabase = defaults.bool(forKey: Keys.exportDatabase)
        exportPlaylistFiles = defaults.object(forKey: Keys.exportPlaylistFiles) == nil ? true : defaults.bool(forKey: Keys.exportPlaylistFiles)
        exportDestination = defaults.string(forKey: Keys.exportDestination).map { URL(fileURLWithPath: $0, isDirectory: true) }
        ejectAfterRip = defaults.object(forKey: Keys.ejectAfterRip) == nil ? true : defaults.bool(forKey: Keys.ejectAfterRip)
        matchOutputRate = defaults.object(forKey: Keys.matchRate) == nil ? true : defaults.bool(forKey: Keys.matchRate)
        matchOutputBitDepth = defaults.object(forKey: Keys.matchBitDepth) == nil ? true : defaults.bool(forKey: Keys.matchBitDepth)
        player = Player(root: root, matcher: outputMatcher)
        player.matchOutputRate = matchOutputRate
        player.matchOutputBitDepth = matchOutputBitDepth
        player.formatProvider = { [unowned self] track in await self.probeAudioFormat(track) }
        let scrobbler = scrobbler
        player.onTrackStart = { [unowned self] track in
            scrobbler.trackStarted(track)
            self.startPlay(track)
        }
        player.onProgress = { [unowned self] track, position, playing in
            scrobbler.progress(track, position: position, playing: playing)
            self.advancePlay(track, position: position, playing: playing)
        }
        player.onPlaybackEnded = { [unowned self] in self.finishPlay() }
        artistInfo.onAutoSyncEnabled = { [unowned self] in self.syncArtistInfo() }
        importer = ImportController(model: self)
        cd = CDController(model: self)
        let matcher = outputMatcher
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPlay() }
            matcher.restoreAll()
        }
        applyAppearance()
        openLibrary()
        installSpaceBarMonitor()
        cd.start()
    }

    // MARK: Appearance

    /// Menus, sheets and the Settings window follow a theme that only comes in light or dark.
    func applyAppearance() {
        switch theme.forcedDark {
        case true?: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case false?: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case nil: NSApplication.shared.appearance = nil
        }
    }

    // MARK: Tools

    var ffmpegAvailable: Bool { tools.ffmpeg != nil && tools.ffprobe != nil }
    var acoustID: AcoustIDClient? { AcoustIDClient(apiKey: acoustIDKey, tools: tools) }
    func refreshTools() { tools = ToolLocator() }

    private func applyContact() {
        let contact = mbContact
        Task { await musicBrainz.setContact(contact) }
    }

    // MARK: Library

    var importService: ImportService? {
        database.map { ImportService(root: libraryRoot, database: $0, tools: tools) }
    }

    private func openLibrary() {
        do {
            database = try LibraryLocation.openDatabase(root: libraryRoot)
            player.root = libraryRoot
            artistInfo.open(database: database, root: libraryRoot)
            albumInfo.open(database: database)
            reloadLibrary()
            Task { await backfillAudioFormats() }
        } catch {
            database = nil
            errorMessage = error.localizedDescription
        }
    }

    func probeAudioFormat(_ track: Track) async -> AudioFormat? {
        guard let db = database, tools.ffprobe != nil else { return nil }
        guard let info = try? await TagReader(tools: tools).read(track.fileURL(root: libraryRoot)), let audio = info.audio else { return nil }
        try? db.updateAudioFormat(id: track.id, audio)
        return audio
    }

    private func backfillAudioFormats() async {
        guard let db = database, tools.ffprobe != nil, let missing = try? db.tracksMissingAudioFormat(), !missing.isEmpty else { return }
        let root = libraryRoot
        let reader = TagReader(tools: tools)
        var updated = false
        for track in missing {
            guard database === db else { return }
            if let info = try? await reader.read(track.fileURL(root: root)), let audio = info.audio {
                try? db.updateAudioFormat(id: track.id, audio)
                updated = true
            }
        }
        if updated, database === db { reloadLibrary() }
    }

    func setLibraryRoot(_ url: URL) {
        player.stop()
        artistInfo.cancel()
        albumInfo.cancel()
        libraryRoot = url
        UserDefaults.standard.set(url.path, forKey: Keys.root)
        database = nil
        tracks = []; albums = []; artists = []; playlists = []; smartPlaylists = []; totalTracks = 0
        playTotals = [:]; artistPlayTotals = [:]; albumPlayTotals = [:]; albumAddedDates = [:]
        index = .empty; searchResults = SearchResults(); stats = nil; statsVersion = -1
        listening = nil; listeningRequest = nil
        openLibrary()
    }

    func reloadLibrary() {
        guard let db = database else { return }
        do {
            tracks = try db.fetchAllTracks()
            albums = try db.albums()
            artists = try db.artists()
            playlists = try db.playlists()
            smartPlaylists = try db.smartPlaylists()
            playTotals = try db.playTotals()
            totalTracks = tracks.count
            trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            recomputeGroupTotals()
        } catch {
            errorMessage = error.localizedDescription
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        indexGeneration += 1
        let generation = indexGeneration
        let all = tracks
        let root = libraryRoot
        let smart = smartPlaylists
        Task.detached(priority: .userInitiated) {
            let covers = CoverLookup(root: root)
            let index = SearchIndex(tracks: all, hasCover: covers.hasCover)
            let graph = CollaborationGraph(tracks: all)
            let counts = Dictionary(uniqueKeysWithValues: smart.map { ($0.id, index.tracks(matching: SearchQuery.parse($0.query)).count) })
            await MainActor.run { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                self.index = index
                self.collaborations = graph
                self.smartPlaylistCounts = counts
                self.libraryVersion += 1
                self.runSearch()
                self.syncArtistInfo()
            }
        }
    }

    // MARK: Listening history

    private func startPlay(_ track: Track) {
        finishPlay()
        currentPlay = (track, Date(), ListenTracker(duration: track.duration))
    }

    private func advancePlay(_ track: Track, position: Double, playing: Bool) {
        guard currentPlay?.track.id == track.id else { return }
        _ = currentPlay?.tracker.advance(to: position, playing: playing)
    }

    /// Saves the play in progress, if any listening happened.
    func finishPlay() {
        guard let play = currentPlay else { return }
        currentPlay = nil
        let listened = play.tracker.listened
        guard listened >= 1, let db = database else { return }
        let counted = play.tracker.hasScrobbled
        do {
            try db.recordPlay(trackId: play.track.id, startedAt: play.startedAt, listened: listened, counted: counted)
        } catch {
            return  // e.g. the track was removed meanwhile
        }
        let delta = PlayTotal(plays: counted ? 1 : 0, listened: listened, lastPlayed: play.startedAt)
        playTotals[play.track.id] = (playTotals[play.track.id] ?? PlayTotal()) + delta
        let key = ArtistInfoStore.key(play.track.effectiveAlbumArtist)
        artistPlayTotals[key] = (artistPlayTotals[key] ?? PlayTotal()) + delta
        let albumKey = SearchIndex.albumKey(album: play.track.album, artist: play.track.effectiveAlbumArtist)
        albumPlayTotals[albumKey] = (albumPlayTotals[albumKey] ?? PlayTotal()) + delta
        historyVersion += 1
    }

    /// Per-artist and per-album aggregates of the library and its listening history.
    private func recomputeGroupTotals() {
        var artists: [String: PlayTotal] = [:], albums: [String: PlayTotal] = [:]
        var added: [String: Date] = [:]
        for t in tracks {
            let albumKey = SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)
            added[albumKey] = max(added[albumKey] ?? t.addedAt, t.addedAt)
            guard let p = playTotals[t.id] else { continue }
            let key = ArtistInfoStore.key(t.effectiveAlbumArtist)
            artists[key] = (artists[key] ?? PlayTotal()) + p
            albums[albumKey] = (albums[albumKey] ?? PlayTotal()) + p
        }
        artistPlayTotals = artists
        albumPlayTotals = albums
        albumAddedDates = added
    }

    // MARK: Artists

    func tracks(ofArtist name: String) -> [Track] {
        let key = ArtistInfoStore.key(name)
        return tracks.filter { ArtistInfoStore.key($0.effectiveAlbumArtist) == key }
    }

    func albums(forArtist name: String) -> [AlbumSummary] {
        (try? database?.albums(artist: name)) ?? []
    }

    /// MusicBrainz artist IDs from an artist's tags, most common first.
    private func taggedArtistIds(_ tracks: [Track]) -> [String] {
        var counts: [String: Int] = [:]
        for t in tracks {
            let x = t.metadata.extended
            for id in (x.mbAlbumArtistIds.isEmpty ? x.mbArtistIds : x.mbAlbumArtistIds) { counts[id, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private var artistFetcher: InfoFetcher {
        let lastfm = scrobbler.hasCredentials ? LastFMClient(apiKey: scrobbler.apiKey, secret: scrobbler.sharedSecret) : nil
        return InfoFetcher(musicBrainz: musicBrainz, lastfm: lastfm, lastfmUser: scrobbler.session?.username)
    }

    private func artistRequests(_ names: [String]) -> [(name: String, ids: [String])] {
        var byKey: [String: [Track]] = [:]
        for t in tracks { byKey[ArtistInfoStore.key(t.effectiveAlbumArtist), default: []].append(t) }
        return names.map { ($0, taggedArtistIds(byKey[ArtistInfoStore.key($0)] ?? [])) }
    }

    /// Fetches info for artists that don't have it yet (when automatic downloads are on).
    func syncArtistInfo() {
        guard artistInfo.autoSync, database != nil else { return }
        artistInfo.syncMissing(artistRequests(artists.map(\.name)), fetcher: artistFetcher)
        albumInfo.syncMissing(albums.map(albumRequest), fetcher: artistFetcher)
    }

    // MARK: Albums

    func tracks(of album: AlbumSummary) -> [Track] { tracks(ofAlbumKey: AlbumInfoStore.key(album)) }

    func tracks(ofAlbumKey key: String) -> [Track] {
        tracks.filter { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) == key }
            .sorted { (($0.metadata.discNo ?? 1), ($0.trackNo ?? 0)) < (($1.metadata.discNo ?? 1), ($1.trackNo ?? 0)) }
    }

    /// The release and release group most of the album's tracks were matched to.
    private func albumRequest(_ album: AlbumSummary) -> AlbumInfoStore.Request {
        let ts = tracks(of: album)
        func mostCommon(_ values: [String?]) -> String? {
            let counts = values.compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        return AlbumInfoStore.Request(key: AlbumInfoStore.key(album), title: album.album, artist: album.artist,
                                      releaseGroupId: mostCommon(ts.map { $0.metadata.extended.mbReleaseGroupId }),
                                      releaseId: mostCommon(ts.map(\.metadata.mbReleaseId)))
    }

    /// Fetches info for an album being viewed, if it isn't cached (and downloads are on).
    func ensureAlbumInfo(_ album: AlbumSummary) {
        guard artistInfo.autoSync, !album.album.isEmpty else { return }
        albumInfo.ensure(albumRequest(album), fetcher: artistFetcher)
    }

    func refreshAlbumInfo(_ album: AlbumSummary) {
        albumInfo.refresh([albumRequest(album)], fetcher: artistFetcher)
    }

    func artistSummary(named name: String) -> ArtistSummary? {
        let key = ArtistInfoStore.key(name)
        return artists.first { ArtistInfoStore.key($0.name) == key }
    }

    func refreshArtistInfo(_ names: [String]) {
        artistInfo.refresh(artistRequests(names), fetcher: artistFetcher)
    }

    // MARK: Music DNA

    /// Opens Music DNA centered on someone from the credits.
    func showMusicDNA(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        nowPlayingExpanded = false
        if sidebar != .musicDNA { sidebar = .musicDNA }
        if !searchText.isEmpty { searchText = "" }
        navigationPath = NavigationPath()
        guard CollaborationGraph.key(name) != dnaCenter.map(CollaborationGraph.key) else { return }
        if let current = dnaCenter {
            dnaHistory.append(current)
            if dnaHistory.count > 50 { dnaHistory.removeFirst() }
        }
        dnaCenter = name
    }

    func musicDNABack() {
        guard let previous = dnaHistory.popLast() else { return }
        dnaCenter = previous
    }

    func clearMusicDNA() {
        if let current = dnaCenter { dnaHistory.append(current) }
        dnaCenter = nil
    }

    /// Everyone credited on a track, for "Music DNA" menus.
    func people(on track: Track) -> [String] {
        let m = track.metadata, x = m.extended
        var names = CollaborationGraph.splitArtists(m.artist) + x.credits.map(\.name)
        for field in [m.composer, x.lyricist, x.writer, x.arranger, x.conductor, x.producer, x.engineer, x.mixer] {
            names += CollaborationGraph.splitNames(field)
        }
        var seen = Set<String>()
        return names.filter { collaborations.person(named: $0) != nil && seen.insert(CollaborationGraph.key($0)).inserted }
    }

    // MARK: Search

    private func runSearch() {
        searchResults = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? SearchResults() : index.search(searchText, autocorrect: searchAutocorrect)
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var searchCompletions: [SearchCompletion] { index.completions(for: searchText) }

    /// Show results for exactly what was typed, skipping spelling correction.
    func searchExactly() {
        searchAutocorrect = false
        runSearch()
    }

    /// Replaces the search with `text` (e.g. from Insights).
    func search(_ text: String) {
        nowPlayingExpanded = false
        searchText = text
        recordRecentSearch()
    }

    /// Adds a filter to the current search unless it's already there.
    func refineSearch(with term: String) {
        let current = searchText.trimmingCharacters(in: .whitespaces)
        guard !current.split(separator: " ").contains(Substring(term)) else { return }
        searchText = current.isEmpty ? term : current + " " + term
    }

    func recordRecentSearch() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        recentSearches.removeAll { $0 == text }
        recentSearches.insert(text, at: 0)
        if recentSearches.count > 10 { recentSearches.removeLast(recentSearches.count - 10) }
        UserDefaults.standard.set(recentSearches, forKey: Keys.recentSearches)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Keys.recentSearches)
    }

    // MARK: Insights

    /// Computes stats for the current library in the background unless they're already up to date.
    func loadStatsIfNeeded() {
        guard statsVersion != libraryVersion || stats == nil else { return }
        let version = libraryVersion
        let all = tracks
        let root = libraryRoot
        statsTask?.cancel()
        statsTask = Task.detached(priority: .userInitiated) {
            let covers = CoverLookup(root: root)
            let stats = LibraryStats(tracks: all, hasCover: covers.hasCover, fileSize: { t in
                (try? FileManager.default.attributesOfItem(atPath: t.fileURL(root: root).path)[.size] as? NSNumber)?.int64Value
            })
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.libraryVersion == version else { return }
                self.stats = stats
                self.statsVersion = version
            }
        }
    }

    /// Computes listening stats for `period` in the background unless they're up to date. They're also refreshed
    /// after a few minutes, so "today" and the period's window move along while the app stays open.
    func loadListeningIfNeeded(_ period: ListeningStats.Period) {
        if let r = listeningRequest, r.period == period, r.library == libraryVersion, r.history == historyVersion,
           Date().timeIntervalSince(r.at) < 300 { return }
        guard let db = database else { return }
        let request = (period: period, library: libraryVersion, history: historyVersion, at: Date())
        listeningRequest = request
        let plays = (try? db.plays()) ?? []
        let all = tracks
        listeningTask?.cancel()
        listeningTask = Task.detached(priority: .userInitiated) {
            let stats = ListeningStats(plays: plays, tracks: all, period: period, now: request.at)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.listeningRequest?.at == request.at else { return }
                self.listening = stats
            }
        }
    }

    // MARK: Smart playlists

    func newSmartPlaylist(query: String = "") {
        smartPlaylistDraft = SmartPlaylistDraft(id: nil, name: "", query: query)
    }

    func editSmartPlaylist(_ p: SmartPlaylist) {
        smartPlaylistDraft = SmartPlaylistDraft(id: p.id, name: p.name, query: p.query)
    }

    func saveSmartPlaylist(_ draft: SmartPlaylistDraft) {
        guard let db = database else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = draft.query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let id = draft.id {
                try db.updateSmartPlaylist(id: id, name: name, query: query)
                reloadLibrary()
            } else {
                let p = try db.createSmartPlaylist(name: name, query: query)
                reloadLibrary()
                sidebar = .smartPlaylist(p.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        smartPlaylistDraft = nil
    }

    func deleteSmartPlaylist(_ id: Int64) {
        try? database?.deleteSmartPlaylist(id: id)
        if sidebar == .smartPlaylist(id) { sidebar = .songs }
        reloadLibrary()
    }

    func smartPlaylistTracks(_ p: SmartPlaylist) -> [Track] {
        index.tracks(matching: SearchQuery.parse(p.query))
    }

    func tracks(album: String, artist: String) -> [Track] {
        (try? database?.tracks(album: album, artist: artist)) ?? []
    }

    func tracks(forArtist name: String) -> [Track] {
        guard let db = database else { return [] }
        let albums = (try? db.albums(artist: name)) ?? []
        return albums.flatMap { (try? db.tracks(album: $0.album, artist: name)) ?? [] }
    }

    func coverURL(forAlbum a: AlbumSummary) -> URL {
        libraryRoot.appendingPathComponent(a.firstTrackPath).deletingLastPathComponent().appendingPathComponent("cover.jpg")
    }

    func coverURL(for track: Track) -> URL {
        track.albumDirectory(root: libraryRoot).appendingPathComponent("cover.jpg")
    }

    func removeFromLibrary(_ ids: Set<Int64>) {
        guard let db = database else { return }
        for id in ids {
            do {
                guard let t = try db.track(id: id) else { continue }
                let url = t.fileURL(root: libraryRoot)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                try db.deleteTrack(id: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        reloadLibrary()
    }

    func showInFinder(_ ts: [Track]) {
        NSWorkspace.shared.activateFileViewerSelecting(ts.map { $0.fileURL(root: libraryRoot) })
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String = "New Playlist", adding ids: [Int64] = [], rename: Bool = true) -> Playlist? {
        guard let db = database else { return nil }
        do {
            let p = try db.createPlaylist(name: name)
            if !ids.isEmpty { try db.addTracks(ids, toPlaylist: p.id) }
            reloadLibrary()
            if rename { renamingPlaylistID = p.id }
            return p
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingPlaylistID = nil
        guard !trimmed.isEmpty else { return }
        try? database?.renamePlaylist(id: id, name: trimmed)
        reloadLibrary()
    }

    func deletePlaylist(_ id: Int64) {
        try? database?.deletePlaylist(id: id)
        if sidebar == .playlist(id) { sidebar = .songs }
        reloadLibrary()
    }

    func add(_ ids: [Int64], toPlaylist id: Int64) {
        do { try database?.addTracks(ids, toPlaylist: id) } catch { errorMessage = error.localizedDescription }
        reloadLibrary()
    }

    func playlistTracks(_ id: Int64) -> [Track] { (try? database?.playlistTracks(id)) ?? [] }

    func removeFromPlaylist(_ id: Int64, positions: [Int]) {
        try? database?.removeTracks(atPositions: positions, fromPlaylist: id)
        reloadLibrary()
    }

    func movePlaylistTracks(_ id: Int64, from offsets: [Int], to offset: Int) {
        try? database?.moveTracks(inPlaylist: id, fromOffsets: offsets, toOffset: offset)
    }

    func exportPlaylist(_ playlist: Playlist) {
        export(name: playlist.name, tracks: playlistTracks(playlist.id))
    }

    func export(name: String, tracks: [Track]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder (e.g. your MP3 player) to export \"\(name)\" to"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let root = libraryRoot
        exportState = ExportState(title: name, total: tracks.count)
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.exportState?.done = done; self?.exportState?.total = total }
        }
        Task { [weak self] in
            // Only the copying runs off the main actor; state is updated here.
            let result = await Task.detached { () -> Result<URL, Error> in
                Result { try PlaylistExporter().export(name: name, tracks: tracks, libraryRoot: root, to: dest, progress: progress) }
            }.value
            switch result {
            case .success(let folder):
                self?.exportState = nil
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            case .failure(let error):
                self?.exportState?.error = error.localizedDescription
            }
        }
    }

    // MARK: Export list

    func addToExportList(_ items: [ExportItem]) {
        let new = items.filter { !exportList.contains($0) }
        guard !new.isEmpty else { return }
        exportList += new
    }

    func removeFromExportList(_ items: Set<ExportItem>) { exportList.removeAll { items.contains($0) } }

    func clearExportList() { exportList = [] }

    func isInExportList(_ item: ExportItem) -> Bool { exportList.contains(item) }

    /// The item's tracks as they are now (playlists and smart playlists can change after being added).
    func tracks(for item: ExportItem) -> [Track] {
        switch item {
        case .library: return tracks
        case .album(let album, let artist): return tracks(ofAlbumKey: SearchIndex.albumKey(album: album, artist: artist))
        case .artist(let name): return tracks(ofArtist: name)
        case .track(let id): return trackByID[id].map { [$0] } ?? []
        case .playlist(let id): return playlistTracks(id)
        case .smartPlaylist(let id): return smartPlaylists.first { $0.id == id }.map(smartPlaylistTracks) ?? []
        }
    }

    /// Every track in the export list once, in list order.
    var exportListTracks: [Track] {
        var seen = Set<Int64>()
        return exportList.flatMap(tracks(for:)).filter { seen.insert($0.id).inserted }
    }

    /// Playlists in the export list that get an .m3u file (when that option is on).
    var exportPlaylistsToWrite: [ExportPlaylist] {
        guard exportPlaylistFiles else { return [] }
        return exportList.compactMap { item in
            switch item {
            case .playlist(let id): return playlists.first { $0.id == id }.map { ExportPlaylist(name: $0.name, tracks: tracks(for: item)) }
            case .smartPlaylist(let id): return smartPlaylists.first { $0.id == id }.map { ExportPlaylist(name: $0.name, tracks: tracks(for: item)) }
            default: return nil
            }
        }.filter { !$0.tracks.isEmpty }
    }

    func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Destination"
        panel.message = "Choose where to export to (e.g. your music player or a backup drive). Files already there are kept."
        if let current = exportDestination { panel.directoryURL = current }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        if dest.standardizedFileURL.path == libraryRoot.standardizedFileURL.path {
            errorMessage = "Choose a folder other than the library itself."
            return
        }
        exportDestination = dest
    }

    func clearExportDestination() { exportDestination = nil }

    var exportDestinationAvailable: Bool {
        var isDir: ObjCBool = false
        return exportDestination.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false
    }

    /// Copies the export list into the destination using the library's own layout.
    func runExportList() {
        guard let dest = exportDestination else { chooseExportDestination(); return }
        guard exportDestinationAvailable else {
            errorMessage = "“\(dest.lastPathComponent)” isn't available. Connect the drive or choose another destination."
            return
        }
        let tracks = exportListTracks
        let playlistFiles = exportPlaylistsToWrite
        let backup = exportBackupDatabase ? database : nil
        let root = libraryRoot
        let volume = try? dest.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey])
        let ejectable = volume?.volumeIsEjectable == true || volume?.volumeIsRemovable == true || volume?.volumeIsInternal == false
        exportState = ExportState(title: dest.lastPathComponent, destination: dest, ejectableVolume: ejectable ? volume?.volume : nil)
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard self?.exportState?.summary == nil else { return }
                self?.exportState?.done = done; self?.exportState?.total = total
            }
        }
        exportTask = Task { [weak self] in
            let job = Task.detached { () -> Result<LibraryExportSummary, Error> in
                Result {
                    try LibraryExporter().export(tracks: tracks, playlists: playlistFiles, database: backup,
                                                 libraryRoot: root, to: dest, progress: progress)
                }
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            self.exportTask = nil
            self.exportRevision += 1
            guard self.exportState?.destination == dest else { return }
            switch result {
            case .success(let summary): self.exportState?.summary = summary
            case .failure(is CancellationError): self.exportState = nil
            case .failure(let error): self.exportState?.error = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        if exportTask == nil { exportState = nil }
    }

    /// Ejects the drive the last export went to, if it's removable.
    func ejectExportDestination() {
        guard let volume = exportState?.ejectableVolume else { return }
        exportState = nil
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import entry points

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio files or folders to import"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        importer.enqueue(urls)
        sidebar = .importQueue
    }

    func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLibraryRoot(url)
    }

    // MARK: Space bar

    private func installSpaceBarMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  NSApp.keyWindow?.identifier?.rawValue.contains("Settings") != true,
                  NSApp.keyWindow?.title != "Settings",
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            MainActor.assumeIsolated { self?.player.togglePlayPause() }
            return nil
        }
    }
}

/// Caches whether each album folder has a cover.jpg, so checking every track costs one stat per album.
final class CoverLookup: @unchecked Sendable {
    private let root: URL
    private var cache: [String: Bool] = [:]

    init(root: URL) { self.root = root }

    func hasCover(_ track: Track) -> Bool {
        let dir = (track.path as NSString).deletingLastPathComponent
        if let known = cache[dir] { return known }
        let found = FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).appendingPathComponent("cover.jpg").path)
        cache[dir] = found
        return found
    }
}
