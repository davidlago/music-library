import AppKit
import Foundation
import MusicLibraryCore
import SwiftUI

enum SidebarItem: Hashable {
    /// The Shelf (`.all`), one medium, or To Digitize.
    case collection(CollectionScope)
    case songs, albums, artists, insights, musicDNA, concerts, importQueue, exportList, iPhone, catalog, catalogCheckouts, catalogList, cdShop
    /// Digitize Vinyl: recording a record and cutting it into tracks.
    case digitizeVinyl
    case likedSongs
    case playlist(Int64)
    case smartPlaylist(Int64)
    case cd(String)
}

/// The collection's sheets, shown by `ContentView` from anywhere (menus, the Shelf, album pages).
enum CollectionSheet: Identifiable {
    case add(medium: CollectionMedium?, prefill: CollectionPrefill?)
    /// Find by Label, opened on a label when one is given.
    case findByLabel(Sticker?)
    case addLibraryAlbums
    /// Gaps and duplicates in the label series.
    case labelCheck
    /// Link to Library Album… for the item with this id.
    case link(itemID: String)
    /// Change Cover… for the item with this id, optionally with an image dropped on its cover.
    case cover(itemID: String, request: CoverSheetRequest)
    /// Change Edition… for the item with this id: the edition picker, which replaces only its release details.
    case changeEdition(itemID: String)

    var id: String {
        switch self {
        case .add: "add"
        case .findByLabel: "find"
        case .addLibraryAlbums: "bulk"
        case .labelCheck: "labels"
        case .link(let id): "link-\(id)"
        case .cover(let id, let request): "cover-\(id)-\(request.id)"
        case .changeEdition(let id): "edition-\(id)"
        }
    }
}

struct SmartPlaylistDraft: Identifiable {
    var id: Int64?
    var name: String
    var query: String
}

