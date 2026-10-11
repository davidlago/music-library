import AppKit
import Foundation
import MusicLibraryCore

/// The public library catalog: browsing its music CDs with filters, the patron's account, and the per-album
/// details (copies at each library, editions, and the MusicBrainz info looked up for each title).
@MainActor @Observable
final class LibraryCatalogStore {
    enum Keys {
        static let site = "catalogSite"
        static let homeLibrary = "catalogHomeLibrary"
        static let username = "catalogUsername"
        static let password = "catalogPassword"
        static let autoLookup = "catalogAutoLookup"
        static let query = "catalogQuery"
        static let ownership = "catalogOwnershipFilter"
        static let libraries = "catalogLibraries"
        static let librariesDate = "catalogLibrariesDate"
        static let listId = "catalogListId"
        static let downloadLibraries = "catalogDownloadLibraries"
        static let downloadDates = "catalogDownloadDates"
        static let localText = "catalogLocalQuery"
        static let localSort = "catalogLocalSort"
        static let localLibraries = "catalogLocalLibraries"
        static let liveMode = "catalogLiveMode"
    }

    static let defaultSite = "https://natick.minlib.net"

    enum OwnershipFilter: String, CaseIterable, Identifiable {
        case all, notOwned, owned
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "In Library or Not"
            case .notOwned: "Not in My Library"
            case .owned: "In My Library"
            }
        }
    }

    enum Account: Equatable {
        case signedOut
        case signingIn
        case signedIn(String)
        case failed(String)
    }

    // MARK: Settings

    var siteAddress: String {
        didSet {
            UserDefaults.standard.set(siteAddress, forKey: Keys.site)
            guard let url = siteURL, url != client.site else { return }
            client.setSite(url)
            account = .signedOut
            checkouts = []
            libraries = []
            UserDefaults.standard.removeObject(forKey: Keys.libraries)
            reset()
        }
    }

    var siteURL: URL? {
        let trimmed = siteAddress.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), url.host != nil else { return nil }
        return URL(string: "\(url.scheme ?? "https")://\(url.host!)")
    }

    /// The library this catalog site belongs to: its results say "On Shelf" when a copy is on its shelf.
    var siteLibrary: String? { siteURL.flatMap(CatalogPaths.siteLibrary) }

    /// "My library", selected by default.
    var homeLibrary: String { didSet { UserDefaults.standard.set(homeLibrary, forKey: Keys.homeLibrary) } }
    var username: String { didSet { UserDefaults.standard.set(username, forKey: Keys.username) } }
    var password: String { didSet { KeychainStore.app.set(password, for: Keys.password) } }
    /// Look up each title on MusicBrainz as results load.
    var autoLookup: Bool {
        didSet {
            UserDefaults.standard.set(autoLookup, forKey: Keys.autoLookup)
            if autoLookup { lookUp(items) }
        }
    }

    // MARK: Browsing

    var query: CatalogQuery {
        didSet {
            guard query != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(query), forKey: Keys.query)
            search()
        }
    }
    var ownershipFilter: OwnershipFilter {
        didSet {
            UserDefaults.standard.set(ownershipFilter.rawValue, forKey: Keys.ownership)
            fillIfFiltered()
        }
    }
    /// Only titles that aren't on the shelf at the site's library (the catalog can't search for that).
    var onlyUnavailable = false { didSet { fillIfFiltered() } }

    private(set) var items: [CatalogItem] = []
    private(set) var total = 0
    private(set) var loadedPages = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasSearched = false
    private(set) var libraries: [CatalogLibrary]
    @ObservationIgnored private var searchGeneration = 0

    // MARK: Account

    private(set) var account: Account = .signedOut
    private(set) var checkouts: [CatalogCheckout] = []
    private(set) var checkoutsLoading = false
    private(set) var checkoutsError: String?
    private(set) var checkoutsLoaded = false

    // MARK: List

    /// The patron's list Music Library adds titles to.
    var listId: String {
        didSet {
            guard listId != oldValue else { return }
            UserDefaults.standard.set(listId, forKey: Keys.listId)
            listEntries = []
            listLoaded = false
            if isSignedIn, !listId.isEmpty { loadList() }
        }
    }
    private(set) var userLists: [CatalogUserList] = []
    private(set) var listEntries: [CatalogListEntry] = [] { didSet { runLocalSearch() } }
    private(set) var listLoading = false
    private(set) var listLoaded = false
    private(set) var listError: String?
    /// Titles being added to or removed from the list.
    private(set) var listBusy: Set<String> = []

    // MARK: Details

    private(set) var details: [String: CatalogAlbumDetails] = [:]
    private(set) var copies: [String: [CatalogCopy]] = [:]
    /// Why copies couldn't be loaded (rate limited, offline…), by work.
    private(set) var copiesError: [String: String] = [:]
    private(set) var works: [String: CatalogWorkDetails] = [:]
    private(set) var lookingUp: String?
    private(set) var lookupRemaining = 0
    private(set) var lookupError: String?
    /// Which library albums the catalog's titles are; rebuilt with the search index.
    var ownership = CatalogOwnership.empty {
        didSet { refreshOwned() }
    }

    // MARK: Downloaded catalog

    enum LocalAvailability: String, CaseIterable, Identifiable {
        case any, available, out
        var id: String { rawValue }
    }

    struct DownloadProgress: Equatable {
        var library: String
        var page: Int
        var pages: Int?
        /// Waiting out the site's rate limit until then.
        var pausedUntil: Date?
    }

    /// Libraries whose whole CD catalog is downloaded and kept up to date.
    var downloadLibraries: [String] {
        didSet {
            guard downloadLibraries != oldValue else { return }
            UserDefaults.standard.set(downloadLibraries, forKey: Keys.downloadLibraries)
            localLibraries.removeAll { !downloadLibraries.contains($0) }
        }
    }
    /// When each library's catalog was last downloaded in full.
    var downloadDates: [String: Date] {
        didSet { UserDefaults.standard.set(downloadDates, forKey: Keys.downloadDates) }
    }
    var records: [String: CatalogRecord] = [:]
    var index = CatalogIndex.empty
    var ownedIds: Set<String> = []
    var downloadProgress: DownloadProgress?
    var downloadError: String?

    /// The search of the downloaded catalog, in the app's query language.
    var localText: String {
        didSet { UserDefaults.standard.set(localText, forKey: Keys.localText); runLocalSearch() }
    }
    var localSort: CatalogLocalSort {
        didSet { UserDefaults.standard.set(localSort.rawValue, forKey: Keys.localSort); runLocalSearch() }
    }
    /// Downloaded libraries to show (all when empty).
    var localLibraries: [String] {
        didSet { UserDefaults.standard.set(localLibraries, forKey: Keys.localLibraries); runLocalSearch() }
    }
    var localAvailability = LocalAvailability.any { didSet { runLocalSearch() } }
    var localOwnership = OwnershipFilter.all { didSet { runLocalSearch() } }
    var localOnList = false { didSet { runLocalSearch() } }
    /// Searching the library's website instead of the downloaded catalog.
    var liveMode: Bool { didSet { UserDefaults.standard.set(liveMode, forKey: Keys.liveMode) } }
    var localResult = CatalogSearchResult.empty

    @ObservationIgnored let client: LibraryCatalogClient
    @ObservationIgnored var makeEnricher: (@MainActor (LibraryCatalogClient) -> CatalogEnricher)?
    @ObservationIgnored var database: Database?
    @ObservationIgnored var lookupQueue: [CatalogItem] = []
    /// Titles of the downloaded catalog still to look up, after anything the user is looking at.
    @ObservationIgnored var downloadQueue: [CatalogItem] = []
    @ObservationIgnored var indexGeneration = 0
    @ObservationIgnored var indexRebuild: Task<Void, Never>?
    @ObservationIgnored private var lookupWorker: Task<Void, Never>?
    @ObservationIgnored private var covers = NSCache<NSString, NSImage>()
    @ObservationIgnored private var coverTasks: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var copiesFetched: [String: Date] = [:]
    @ObservationIgnored let cache = LibraryCatalogCache.shared

    init() {
        let defaults = UserDefaults.standard
        let site = defaults.string(forKey: Keys.site) ?? Self.defaultSite
        siteAddress = site
        let siteURL = URL(string: site) ?? URL(string: Self.defaultSite)!
        client = LibraryCatalogClient(site: siteURL)
        let siteLibrary = CatalogPaths.siteLibrary(siteURL) ?? ""
        homeLibrary = defaults.string(forKey: Keys.homeLibrary) ?? siteLibrary
        username = defaults.string(forKey: Keys.username) ?? ""
        listId = defaults.string(forKey: Keys.listId) ?? ""
        password = KeychainStore.app.string(for: Keys.password) ?? ""
        autoLookup = defaults.object(forKey: Keys.autoLookup) == nil ? true : defaults.bool(forKey: Keys.autoLookup)
        query = defaults.data(forKey: Keys.query).flatMap { try? JSONDecoder().decode(CatalogQuery.self, from: $0) }
            ?? CatalogQuery(libraries: siteLibrary.isEmpty ? [] : [siteLibrary])
        ownershipFilter = defaults.string(forKey: Keys.ownership).flatMap(OwnershipFilter.init) ?? .all
        libraries = defaults.data(forKey: Keys.libraries).flatMap { try? JSONDecoder().decode([CatalogLibrary].self, from: $0) } ?? []
        downloadLibraries = defaults.stringArray(forKey: Keys.downloadLibraries) ?? (siteLibrary.isEmpty ? [] : [siteLibrary])
        downloadDates = defaults.dictionary(forKey: Keys.downloadDates) as? [String: Date] ?? [:]
        localText = defaults.string(forKey: Keys.localText) ?? ""
        localSort = defaults.string(forKey: Keys.localSort).flatMap(CatalogLocalSort.init) ?? .recentlyAdded
        localLibraries = defaults.stringArray(forKey: Keys.localLibraries) ?? []
        liveMode = defaults.bool(forKey: Keys.liveMode)
        covers.countLimit = 400
    }

    func open(database: Database?) {
        cancelLookups()
        self.database = database
        details = (try? database?.catalogDetails()) ?? [:]
        records = (try? database?.catalogRecords()) ?? [:]
        rebuildIndex()
    }

    // MARK: Searching

    /// The loaded results that pass the filters the catalog can't apply itself.
    var visibleItems: [CatalogItem] {
        items.filter { item in
            if onlyUnavailable, item.availability == .here { return false }
            switch ownershipFilter {
            case .all: return true
            case .owned: return ownedAlbum(item) != nil
            case .notOwned: return ownedAlbum(item) == nil
            }
        }
    }

    var hasClientFilters: Bool { onlyUnavailable || ownershipFilter != .all }
    var hasMore: Bool { loadedPages * CatalogPage.pageSize < total }

    /// Starts browsing with the saved query, the first time the page is shown.
    func start() {
        downloadCatalogs()
        if !hasSearched, !showsDownloaded { search() }
        if libraries.isEmpty || librariesAreStale { loadLibraries() }
        if case .signedOut = account, !username.isEmpty, !password.isEmpty { signIn() }
    }

    /// Searches with the current query; `refresh` skips the cached results pages.
    func search(refresh: Bool = false) {
        if refresh {
            cache.clearPages()
            copies = [:]
        }
        reset()
        hasSearched = true
        loadNextPage()
    }

    private func reset() {
        searchGeneration += 1
        // Titles still waiting from the previous results make way for the new ones.
        lookupQueue = []
        lookupRemaining = lookingUp == nil ? 0 : 1
        items = []
        total = 0
        loadedPages = 0
        error = nil
        isLoading = false
    }

    /// The next page, or (with filters the catalog can't apply) pages until a dozen more titles show.
    func loadMore() {
        guard !isLoading, hasMore else { return }
        loadNextPage(untilVisible: visibleItems.count + (hasClientFilters ? 12 : 1), pagesLeft: hasClientFilters ? 5 : 1)
    }

    private func fillIfFiltered() {
        if hasClientFilters, hasSearched, visibleItems.count < 12 { loadMore() }
    }

    private func loadNextPage(untilVisible target: Int = 1, pagesLeft: Int = 1) {
        guard siteURL != nil else { error = "Enter the library catalog's address in Settings."; return }
        let generation = searchGeneration
        let page = loadedPages + 1
        let path = query.path(page: page)
        isLoading = true
        error = nil
        let cache = cache
        Task {
            do {
                let result: CatalogPage
                if let cached = cache.page(path, maxAge: Self.pageMaxAge) {
                    result = cached.catalogPage
                } else {
                    let html = String(decoding: try await client.get(path), as: UTF8.self)
                    result = try await Task.detached { try CatalogParser.parseResults(html, page: page) }.value
                    cache.savePage(result, path: path)
                }
                guard generation == searchGeneration else { return }
                let known = Set(items.map(\.id))
                items += result.items.filter { !known.contains($0.id) }
                total = result.total
                loadedPages = page
                isLoading = false
                if autoLookup { lookUp(result.items) }
                if visibleItems.count < target, pagesLeft > 1, hasMore {
                    loadNextPage(untilVisible: target, pagesLeft: pagesLeft - 1)
                }
            } catch {
                guard generation == searchGeneration else { return }
                isLoading = false
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Libraries

    private var librariesAreStale: Bool {
        guard let date = UserDefaults.standard.object(forKey: Keys.librariesDate) as? Date else { return true }
        return Date().timeIntervalSince(date) > 7 * 86_400
    }

    /// Every library in the network with music CDs, and how many each has.
    func loadLibraries() {
        Task {
            do {
                let html = String(decoding: try await client.get(CatalogQuery().path()), as: UTF8.self)
                guard let searchId = try CatalogParser.parseResults(html).searchId else { return }
                let found = try CatalogParser.parseLibraryFacet(try await client.get(CatalogPaths.libraryFacet(searchId: searchId)))
                guard !found.isEmpty else { return }
                libraries = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                UserDefaults.standard.set(try? JSONEncoder().encode(libraries), forKey: Keys.libraries)
                UserDefaults.standard.set(Date(), forKey: Keys.librariesDate)
            } catch {
                // The list is a convenience; the selected libraries still work without it.
            }
        }
    }

    /// The libraries to offer: the network's list, plus any selected ones it doesn't have (yet).
    var libraryChoices: [CatalogLibrary] {
        var all = libraries
        for name in Set(query.libraries + [homeLibrary]).subtracting(all.map(\.name)) where !name.isEmpty {
            all.append(CatalogLibrary(name: name))
        }
        return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func toggleLibrary(_ name: String) {
        if query.libraries.contains(name) {
            query.libraries.removeAll { $0 == name }
            if query.availableAt == name { query.availableAt = nil }
        } else {
            query.libraries.append(name)
        }
    }

    // MARK: Ownership

    func ownedAlbum(_ item: CatalogItem) -> AlbumSummary? { ownership.album(for: item, details: details[item.id]) }

    func ownedAlbum(_ checkout: CatalogCheckout) -> AlbumSummary? { ownership.album(for: checkout) }

    // MARK: Account

    var isSignedIn: Bool { if case .signedIn = account { true } else { false } }

    func signIn() {
        guard !username.isEmpty, !password.isEmpty else { account = .failed("Enter your library card number and PIN or password."); return }
        account = .signingIn
        let body = CatalogPaths.loginBody(username: username, password: password)
        Task {
            do {
                let name = try CatalogParser.parseLogin(try await client.post(CatalogPaths.login, form: body))
                account = .signedIn(name)
                refreshCheckouts()
                loadUserLists()
            } catch {
                account = .failed(error.localizedDescription)
            }
        }
    }

    func signOut() {
        account = .signedOut
        checkouts = []
        checkoutsLoaded = false
        userLists = []
        listEntries = []
        listLoaded = false
        password = ""
        Task { _ = try? await client.get(CatalogPaths.logout) }
    }

    func refreshCheckouts() {
        guard isSignedIn else { checkoutsError = CatalogError.notSignedIn.localizedDescription; return }
        checkoutsLoading = true
        checkoutsError = nil
        Task {
            do {
                checkouts = try CatalogParser.parseCheckouts(try await client.get(CatalogPaths.checkouts))
                checkoutsLoaded = true
            } catch CatalogError.notSignedIn {
                // The session expired: sign in again, which reloads the checkouts.
                checkoutsLoading = false
                if !password.isEmpty { signIn() } else { account = .signedOut }
                return
            } catch {
                checkoutsError = error.localizedDescription
            }
            checkoutsLoading = false
        }
    }

    var cdCheckouts: [CatalogCheckout] { checkouts.filter { $0.format?.localizedCaseInsensitiveContains("CD") == true && $0.format?.localizedCaseInsensitiveContains("Spoken") != true } }

    // MARK: List

    var selectedList: CatalogUserList? { userLists.first { $0.id == listId } }

    /// The list's name, even before the lists have loaded.
    var listTitle: String { selectedList?.title ?? "My List" }

    func loadUserLists() {
        guard isSignedIn else { return }
        Task {
            do {
                userLists = try CatalogParser.parseUserLists(try await client.get(CatalogPaths.userLists))
                // Keep the chosen list if it still exists; with a single list, use it.
                if !userLists.contains(where: { $0.id == listId }) { listId = userLists.count == 1 ? userLists[0].id : "" }
                if !listId.isEmpty, !listLoaded { loadList() }
            } catch {
                listError = error.localizedDescription
            }
        }
    }

    /// Every entry on the chosen list (a page at a time, as the site shows it).
    func loadList() {
        guard isSignedIn, !listId.isEmpty, !listLoading else { return }
        let id = listId
        listLoading = true
        listError = nil
        Task {
            do {
                var entries: [CatalogListEntry] = []
                var page = 1
                while page <= 25 {
                    let html = String(decoding: try await client.get(CatalogPaths.list(id, page: page)), as: UTF8.self)
                    let number = page
                    let result = try await Task.detached { try CatalogParser.parseList(html, page: number) }.value
                    let known = Set(entries.map(\.entryId))
                    let fresh = result.entries.filter { !known.contains($0.entryId) }
                    entries += fresh
                    if fresh.isEmpty || entries.count >= result.total { break }
                    page += 1
                }
                guard id == listId else { listLoading = false; return }
                listEntries = entries
                listLoaded = true
                if autoLookup { lookUp(entries.map(\.item)) }
            } catch {
                listError = error.localizedDescription
            }
            listLoading = false
        }
    }

    func listEntry(for item: CatalogItem) -> CatalogListEntry? { listEntries.first { $0.item.id == item.id } }

    func isOnList(_ item: CatalogItem) -> Bool { listEntry(for: item) != nil }

    func addToList(_ item: CatalogItem) {
        guard isSignedIn, !listId.isEmpty, !listBusy.contains(item.id) else { return }
        let id = listId
        listBusy.insert(item.id)
        listError = nil
        Task {
            do {
                _ = try CatalogParser.parseSaveToList(try await client.get(CatalogPaths.addToList(listId: id, workId: item.id)))
                // Show it right away; the reload brings its entry ID (needed to remove it).
                if !isOnList(item) { listEntries.append(CatalogListEntry(entryId: "", item: item)) }
                listLoaded = false
                loadList()
            } catch {
                listError = "Couldn't add “\(item.displayTitle)”: \(error.localizedDescription)"
            }
            listBusy.remove(item.id)
        }
    }

    func removeFromList(_ item: CatalogItem) {
        guard let entry = listEntry(for: item), !entry.entryId.isEmpty, !listBusy.contains(item.id) else { return }
        let id = listId
        listBusy.insert(item.id)
        listError = nil
        Task {
            do {
                _ = try await client.get(CatalogPaths.removeFromList(listId: id, entryId: entry.entryId))
                listEntries.removeAll { $0.entryId == entry.entryId }
                loadList()
            } catch {
                listError = "Couldn't remove “\(item.displayTitle)”: \(error.localizedDescription)"
            }
            listBusy.remove(item.id)
        }
    }

    // MARK: Album details

    /// Copies at each library, checked again after a few minutes (availability changes).
    func loadCopies(_ item: CatalogItem, force: Bool = false) async {
        if !force, copies[item.id] != nil, let at = copiesFetched[item.id], Date().timeIntervalSince(at) < Self.copiesMaxAge { return }
        do {
            copies[item.id] = try CatalogParser.parseCopies(try await client.get(CatalogPaths.copies(workId: item.id)))
            copiesFetched[item.id] = Date()
            copiesError[item.id] = nil
        } catch {
            copiesError[item.id] = error.localizedDescription
        }
    }

    /// Performers, subjects and contents from the work's page, kept on disk.
    func loadWork(_ item: CatalogItem) async {
        guard works[item.id] == nil else { return }
        if let cached = cache.work(item.id) { works[item.id] = cached; return }
        if let data = try? await client.get(item.pagePath.hasPrefix("/GroupedWork/") ? item.pagePath : CatalogPaths.work(item.id)) {
            let html = String(decoding: data, as: UTF8.self)
            if let work = try? await Task.detached(operation: { try CatalogParser.parseWork(html) }).value {
                works[item.id] = work
                cache.saveWork(work, workId: item.id)
            }
        }
    }

    static let pageMaxAge: TimeInterval = 30 * 60
    static let copiesMaxAge: TimeInterval = 10 * 60
    static let maxAge: TimeInterval = 60 * 86_400
    static let notFoundRetry: TimeInterval = 14 * 86_400

    func needsLookup(_ id: String, now: Date = Date()) -> Bool {
        guard let d = details[id] else { return true }
        return now.timeIntervalSince(d.fetchedAt) > (d.isMatched ? Self.maxAge : Self.notFoundRetry)
    }

    func isLookingUp(_ item: CatalogItem) -> Bool { lookingUp == item.id || lookupQueue.contains { $0.id == item.id } }

    var queuedLookups: Int { lookupQueue.count + downloadQueue.count }

    /// Queues titles without (fresh) details behind those already queued.
    func lookUp(_ list: [CatalogItem]) {
        enqueue(list.filter { needsLookup($0.id) }, first: false)
    }

    /// Looks a title the user opened up first, if it isn't cached (or always, with `force`).
    func ensureDetails(_ item: CatalogItem, force: Bool = false) {
        guard force || needsLookup(item.id) else { return }
        enqueue([item], first: true)
    }

    private func enqueue(_ list: [CatalogItem], first: Bool) {
        let ids = Set(list.map(\.id))
        lookupQueue.removeAll { ids.contains($0.id) }
        let fresh = list.filter { $0.id != lookingUp }
        lookupQueue = first ? fresh + lookupQueue : lookupQueue + fresh
        startLookups()
    }

    /// Starts working through the queues if they have anything and nothing is running.
    func startLookups() {
        lookupRemaining = queuedLookups + (lookingUp == nil ? 0 : 1)
        guard lookupWorker == nil, queuedLookups > 0, let makeEnricher else { return }
        lookupError = nil
        let enricher = makeEnricher(client)
        lookupWorker = Task { [weak self] in await self?.drain(enricher) }
    }

    private func drain(_ enricher: CatalogEnricher) async {
        var failures = 0
        while !Task.isCancelled, queuedLookups > 0 {
            // While the catalog is being scanned, only the user's own lookups go to the library's website.
            if lookupQueue.isEmpty, downloadProgress != nil {
                lookingUp = nil
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            let fromDownload = lookupQueue.isEmpty
            let next = fromDownload ? downloadQueue.removeFirst() : lookupQueue.removeFirst()
            // A downloaded title may have been looked up since it was queued (the user opened it).
            if fromDownload, !needsLookup(next.id) { continue }
            lookingUp = next.id
            lookupRemaining = queuedLookups + 1
            do {
                let found = try await enricher.details(for: next)
                guard !Task.isCancelled else { break }
                try? database?.saveCatalogDetails(found)
                details[next.id] = found
                failures = 0
                if records[next.id] != nil { scheduleIndexRebuild() }
            } catch CatalogError.rateLimited(let until) {
                // Not the title's fault: put it back and wait.
                if fromDownload { downloadQueue.insert(next, at: 0) } else { lookupQueue.insert(next, at: 0) }
                lookupError = CatalogError.rateLimited(until).localizedDescription
                lookingUp = nil
                try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow)))
                lookupError = nil
            } catch {
                failures += 1
                lookupError = "Couldn't look up “\(next.displayTitle)”: \(error.localizedDescription)"
                // Stop after repeated failures (offline, rate limited) rather than burning through the queue.
                if failures >= 3 { lookupQueue = []; downloadQueue = [] }
            }
        }
        lookingUp = nil
        lookupRemaining = 0
        lookupWorker = nil
    }

    func cancelLookups() {
        lookupWorker?.cancel()
        lookupWorker = nil
        lookupQueue = []
        downloadQueue = []
        lookingUp = nil
        lookupRemaining = 0
    }

    // MARK: Covers

    /// The album's cover: the Cover Art Archive's when the title was matched on MusicBrainz, otherwise the
    /// catalog's own.
    func cover(for item: CatalogItem, large: Bool = false) async -> NSImage? {
        let d = details[item.id]
        let key = "\(item.id)|\(d?.releaseId ?? d?.releaseGroupId ?? "")|\(large)"
        if let cached = covers.object(forKey: key as NSString) { return cached }
        if let running = coverTasks[key] { return await running.value }
        let client = client
        let cache = cache
        let task = Task { @MainActor () -> NSImage? in
            if let data = cache.cover(key), let image = NSImage(data: data) { return image }
            var found: Data?
            if let d, d.isMatched,
               let data = try? await CoverArtClient().fetchFront(releaseId: d.releaseId ?? "", releaseGroupId: d.releaseGroupId, size: large ? 500 : 250),
               NSImage(data: data) != nil {
                found = data
            } else {
                found = try? await client.image(CatalogPaths.cover(workId: item.id, size: large ? "large" : "medium"))
            }
            guard let found, let image = NSImage(data: found) else { return nil }
            cache.saveCover(found, key: key)
            return image
        }
        coverTasks[key] = task
        let image = await task.value
        coverTasks[key] = nil
        if let image { covers.setObject(image, forKey: key as NSString) }
        return image
    }

    func coverImage(path: String) async -> NSImage? {
        if let cached = covers.object(forKey: path as NSString) { return cached }
        if let data = cache.cover(path), let image = NSImage(data: data) {
            covers.setObject(image, forKey: path as NSString)
            return image
        }
        guard let data = try? await client.image(path), let image = NSImage(data: data) else { return nil }
        cache.saveCover(data, key: path)
        covers.setObject(image, forKey: path as NSString)
        return image
    }

    func webURL(_ path: String) -> URL? { client.url(for: path) }
}