/// Songs waiting for the user to confirm removing them from the library; `title` names them (an album).
struct RemovalRequest {
    var tracks: [Track]
    var title: String?
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
        static let askCDOwnership = "collectionAskOnInsert"
        static let ejectAfterCataloging = "collectionEjectAfterCataloging"
        static let recentSearches = "recentSearches"
        static let dnaDepth = "musicDNADepth"
        static let exportList = "exportList"
        static let exportDatabase = "exportBackupDatabase"
        static let exportPlaylistFiles = "exportPlaylistFiles"
        static let exportDestination = "exportDestination"
        static let showsQueue = "showsQueue"
    }

    /// System, Light or Dark. A theme chosen in an older version becomes its mode (`AppearanceMode.resolve`).
    var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppearanceMode.defaultsKey)
            applyAppearance()
        }
    }

    /// Songs until the collection is first loaded, then the Shelf when there's anything on it (unless something else
    /// was picked meanwhile).
    var sidebar: SidebarItem? = .songs {
        didSet {
            guard sidebar != oldValue else { return }
            sidebarChosen = true
            nowPlayingExpanded = false
            navigationPath = NavigationPath()
            // Picking a sidebar item leaves the search results page.
            if !searchText.isEmpty { searchText = "" }
        }
    }
    @ObservationIgnored private var sidebarChosen = false
    var nowPlayingExpanded = false
    /// The Shelf's filter, in the collection query language (`showShelf(query:)` sets it).
    var shelfQuery = ""
    /// The collection sheet showing, if any (Add to Collection…, Find by Label…, Add Library Albums…).
    var collectionSheet: CollectionSheet?
    /// The item Remove from Collection… asks about (`collectionRemovalConfirmation`).
    var pendingItemRemoval: CollectionItem?
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
    /// The collection items matching the search, trackless ones included.
    private(set) var searchItems: [CollectionItem] = []
    /// When the whole search is a label ("#12", "cd 12", "vinyl 12" or a bare number): the items with that label.
    private(set) var searchLabelHits: [CollectionItem] = []
    private(set) var recentSearches: [String]
    /// All tracks in library order.
    private(set) var tracks: [Track] = [] {
        didSet {
            var byKey: [String: [Track]] = [:]
            for t in tracks { byKey[SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist), default: []].append(t) }
            tracksByAlbumKey = byKey.mapValues { list in
                list.sorted { (($0.metadata.discNo ?? 1), ($0.trackNo ?? 0)) < (($1.metadata.discNo ?? 1), ($1.trackNo ?? 0)) }
            }
        }
    }
    /// `tracks` by album key, each album's in disc and track order (`tracks(ofAlbumKey:)`).
    private var tracksByAlbumKey: [String: [Track]] = [:]
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
    /// What AccurateRip said about tracks ripped from CDs, by track ID.
    private(set) var ripChecks: [Int64: RipCheck] = [:]
    /// Listening history per album artist (keyed by `ArtistInfoStore.key`).
    private(set) var artistPlayTotals: [String: PlayTotal] = [:]
    /// Listening history per album (keyed by `AlbumInfoStore.key`).
    private(set) var albumPlayTotals: [String: PlayTotal] = [:]
    /// When each album last got a track added (keyed by `AlbumInfoStore.key`).
    private(set) var albumAddedDates: [String: Date] = [:]
    private(set) var smartPlaylistCounts: [Int64: Int] = [:]
    var smartPlaylistDraft: SmartPlaylistDraft?
    var pendingRemoval: RemovalRequest?
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
    /// Everything you own (CDs, records, downloads), with or without tracks in the library. Rebuilt off the main
    /// thread after each library reload and each change (`saveItem`, `deleteItem`).
    private(set) var collection = MusicCollection.empty
    /// The collection, searchable in the collection query language; rebuilt with `collection`.
    private(set) var collectionIndex = CollectionIndex.empty
    /// Bumped whenever `collection` is replaced.
    private(set) var collectionVersion = 0
    /// The Collection pane of Insights.
    private(set) var collectionStats: CollectionStats?
    @ObservationIgnored private var collectionStatsRequest: (library: Int, collection: Int, history: Int)?
    @ObservationIgnored private var collectionStatsTask: Task<Void, Never>?
    @ObservationIgnored private var collectionGeneration = 0
    /// Items saved (or, as nil, deleted) since the last rebuild started, so lookups right after a change see it.
    @ObservationIgnored private var unsettledItems: [String: CollectionItem?] = [:]
    @ObservationIgnored private var appliedDefaultSidebar = false
    /// False until the open library's collection has been built once: until then `collection` is empty, so what
    /// Collection on iPhone adds isn't known (the iPhone selection isn't tidied and syncs wait).
    @ObservationIgnored private var collectionLoaded = false
    /// The album keys and artists of the collection that info was last fetched for (`syncArtistInfo`).
    @ObservationIgnored private var infoSyncedKeys: Set<String>?
    /// False while a reload rebuilds `index`, which is then of other tracks than `tracks`.
    @ObservationIgnored private var indexIsCurrent = false
    /// The songs you bought (entered when importing).
    private(set) var trackPurchases: [Int64: TrackPurchase] = [:]
    /// Bumped when an album gets a new cover, so views showing the same cover.jpg load it again.
    private(set) var coverRevision = 0
    private(set) var albums: [AlbumSummary] = []
    private(set) var artists: [ArtistSummary] = []

    /// Every artist in either collection: the digital collection's (`artists`), plus the ones you only own on CD or
    /// vinyl, their albums counted once per album and no songs. Case-insensitively by name, like artist pages.
    var allArtists: [ArtistSummary] { collection.artists(adding: artists) }
    private(set) var playlists: [Playlist] = []
    /// When each liked song was liked; the Liked Songs playlist.
    private(set) var likedDates: [Int64: Date] = [:]
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
    /// Settings ▸ Collection: ask whether an inserted CD with no item is yours, instead of adding it by default.
    var askCDOwnership: Bool { didSet { UserDefaults.standard.set(askCDOwnership, forKey: Keys.askCDOwnership) } }
    /// Settings ▸ Collection: eject a CD once Catalog Without Ripping has saved it.
    var ejectAfterCataloging: Bool { didSet { UserDefaults.standard.set(ejectAfterCataloging, forKey: Keys.ejectAfterCataloging) } }
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
    /// Apple Music previews of catalog CDs.
    @ObservationIgnored let previews = PreviewPlayer()
    @ObservationIgnored let scrobbler = Scrobbler(openURL: { NSWorkspace.shared.open($0) })
    @ObservationIgnored let artistInfo = ArtistInfoStore()
    @ObservationIgnored let albumInfo = AlbumInfoStore()
    /// The public library's catalog of music CDs.
    @ObservationIgnored let catalog = LibraryCatalogStore()
    /// Upcoming concerts near home.
    @ObservationIgnored let concerts = ConcertStore()
    /// The Radio DJ (off without a Claude API key).
    @ObservationIgnored let radioDJ = RadioDJStore()
    /// Shopping for new and used CDs.
    @ObservationIgnored let cdShop = CDShopStore()
    /// Wi-Fi sync to the iPhone app.
    @ObservationIgnored let iPhone = SyncStore()
    @ObservationIgnored private var currentPlay: (track: Track, startedAt: Date, tracker: ListenTracker)?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var importer: ImportController!
    @ObservationIgnored private(set) var cd: CDController!
    @ObservationIgnored private(set) var rips: RipChecker!
    @ObservationIgnored private(set) var vinyl: VinylController!
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
        appearance = AppearanceMode.resolve(stored: defaults.string(forKey: AppearanceMode.defaultsKey),
                                            legacyTheme: defaults.string(forKey: AppearanceMode.legacyThemeKey))
        dnaDepth = min(3, max(1, defaults.object(forKey: Keys.dnaDepth) == nil ? 2 : defaults.integer(forKey: Keys.dnaDepth)))
        exportList = defaults.data(forKey: Keys.exportList).flatMap { try? JSONDecoder().decode([ExportItem].self, from: $0) } ?? []
        exportBackupDatabase = defaults.bool(forKey: Keys.exportDatabase)
        exportPlaylistFiles = defaults.object(forKey: Keys.exportPlaylistFiles) == nil ? true : defaults.bool(forKey: Keys.exportPlaylistFiles)
        exportDestination = defaults.string(forKey: Keys.exportDestination).map { URL(fileURLWithPath: $0, isDirectory: true) }
        ejectAfterRip = defaults.object(forKey: Keys.ejectAfterRip) == nil ? true : defaults.bool(forKey: Keys.ejectAfterRip)
        // Off by default: a CD with no copy in the collection is added as a new one, a switch already on (§4.3).
        askCDOwnership = defaults.bool(forKey: Keys.askCDOwnership)
        ejectAfterCataloging = defaults.object(forKey: Keys.ejectAfterCataloging) == nil ? true
            : defaults.bool(forKey: Keys.ejectAfterCataloging)
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
            // Saved now too, so a crash keeps the queue (the position is saved on quit).
            self.savePlayerState()
        }
        player.onProgress = { [unowned self] track, position, playing in
            scrobbler.progress(track, position: position, playing: playing)
            self.advancePlay(track, position: position, playing: playing)
        }
        player.onPlaybackEnded = { [unowned self] in self.finishPlay() }
        player.onWillPlay = { [unowned self] in self.previews.stop() }
        previews.onWillPlay = { [unowned self] in if self.player.isPlaying { self.player.togglePlayPause() } }
        // Plays and likes from the iPhone are in the database now: likes, play counts and Insights follow.
        iPhone.onHistoryChanged = { [unowned self] in
            self.reloadLibrary()
            self.loadPurchases()
            self.historyVersion += 1
        }
        iPhone.context = { [unowned self] in self.syncContext }
        radioDJ.location = { [unowned self] in self.radioDJLocation }
        iPhone.startListening()
        artistInfo.onAutoSyncEnabled = { [unowned self] in self.syncArtistInfo() }
        catalog.makeEnricher = { [unowned self] client in
            CatalogEnricher(catalog: { path in try await client.get(path, priority: .background) }, musicBrainz: self.musicBrainz, info: self.artistFetcher)
        }
        cdShop.musicBrainz = musicBrainz
        importer = ImportController(model: self)
        cd = CDController(model: self)
        rips = RipChecker(model: self)
        vinyl = VinylController(model: self)
        let matcher = outputMatcher
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishPlay()
                self?.savePlayerState()
                self?.vinyl.finish()
            }
            matcher.restoreAll()
        }
        applyAppearance()
        openLibrary()
        restorePlayerState()
        // Keep a downloaded library catalog current (it's only downloaded once Library CDs has been opened).
        if !catalog.downloadDates.isEmpty { catalog.downloadCatalogs() }
        installSpaceBarMonitor()
        cd.start()
    }

    // MARK: Appearance

    /// Every window, menu and sheet follows the chosen mode; System clears the override.
    func applyAppearance() {
        switch appearance {
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .system: NSApplication.shared.appearance = nil
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
            albumInfo.onFetched = { [weak self] in self?.rebuildCollection() }
            catalog.open(database: database)
            reloadLibrary()
            vinyl?.libraryOpened()
            Task { await backfillAudioFormats() }
        } catch {
            database = nil
            errorMessage = error.localizedDescription
        }
    }

    func probeAudioFormat(_ track: Track) async -> AudioFormat? {
        guard let db = database, tools.ffprobe != nil else { return nil }
        guard let url = track.resolvedFileURL(root: libraryRoot),
              let info = try? await TagReader(tools: tools).read(url), let audio = info.audio else { return nil }
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
            if let url = track.resolvedFileURL(root: root), let info = try? await reader.read(url), let audio = info.audio {
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
        tracks = []; albums = []; artists = []; playlists = []; smartPlaylists = []; likedDates = [:]; totalTracks = 0
        playTotals = [:]; artistPlayTotals = [:]; albumPlayTotals = [:]; albumAddedDates = [:]
        index = .empty; searchResults = SearchResults(); stats = nil; statsVersion = -1
        listening = nil; listeningRequest = nil
        trackPurchases = [:]
        collection = .empty; collectionIndex = .empty; collectionStats = nil; collectionStatsRequest = nil; collectionLoaded = false
        unsettledItems = [:]; searchItems = []; searchLabelHits = []; collectionVersion += 1
        openLibrary()
    }

    func reloadLibrary() {
        guard let db = database else { return }
        do {
            let previous = tracks
            tracks = try db.fetchAllTracks()
            rekeyRetaggedAlbums(from: previous, to: tracks)
            albums = try db.albums()
            artists = try db.artists()
            playlists = try db.playlists()
            smartPlaylists = try db.smartPlaylists()
            likedDates = try db.likedTrackDates()
            ripChecks = try db.ripChecks()
            playTotals = try db.playTotals()
            totalTracks = tracks.count
            trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            recomputeGroupTotals()
            loadPurchases()
            iPhone.dropMissing()
        } catch {
            errorMessage = error.localizedDescription
        }
        rebuildIndex()
    }

    /// Rebuilds the search index, Music DNA and the collection (after linking its items to the library as it is now:
    /// `CollectionLinker`) in the background.
    private func rebuildIndex() {
        indexGeneration += 1
        let generation = indexGeneration
        indexIsCurrent = false
        let all = tracks
        let root = libraryRoot
        let smart = smartPlaylists
        let albumList = albums
        let collectionRequest = startCollectionRebuild()
        Task.detached(priority: .userInitiated) {
            let covers = CoverLookup(root: root)
            let index = SearchIndex(tracks: all, hasCover: covers.hasCover)
            let ownership = Self.catalogOwnership(albums: albumList, tracks: all)
            var built: (collection: MusicCollection, index: CollectionIndex)?
            if var request = collectionRequest {
                let read = request.read.items
                let changes = CollectionLinker.changes(items: read, tracks: all)
                if !changes.isEmpty, let linked = await MainActor.run(body: { [weak self] in
                    self?.applyLinkerChanges(changes, readAt: read)
                }) {
                    request.read = linked
                }
                built = Self.buildCollection(request.read, songs: request.songs, tracks: all, infos: request.infos, index: index)
            }
            let current = built
            // Music DNA spans both collections: CDs and records with no digital copy add their releases' people.
            let graph = CollaborationGraph(tracks: all, physical: Self.physicalSongs(built?.collection, infos: collectionRequest?.infos))
            let counts = Dictionary(uniqueKeysWithValues: smart.map { p in
                (p.id, current.map { LibrarySearch.tracks(matching: p.query, index: index, collectionIndex: $0.index, collection: $0.collection) }?.count
                    ?? index.tracks(matching: SearchQuery.parse(p.query)).count)
            })
            await MainActor.run { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                self.index = index
                self.indexIsCurrent = true
                self.collaborations = graph
                self.catalog.ownership = ownership
                self.smartPlaylistCounts = counts
                self.libraryVersion += 1
                if let current, let request = collectionRequest, request.generation == self.collectionGeneration {
                    self.infoSyncedKeys = nil
                    self.setCollection(current, settling: request.unsettled)
                } else {
                    self.runSearch()
                    self.syncArtistInfo()
                }
            }
        }
    }

    /// Library albums by title and artist, and by the MusicBrainz release group their tracks are tagged with.
    nonisolated static func catalogOwnership(albums: [AlbumSummary], tracks: [Track]) -> CatalogOwnership {
        let byKey = Dictionary(albums.map { (SearchIndex.albumKey(album: $0.album, artist: $0.artist), $0) }, uniquingKeysWith: { a, _ in a })
        var releaseGroups: [String: AlbumSummary] = [:]
        for t in tracks {
            let rg = t.metadata.extended.mbReleaseGroupId
            guard !rg.isEmpty, releaseGroups[rg] == nil,
                  let album = byKey[SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)] else { continue }
            releaseGroups[rg] = album
        }
        return CatalogOwnership(albums: albums, releaseGroups: releaseGroups)
    }

    // MARK: Player state

    /// The play queue and position at the last quit, for the library it belongs to.
    private struct SavedPlayerState: Codable {
        var libraryRoot: String
        var queue: PlayQueue.Snapshot
    }

    static var playerStateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MusicLibrary/player-state.json")
    }

    func savePlayerState() {
        let url = Self.playerStateURL
        guard let queue = player.snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(SavedPlayerState(libraryRoot: libraryRoot.path, queue: queue)).write(to: url, options: .atomic)
        } catch {
            // Not worth interrupting anything for; the queue just won't come back.
        }
    }

    /// Puts back the queue saved at the last quit, paused at the same spot in the same song.
    private func restorePlayerState() {
        guard let data = try? Data(contentsOf: Self.playerStateURL),
              let saved = try? JSONDecoder().decode(SavedPlayerState.self, from: data),
              saved.libraryRoot == libraryRoot.path else { return }
        player.restore(saved.queue) { trackByID[$0] }
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

    /// Fetches info for artists and albums that don't have it yet (when automatic downloads are on), including the
    /// collection's: artists and albums you own without songs in the library.
    func syncArtistInfo() {
        guard artistInfo.autoSync, database != nil else { return }
        artistInfo.syncMissing(artistRequests(artistNames), fetcher: artistFetcher)
        let keys = Set(albums.map(AlbumInfoStore.key))
        var itemRequests: [AlbumInfoStore.Request] = []
        var seen = keys
        for item in collection.items where item.origin == .stored && seen.insert(item.albumKey).inserted {
            itemRequests.append(albumRequest(for: item))
        }
        albumInfo.syncMissing(albums.map(albumRequest) + itemRequests, fetcher: artistFetcher)
    }

    /// The library's artists, then the collection's (trackless items included), once each.
    private var artistNames: [String] {
        var seen = Set<String>()
        return (artists.map(\.name) + collection.artists).filter { seen.insert(ArtistInfoStore.key($0)).inserted }
    }

    // MARK: Albums

    func tracks(of album: AlbumSummary) -> [Track] { tracks(ofAlbumKey: AlbumInfoStore.key(album)) }

    func tracks(ofAlbumKey key: String) -> [Track] { tracksByAlbumKey[key] ?? [] }

    /// The release and release group most of the album's tracks were matched to.
    private func albumRequest(_ album: AlbumSummary) -> AlbumInfoStore.Request {
        let ts = tracks(of: album)
        func mostCommon(_ values: [String?]) -> String? {
            let counts = values.compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        // Songs not matched on MusicBrainz go by the release of a copy you own.
        let key = AlbumInfoStore.key(album)
        let copy = collection.copies(albumKey: key).first { $0.origin == .stored && ($0.releaseID != nil || $0.releaseGroupID != nil) }
        return AlbumInfoStore.Request(key: key, title: album.album, artist: album.artist,
                                      releaseGroupId: mostCommon(ts.map { $0.metadata.extended.mbReleaseGroupId }) ?? copy?.releaseGroupID,
                                      releaseId: mostCommon(ts.map(\.metadata.mbReleaseId)) ?? copy?.releaseID)
    }

    /// The album info request for an item: its library album's, or for an item without songs, its own release.
    private func albumRequest(for item: CollectionItem) -> AlbumInfoStore.Request {
        if !collection.libraryTracks(item).isEmpty, let album = album(forKey: item.albumKey) { return albumRequest(album) }
        return AlbumInfoStore.Request(key: item.albumKey, title: item.album, artist: item.artist,
                                      releaseGroupId: item.releaseGroupID, releaseId: item.releaseID)
    }

    /// Fetches info (track list, genres, reviews) for an item being viewed, if it isn't cached (and downloads are on).
    func ensureAlbumInfo(for item: CollectionItem) {
        guard artistInfo.autoSync, !item.album.isEmpty else { return }
        albumInfo.ensure(albumRequest(for: item), fetcher: artistFetcher)
    }

    func refreshAlbumInfo(for item: CollectionItem) {
        albumInfo.refresh([albumRequest(for: item)], fetcher: artistFetcher)
    }

    /// Fetches info for an album being viewed, if it isn't cached (and downloads are on).
    func ensureAlbumInfo(_ album: AlbumSummary) {
        guard artistInfo.autoSync, !album.album.isEmpty else { return }
        albumInfo.ensure(albumRequest(album), fetcher: artistFetcher)
    }

    func refreshAlbumInfo(_ album: AlbumSummary) {
        albumInfo.refresh([albumRequest(album)], fetcher: artistFetcher)
    }

    /// Gives the album a new cover (JPEG): its `cover.jpg` and, with `embed`, the art inside its files. The CDs and
    /// records its songs came from show it too: one with a cover of its own drops it (the file is removed once saved).
    /// A copy whose music came from elsewhere keeps its own art.
    func replaceCover(of album: AlbumSummary, with jpeg: Data, embed: Bool,
                      progress: @escaping @Sendable (Int, Int) -> Void) async throws -> AlbumCoverWriter.Result {
        let writer = AlbumCoverWriter(root: libraryRoot, tools: tools)
        let albumTracks = tracks(of: album)
        defer {
            coverRevision += 1
            player.reloadCover()
            reloadLibrary()
        }
        let result = try await Task.detached(priority: .userInitiated) {
            try await writer.apply(jpeg, to: albumTracks, embed: embed, progress: progress)
        }.value
        for item in collection.copies(albumKey: AlbumInfoStore.key(album)) where item.coverFile != nil && item.isEditable {
            switch collection.digitalState(item) {
            case .digitized, .partial: changeItem(id: item.id) { $0.coverFile = nil }
            case .otherCopy, .none, .missing: break
            }
        }
        return result
    }

    func album(forKey key: String) -> AlbumSummary? {
        albums.first { AlbumInfoStore.key($0) == key }
    }

    // MARK: Collection

    /// The item with this id, including one saved or removed a moment ago (before `collection` is rebuilt).
    func item(id: String) -> CollectionItem? {
        if let recent = unsettledItems[id] { return recent }
        return collection.item(id: id)
    }

    /// The number to suggest for the next label in a series, past every saved item (including ones saved a moment
    /// ago) and `pending` ones not saved yet.
    func nextNumber(in series: StickerSeries, pending: [Int] = []) -> Int {
        let recent = unsettledItems.values.compactMap { $0?.sticker?.series == series ? $0?.stickerNumber : nil }
        return collection.nextNumber(in: series, pending: pending + recent)
    }

    /// Another item with this label (not the one with id `excluding`), if any: saving it twice is refused (D7).
    func itemLabeled(_ sticker: Sticker, excluding id: String?) -> CollectionItem? {
        if let recent = unsettledItems.values.lazy.compactMap({ $0 }).first(where: { $0.sticker == sticker && $0.id != id }) {
            return recent
        }
        return collection.items(at: sticker).first { $0.id != id && unsettledItems[$0.id] == nil }
    }

    /// Saves an item (new or changed). Pass a copy of what `item(id:)` returns just now, changed only where the user
    /// changed it: every field is written as given. With `cover` (JPEG), the item gets a new cover of its own; the
    /// file it had is removed once the row is saved. Returns the item as saved, or nil (with the error shown).
    @discardableResult
    func saveItem(_ item: CollectionItem, cover jpeg: Data? = nil) -> CollectionItem? {
        guard let db = database else { return nil }
        var item = item
        let previousCover = self.item(id: item.id)?.coverFile
        var newCover: String?
        if let jpeg {
            do {
                newCover = try CollectionCovers.write(jpeg, itemID: item.id, root: libraryRoot)
                item.coverFile = newCover
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
        let now = Date()
        do {
            try db.saveCollectionItem(item, at: now)
        } catch {
            if let newCover { removeCoverFile(newCover) }
            errorMessage = error.localizedDescription
            return nil
        }
        if let previousCover, previousCover != item.coverFile { removeCoverFile(previousCover) }
        item.updatedAt = now
        unsettledItems[item.id] = item
        rebuildCollection()
        return item
    }

    /// Saves several items at once (Add Library Albums…), in one transaction: all or none.
    @discardableResult
    func saveItems(_ items: [CollectionItem]) -> Bool {
        guard let db = database, !items.isEmpty else { return false }
        let now = Date()
        do {
            try db.saveCollectionItems(items, at: now)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        for var item in items {
            item.updatedAt = now
            unsettledItems[item.id] = item
        }
        rebuildCollection()
        return true
    }

    /// Removes an item from the collection (the user asked to), with its own cover file. Its album's songs stay.
    func deleteItem(id: String) {
        guard let db = database else { return }
        let cover = item(id: id)?.coverFile
        do {
            try db.deleteCollectionItem(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if let cover { removeCoverFile(cover) }
        unsettledItems[id] = .some(nil)
        rebuildCollection()
    }

    /// An item's own cover file, else its linked album's cover.jpg (when that album has songs).
    func coverURL(for item: CollectionItem) -> URL? {
        if let file = item.coverFile, let url = CollectionCovers.url(file, root: libraryRoot),
           FileManager.default.fileExists(atPath: url.path) { return url }
        var linked = item
        linked.coverFile = nil
        return collection.coverPath(linked).flatMap { LibraryPath.resolve($0, in: libraryRoot) }
    }

    /// How a library album's cover shows the copies you own.
    func copyMark(for album: AlbumSummary) -> CopyMark { collection.mark(albumKey: AlbumInfoStore.key(album)) }

    /// Opens an item's page on top of whatever is showing.
    func showItem(id: String) {
        nowPlayingExpanded = false
        navigationPath.append(CollectionItemRoute(id: id))
    }

    /// Opens the Shelf (or one of its scopes) filtered by `query`, in the collection query language.
    func showShelf(query: String = "", scope: CollectionScope = .all) {
        var scope = scope
        // Downloads aren't on the Shelf: a filter that finds only downloads (an Insights row, say) opens Downloads.
        if scope == .all, !query.isEmpty {
            let found = collectionIndex.search(query)
            if !found.isEmpty, !found.contains(where: { $0.medium.isPhysical }) { scope = .downloads }
        }
        nowPlayingExpanded = false
        if !searchText.isEmpty { searchText = "" }
        if sidebar != .collection(scope) { sidebar = .collection(scope) }
        navigationPath = NavigationPath()
        shelfQuery = query
    }

    /// Add to Collection… (⇧⌘N), optionally for a medium and prefilled (e.g. from a catalog or shop listing).
    func addToCollection(medium: CollectionMedium? = nil, prefill: CollectionPrefill? = nil) {
        presentCollectionSheet(.add(medium: medium, prefill: prefill))
    }

    /// Find by Label (⌘L), optionally opened on a label.
    func findByLabel(_ sticker: Sticker? = nil) { presentCollectionSheet(.findByLabel(sticker)) }

    /// Add Library Albums…
    func addLibraryAlbums() { presentCollectionSheet(.addLibraryAlbums) }

    /// A sheet is showing in a window (a collection sheet, the smart playlist editor, an export, or a page's own
    /// sheet): the collection's menu commands do nothing then, rather than replace it and lose what's entered.
    var isShowingSheet: Bool {
        collectionSheet != nil || smartPlaylistDraft != nil || exportState != nil
            || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func presentCollectionSheet(_ sheet: CollectionSheet) {
        guard !isShowingSheet else { return }
        collectionSheet = sheet
    }

    /// Changes one stored item as it is saved now (not as some view last saw it), so only what `change` sets is
    /// written. Nothing happens for an item that's gone, read-only, or unchanged. Returns the item as saved.
    @discardableResult
    func changeItem(id: String, cover jpeg: Data? = nil, _ change: (inout CollectionItem) -> Void) -> CollectionItem? {
        guard let current = item(id: id), current.isEditable else { return nil }
        var item = current
        change(&item)
        guard item != current || jpeg != nil else { return current }
        return saveItem(item, cover: jpeg)
    }

    /// Asks before removing an item (`collectionRemovalConfirmation`).
    func confirmItemRemoval(_ item: CollectionItem) {
        guard item.isEditable else { return }
        pendingItemRemoval = item
    }

    /// The library album an item's digital copy is, when its album key has songs.
    func linkedAlbum(for item: CollectionItem) -> AlbumSummary? {
        collection.libraryTracks(item).isEmpty ? nil : album(forKey: item.albumKey)
    }

    /// Plays an item's songs in album order (or shuffled).
    func play(item: CollectionItem, shuffled: Bool = false) {
        let songs = collection.libraryTracks(item)
        guard !songs.isEmpty else { return }
        player.play(queue: shuffled ? songs.shuffled() : songs, startAt: 0, source: item.album)
    }

    /// The disc in a drive that is this CD (by release, barcode or album key), if any.
    func discInDrive(for item: CollectionItem) -> CDDisc? {
        guard item.medium == .cd else { return nil }
        return cd.discs.first { disc in
            guard let release = disc.release else { return false }
            if let id = item.releaseID { return release.id == id }
            if let code = item.barcode, !release.barcode.isEmpty {
                return release.barcode.filter(\.isNumber).drop { $0 == "0" } == code.drop { $0 == "0" }
            }
            return disc.albumKey == item.albumKey
        }
    }

    /// The album key an item can be unlinked to: its own title and artist's, unless songs are under that key too
    /// (then it can only be linked to another album).
    func unlinkedKey(for item: CollectionItem) -> String? {
        let own = SearchIndex.albumKey(album: item.album, artist: item.artist)
        return tracks(ofAlbumKey: own).isEmpty ? own : nil
    }

    /// Whether Unlink can do anything: the item is linked, and its link can be dropped (see `unlink`).
    func canUnlink(_ item: CollectionItem) -> Bool {
        guard item.isEditable else { return false }
        if collection.libraryTracks(item).isEmpty { return item.digitalSource != nil }
        return unlinkedKey(for: item) != nil
    }

    /// Unlinks an item from its digital copy. A copy that left the library just stops being linked (a rip under the
    /// same key links it again); one whose songs are there moves to its own title and artist's key, since songs under
    /// its key are always its digital copy. The item's other details stay.
    func unlink(itemID: String) {
        guard let item = item(id: itemID), canUnlink(item) else { return }
        let key = collection.libraryTracks(item).isEmpty ? item.albumKey : unlinkedKey(for: item)
        guard let key else { return }
        changeItem(id: itemID) {
            $0.albumKey = key
            $0.digitalSource = nil
        }
    }

    /// Opens an artist's page, also for an artist you only have items by.
    func showArtist(named name: String) {
        nowPlayingExpanded = false
        if let artist = artistSummary(named: name) {
            navigationPath.append(artist)
        } else {
            navigationPath.append(ArtistRoute(name: name))
        }
    }

    /// Adds a copy of a library album you own (linked to it) with the next label in its series. Returns it as saved.
    @discardableResult
    func addCopy(of album: AlbumSummary, medium: CollectionMedium) -> CollectionItem? {
        let number = medium.series.map { nextNumber(in: $0) }
        let item = CollectionDraft.item(album: album, tracks: tracks(of: album), medium: medium, sticker: number)
        return saveItem(item)
    }

    /// The item the Import page's files are the digital copy of, preset by Import a Transfer… on an item's page.
    var importLinkItemID: String?

    /// Import Files… / Import a Transfer… for an item: chooses the files, with the item preset as what they're the
    /// digital copy of.
    func importFiles(for item: CollectionItem) {
        importLinkItemID = item.id
        // The queue takes it when the files are added; choosing none leaves nothing preset.
        defer { importLinkItemID = nil }
        chooseFilesToImport()
    }

    /// Moves the items of an album whose album or album artist tags changed to its new key.
    func rekeyCollection(from oldKey: String, to newKey: String) {
        guard let db = database, oldKey != newKey else { return }
        do {
            try db.rekeyCollection(from: oldKey, to: newKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Items follow their album when its album or album artist tags change, whatever changed them (the Mac app has
    /// no tag editor of its own: tags change by re-importing, rematching or outside the app, and show up here). When
    /// none of an old key's songs is left under it, its items move to the key most of its retagged songs went to
    /// (an album split in two, by disc say, follows its bigger part and reads partly digitized there, rather than
    /// missing). An old key that still has songs keeps its items. Called with the songs before and after a reload,
    /// before the collection is read.
    private func rekeyRetaggedAlbums(from old: [Track], to new: [Track]) {
        guard database != nil, !old.isEmpty, !new.isEmpty else { return }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let retagged = new.filter { t in
            before[t.id].map { $0.album != t.album || $0.effectiveAlbumArtist != t.effectiveAlbumArtist } ?? false
        }
        guard !retagged.isEmpty else { return }
        func key(_ t: Track) -> String { SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist) }
        let live = Set(new.map(key))
        var moves: [String: [String: Int]] = [:]
        for t in retagged {
            guard let was = before[t.id] else { continue }
            let oldKey = key(was)
            // The old key still has songs (some weren't retagged, or others joined it): its items stay.
            guard !live.contains(oldKey) else { continue }
            moves[oldKey, default: [:]][key(t), default: 0] += 1
        }
        for (oldKey, targets) in moves.sorted(by: { $0.key < $1.key }) {
            let target = targets.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            if let target { rekeyCollection(from: oldKey, to: target) }
        }
    }

    /// What a collection rebuild works from, read on the main actor.
    private struct CollectionRequest: Sendable {
        var read: CollectionRead
        var songs: [Int64: TrackPurchase]
        var infos: [String: AlbumInfo]
        var generation: Int
        /// The changes made before the read, which the rebuilt collection includes.
        var unsettled: [String: CollectionItem?]
    }

    /// Reads the items for a rebuild. Nil when they can't be read: the collection shown stays as it is.
    private func startCollectionRebuild() -> CollectionRequest? {
        guard let db = database, let read = try? db.collectionItems() else { return nil }
        collectionGeneration += 1
        return CollectionRequest(read: read, songs: trackPurchases, infos: albumInfo.infos, generation: collectionGeneration,
                                 unsettled: unsettledItems)
    }

    /// Rebuilds `collection` and its index in the background after a change to the items.
    private func rebuildCollection() {
        guard let request = startCollectionRebuild() else { return }
        let all = tracks
        // The library's index is reused only when it's of these tracks (not while a reload is rebuilding it).
        let index = indexIsCurrent ? self.index : nil
        Task.detached(priority: .userInitiated) {
            let built = Self.buildCollection(request.read, songs: request.songs, tracks: all, infos: request.infos, index: index)
            let graph = CollaborationGraph(tracks: all, physical: Self.physicalSongs(built.collection, infos: request.infos))
            await MainActor.run { [weak self] in
                guard let self, request.generation == self.collectionGeneration else { return }
                self.collaborations = graph
                self.setCollection(built, settling: request.unsettled)
            }
        }
    }

    nonisolated private static func physicalSongs(_ collection: MusicCollection?, infos: [String: AlbumInfo]?)
        -> [CollaborationGraph.PhysicalSong] {
        guard let collection else { return [] }
        return CollaborationGraph.physicalSongs(collection: collection, albumInfos: infos ?? [:])
    }

    nonisolated private static func buildCollection(_ read: CollectionRead, songs: [Int64: TrackPurchase], tracks: [Track],
                                                    infos: [String: AlbumInfo], index: SearchIndex?)
        -> (collection: MusicCollection, index: CollectionIndex) {
        let collection = MusicCollection(items: read.items, songPurchases: songs, tracks: tracks, unreadable: read.unreadable)
        return (collection, CollectionIndex(collection: collection, tracks: tracks, albumInfos: infos, index: index))
    }

    private func setCollection(_ built: (collection: MusicCollection, index: CollectionIndex), settling unsettled: [String: CollectionItem?]) {
        collection = built.collection
        collectionIndex = built.index
        collectionVersion += 1
        for (id, change) in unsettled where unsettledItems[id] == change { unsettledItems.removeValue(forKey: id) }
        catalog.collection = collection
        refreshCollectionPlaylistCounts()
        // The app opens on the Shelf once there's anything on it (D19; downloads aren't on the Shelf), unless
        // something else was picked already (a page opened or a search typed while it loaded counts too).
        if !appliedDefaultSidebar {
            appliedDefaultSidebar = true
            if !sidebarChosen, searchText.isEmpty, navigationPath.isEmpty, collection.count(.all) > 0 { sidebar = .collection(.all) }
        }
        if !collectionLoaded {
            collectionLoaded = true
            // Skipped while the collection was empty, since what Collection on iPhone adds wasn't known.
            iPhone.dropMissing()
        }
        // A disc looked up while the collection was loading (or changing) is matched to its items again.
        cd?.collectionChanged()
        runSearch()
        // Info is fetched after a reload, and after an edit only for albums or artists new to the collection.
        let infoKeys = Set(collection.items.filter { $0.origin == .stored }.map(\.albumKey) + collection.artists.map { "artist:" + ArtistInfoStore.key($0) })
        if infoSyncedKeys.map({ !infoKeys.isSubset(of: $0) }) ?? true {
            infoSyncedKeys = infoKeys
            syncArtistInfo()
        }
    }

    /// Persists what the linker found after a reload, keeping only what's still right for the items as they are now
    /// (one may have been edited since they were read): nothing for an item whose album key changed meanwhile, and
    /// fields only filled while still blank. Returns the items as saved.
    private func applyLinkerChanges(_ changes: [CollectionLinker.Change], readAt old: [CollectionItem]) -> CollectionRead? {
        guard let db = database, let fresh = try? db.collectionItems() else { return nil }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(fresh.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kept: [CollectionLinker.Change] = []
        for change in changes {
            guard let was = before[change.id], let item = now[change.id], item.albumKey == was.albumKey else { continue }
            var c = CollectionLinker.Change(id: change.id, albumKey: change.albumKey)
            if item.releaseID == nil { c.releaseID = change.releaseID }
            if item.releaseGroupID == nil { c.releaseGroupID = change.releaseGroupID }
            if item.year == nil { c.year = change.year }
            if item.digitalSource == nil { c.digitalSource = change.digitalSource }
            if c != CollectionLinker.Change(id: change.id) { kept.append(c) }
        }
        guard !kept.isEmpty else { return fresh }
        do {
            try db.applyCollectionChanges(kept)
            return try db.collectionItems()
        } catch {
            errorMessage = error.localizedDescription
            return fresh
        }
    }

    /// Smart playlists with collection filters change with the collection.
    private func refreshCollectionPlaylistCounts() {
        for p in smartPlaylists where CollectionSearchQuery.parse(p.query, shorthand: false).hasCollectionFilters {
            smartPlaylistCounts[p.id] = smartPlaylistTracks(p).count
        }
    }

    private func removeCoverFile(_ file: String) {
        guard let url = CollectionCovers.url(file, root: libraryRoot) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Computes the Collection pane's stats in the background unless the library, collection and history are unchanged.
    func loadCollectionStatsIfNeeded() {
        let request = (library: libraryVersion, collection: collectionVersion, history: historyVersion)
        if let r = collectionStatsRequest, r == request, collectionStats != nil { return }
        collectionStatsRequest = request
        let current = collection, all = tracks, totals = playTotals, infos = albumInfo.infos
        collectionStatsTask?.cancel()
        collectionStatsTask = Task.detached(priority: .userInitiated) {
            let stats = CollectionStats(collection: current, tracks: all, playTotals: totals, albumInfos: infos)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let r = self.collectionStatsRequest, r == request else { return }
                self.collectionStats = stats
            }
        }
    }

    // MARK: Song purchases

    /// Records what you paid for a song (with nil, forgets it).
    func setTrackPurchase(_ purchase: TrackPurchase?, for trackID: Int64) {
        guard let db = database, trackPurchases[trackID] != purchase else { return }
        do {
            try db.saveTrackPurchase(trackID: trackID, purchase)
            trackPurchases[trackID] = purchase
            rebuildCollection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPurchases() {
        trackPurchases = (try? database?.trackPurchases()) ?? trackPurchases
    }

    /// The artist by this name in either collection (`allArtists`), for links to their page.
    func artistSummary(named name: String) -> ArtistSummary? {
        let key = ArtistInfoStore.key(name)
        return artists.first { ArtistInfoStore.key($0.name) == key } ?? allArtists.first { ArtistInfoStore.key($0.name) == key }
    }

    /// The library's and the collection's artists to look for on the Concerts page, with their MusicBrainz IDs where
    /// known.
    func concertArtists() -> [ConcertArtist] {
        artistNames.map { ConcertArtist(name: $0, mbid: artistInfo.info(for: $0)?.mbid) }
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

    /// Searches the library and the collection together (`LibrarySearch`).
    private func runSearch() {
        guard isSearching else {
            searchResults = SearchResults(); searchItems = []; searchLabelHits = []
            return
        }
        let results = LibrarySearch.run(searchText, index: index, collectionIndex: collectionIndex, collection: collection,
                                        autocorrect: searchAutocorrect)
        searchResults = results.library
        searchItems = results.items
        searchLabelHits = results.labelHits
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The library's completions, then the collection keys' (`own:`, `ripped:`, `sticker:`…).
    var searchCompletions: [SearchCompletion] {
        let library = index.completions(for: searchText)
        let labels = Set(library.map(\.label))
        return library + collectionIndex.completions(for: searchText).filter { !labels.contains($0.label) }
    }

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
                t.resolvedFileURL(root: root).flatMap(LibraryExporter.size(of:))
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

    /// Without collection keys, exactly what the library's index matches (as saved playlists always did).
    func smartPlaylistTracks(_ p: SmartPlaylist) -> [Track] {
        LibrarySearch.tracks(matching: p.query, index: index, collectionIndex: collectionIndex, collection: collection)
    }

    func tracks(album: String, artist: String) -> [Track] {
        (try? database?.tracks(album: album, artist: artist)) ?? []
    }

    func tracks(forArtist name: String) -> [Track] {
        guard let db = database else { return [] }
        let albums = (try? db.albums(artist: name)) ?? []
        return albums.flatMap { (try? db.tracks(album: $0.album, artist: name)) ?? [] }
    }

    func coverURL(forAlbum a: AlbumSummary) -> URL? {
        LibraryPath.coverURL(forTrackAt: a.firstTrackPath, root: libraryRoot)
    }

    func coverURL(for track: Track) -> URL? {
        track.coverURL(root: libraryRoot)
    }

    /// Asks (in `ContentView`) before removing `tracks` from the library; `title` names them, e.g. an album.
    func confirmRemoval(_ tracks: [Track], title: String? = nil) {
        guard !tracks.isEmpty else { return }
        pendingRemoval = RemovalRequest(tracks: tracks, title: title)
    }

    /// The items whose album would have no songs left without these: removing them keeps the items, each with its
    /// album's cover and marked not ripped (D12).
    func copiesLosingMusic(_ ids: Set<Int64>) -> [CollectionItem] {
        var keys = Set<String>()
        for id in ids { if let t = trackByID[id] { keys.insert(SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist)) } }
        return keys.sorted().flatMap { key in
            collection.copies(albumKey: key).filter { item in
                item.isEditable && collection.libraryTracks(item).allSatisfy { ids.contains($0.id) }
            }
        }
    }

    /// Moves the songs' files to the Trash (with album and artist folders left empty but for a cover) and removes
    /// them from the library, their playlists, likes and listening history, and the play queue. Items whose album
    /// leaves the library stay in the collection: first each one without a cover of its own takes a copy of the
    /// album's cover.jpg (which goes to the Trash with the folder), then once the songs are gone it's marked not
    /// ripped (its digital source cleared).
    func removeFromLibrary(_ ids: Set<Int64>) {
        guard let db = database else { return }
        let losing = copiesLosingMusic(ids)
        var adopted: [String: String] = [:]
        for item in losing where item.coverFile == nil {
            guard let url = coverURL(for: item), FileManager.default.fileExists(atPath: url.path),
                  let file = try? CollectionCovers.adopt(albumCover: url, itemID: item.id, root: libraryRoot) else { continue }
            adopted[item.id] = file
        }
        var removed: Set<Int64> = [], trashed: [URL] = []
        for id in ids {
            do {
                guard let t = try db.track(id: id) else { continue }
                // A path leading outside the library isn't a library file: only the entry is removed.
                if let url = t.resolvedFileURL(root: libraryRoot), FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    trashed.append(url)
                }
                try db.deleteTrack(id: id)
                removed.insert(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        for folder in LibraryPath.emptiedFolders(after: trashed, root: libraryRoot) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        player.removeTracks(removed)
        updateCopies(losing, adopted: adopted, removed: removed)
        reloadLibrary()
    }

    /// After removing songs: the items keep the covers they adopted, and those whose album has no songs left now are
    /// marked not ripped. Nothing else about them changes.
    private func updateCopies(_ losing: [CollectionItem], adopted: [String: String], removed: Set<Int64>) {
        guard let db = database, !losing.isEmpty else { return }
        // As saved: only the cover and the source change.
        let saved = Dictionary(((try? db.collectionItems().items) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: [CollectionItem] = []
        for old in losing {
            guard let current = saved[old.id], current.isEditable else { continue }
            var item = current
            if let file = adopted[item.id], item.coverFile == nil { item.coverFile = file }
            if collection.libraryTracks(old).allSatisfy({ removed.contains($0.id) }) { item.digitalSource = nil }
            if item != current { changed.append(item) }
        }
        let used = Set(changed.compactMap(\.coverFile))
        defer { for file in adopted.values where !used.contains(file) { removeCoverFile(file) } }
        guard !changed.isEmpty else { return }
        do {
            try db.saveCollectionItems(changed)
            for item in changed { unsettledItems[item.id] = item }
        } catch {
            for item in changed { if let file = adopted[item.id] { removeCoverFile(file) } }
            errorMessage = error.localizedDescription
        }
    }

    func showInFinder(_ ts: [Track]) {
        NSWorkspace.shared.activateFileViewerSelecting(ts.compactMap { $0.resolvedFileURL(root: libraryRoot) })
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

    // MARK: Liked songs

    static let likedSongsName = "Liked Songs"

    func isLiked(_ track: Track) -> Bool { likedDates[track.id] != nil }

    /// Liked songs, most recently liked first.
    var likedTracks: [Track] {
        likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { trackByID[$0.key] }
    }

    func setLiked(_ tracks: [Track], _ liked: Bool) {
        guard let db = database, !tracks.isEmpty else { return }
        let ids = tracks.map(\.id)
        let now = Date()
        do {
            try db.setLiked(ids, liked, at: now)
            for id in ids {
                if liked { if likedDates[id] == nil { likedDates[id] = now } } else { likedDates[id] = nil }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleLike(_ track: Track) { setLiked([track], !isLiked(track)) }

    func saveRipChecks(_ checks: [RipCheck]) {
        guard let db = database, !checks.isEmpty else { return }
        do {
            try db.saveRipChecks(checks)
            for c in checks { ripChecks[c.trackId] = c }
        } catch {
            errorMessage = error.localizedDescription
        }
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
        case .likedSongs: return likedTracks
        case .smartPlaylist(let id): return smartPlaylists.first { $0.id == id }.map(smartPlaylistTracks) ?? []
        }
    }

    /// Every track the iPhone selection puts on the phone, once, in list order.
    /// The songs the iPhone list puts on a phone, with what its Collection on iPhone adds; with nil, on any paired
    /// phone (the list is shared, each phone has its own scope).
    func iPhoneTracks(for phone: SyncStore.PairedPhone? = nil) -> [Track] {
        iPhone.selection.resolve(tracks(for:), implicit: iPhone.implicit(for: phone, collection: collection))
    }

    func syncIPhone(_ phone: SyncStore.PairedPhone) { iPhone.sync(phone) }

    /// What a sync with the iPhone needs: the library, and the Last.fm account, concert settings and Radio DJ to hand
    /// over.
    private var syncContext: SyncContext? {
        guard let database else { return nil }
        var lastFM: SyncLastFM?
        if case .connected = scrobbler.status, let session = scrobbler.session {
            lastFM = SyncLastFM(apiKey: scrobbler.apiKey, sharedSecret: scrobbler.sharedSecret, sessionKey: session.key, username: session.username)
        }
        var concertSettings: SyncConcertSettings?
        if concerts.isConfigured, let home = concerts.home {
            concertSettings = SyncConcertSettings(home: home, radius: concerts.radius, unit: concerts.unit,
                                                  ticketmasterKey: concerts.ticketmasterKey, jambaseKey: concerts.jambaseKey)
        }
        return SyncContext(libraryRoot: libraryRoot, database: database, lastFM: lastFM, concerts: concertSettings,
                           radioDJ: radioDJ.syncSettings,
                           library: tracks, tracks: { [unowned self] in self.tracks(for: $0) }, collection: collection,
                           collectionReady: collectionLoaded)
    }

    /// The collection's own covers (`Music/Collection Covers`), which go with a database backup.
    func collectionCoverPaths() -> [String] { (try? database?.collectionCoverPaths()) ?? [] }

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
            case .likedSongs: return ExportPlaylist(name: Self.likedSongsName, tracks: tracks(for: item))
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
            errorMessage = "Choose a folder other than the library folder itself."
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
            MainActor.assumeIsolated {
                guard let self else { return }
                // A vinyl recording on its page, a catalog preview while one is loaded, else the library's player.
                if self.sidebar == .digitizeVinyl, self.vinyl.recording != nil, !self.vinyl.isBusy, !self.isSearching {
                    self.vinyl.togglePreview()
                } else if self.previews.current != nil { self.previews.togglePlayPause() } else { self.player.togglePlayPause() }
            }
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
