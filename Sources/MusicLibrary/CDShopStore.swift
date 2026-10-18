import Foundation
import MusicLibraryCore

/// Shop for CDs: find the exact CD on MusicBrainz, then gather copies for sale from marketplaces that ship to
/// the US (`CDShop.searched`), plus links to search a few more. Nothing is signed in to. Results are kept in
/// memory for half an hour per CD; exchange rates (to compare prices in other currencies) once a day.
@MainActor @Observable
final class CDShopStore {
    enum SearchState: Equatable {
        case idle
        case searching
        case done
        case failed(String)
    }

    enum ShopState: Equatable {
        case waiting
        case loading
        case done(Int)
        case failed(String)
        /// MusicBrainz doesn't link the CD to this store.
        case notLinked
    }

    enum ConditionFilter: String, CaseIterable, Identifiable {
        case any = "Any Condition", new = "New", used = "Used"
        var id: String { rawValue }
    }

    var query = CDSearchQuery()
    private(set) var searchState: SearchState = .idle
    private(set) var albums: [CDAlbum] = []
    var expandedAlbum: String?
    /// For a search by artist alone: the artists it matched, and the one whose albums are listed.
    private(set) var artists: [CDArtist] = []
    private(set) var artist: CDArtist?
    /// Albums whose CD editions are being looked up.
    private(set) var loadingEditions: Set<String> = []
    private(set) var editionErrors: [String: String] = [:]

    private(set) var target: CDShoppingTarget?
    private(set) var isResolving = false
    private(set) var resolveError: String?
    private(set) var shopStates: [CDShop: ShopState] = [:]
    private(set) var offers: [CDOffer] = []
    private(set) var discogsStats: DiscogsMarketStats?
    private(set) var rates = ExchangeRates()

    var condition: ConditionFilter = .any
    var hiddenShops: Set<CDShop> = []
    var showsPossible = true

    @ObservationIgnored var musicBrainz: MusicBrainzClient?
    @ObservationIgnored private let loader = CDShopPageLoader()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var shopTask: Task<Void, Never>?
    @ObservationIgnored private var cache: [CDShoppingTarget: (offers: [CDOffer], states: [CDShop: ShopState], stats: DiscogsMarketStats?, at: Date)] = [:]
    @ObservationIgnored private var raw: [CDOffer] = []
    /// The shopping run whose results are shown; an older one still loading drops its pages.
    @ObservationIgnored private var runID = UUID()

    static let cacheAge: TimeInterval = 30 * 60
    private static let ratesKey = "cdShopExchangeRates"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.ratesKey),
           let saved = try? JSONDecoder().decode(ExchangeRates.self, from: data) {
            rates = saved
        }
    }

    // MARK: Finding the CD

    func search() {
        guard !query.isEmpty, let musicBrainz else { return }
        let q = query
        searchTask?.cancel()
        searchState = .searching
        artists = []
        artist = nil
        editionErrors = [:]
        searchTask = Task {
            do {
                if q.album.trimmingCharacters(in: .whitespaces).isEmpty, q.code.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Artist alone: list their albums to pick from.
                    let found = try await musicBrainz.searchArtists(q.artist)
                    guard !Task.isCancelled else { return }
                    let best = found.first?.score ?? 0
                    artists = found.filter { $0.score >= best - 35 }.prefix(6).map { $0 }
                    if let first = artists.first {
                        try await loadAlbums(of: first)
                    } else {
                        albums = []
                    }
                } else {
                    let editions = try await musicBrainz.searchCDEditions(q)
                    guard !Task.isCancelled else { return }
                    albums = CDEditionParser.albums(editions)
                    expandedAlbum = albums.count == 1 ? albums.first?.id : nil
                }
                searchState = .done
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    /// Lists another of the artists the search matched.
    func choose(artist: CDArtist) {
        guard artist != self.artist, let musicBrainz else { return }
        searchTask?.cancel()
        searchState = .searching
        searchTask = Task {
            do {
                try await loadAlbums(of: artist)
                searchState = .done
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
        _ = musicBrainz
    }

    private func loadAlbums(of artist: CDArtist) async throws {
        guard let musicBrainz else { return }
        self.artist = artist
        albums = []
        expandedAlbum = nil
        let found = try await musicBrainz.cdAlbums(artist: artist)
        guard !Task.isCancelled, self.artist == artist else { return }
        albums = found
    }

    /// Opens or closes an album, looking up its CD editions the first time.
    func toggle(_ album: CDAlbum) {
        if expandedAlbum == album.id { expandedAlbum = nil; return }
        expandedAlbum = album.id
        guard !album.editionsLoaded, !loadingEditions.contains(album.id), let id = album.releaseGroupId, let musicBrainz else { return }
        loadingEditions.insert(album.id)
        editionErrors[album.id] = nil
        Task {
            defer { loadingEditions.remove(album.id) }
            do {
                let editions = try await musicBrainz.cdEditions(releaseGroupId: id)
                guard let i = albums.firstIndex(where: { $0.id == album.id }) else { return }
                albums[i].editions = editions
                albums[i].editionsLoaded = true
            } catch {
                editionErrors[album.id] = error.localizedDescription
            }
        }
    }

    /// Opens one edition straight away (an album page's "Shop for This CD"), falling back to a search.
    func shop(releaseId: String?, album: String, artist: String) {
        query = CDSearchQuery(album: album, artist: artist)
        target = nil
        guard let releaseId, let musicBrainz else { search(); return }
        searchState = .searching
        searchTask?.cancel()
        searchTask = Task {
            if let edition = try? await musicBrainz.cdEdition(releaseId: releaseId) {
                albums = CDEditionParser.albums([edition])
                expandedAlbum = albums.first?.id
                searchState = .done
                lock(edition: edition, album: albums[0])
            } else {
                search()
            }
        }
    }

    // MARK: Shopping

    /// Shops for one edition, or (with `edition` nil) any CD edition of the album.
    func lock(edition: CDEdition?, album: CDAlbum) {
        lock(CDShoppingTarget(album: album.title, artist: album.artist, releaseGroupId: album.releaseGroupId, edition: edition))
    }

    /// Shops for what was typed, for a CD MusicBrainz doesn't list (new, local or rare releases).
    func shopByName() {
        guard !query.isEmpty else { return }
        lock(CDShoppingTarget(byName: query))
    }

    private func lock(_ target: CDShoppingTarget) {
        self.target = target
        offers = []
        raw = []
        discogsStats = nil
        resolveError = nil
        shopStates = Dictionary(uniqueKeysWithValues: CDShop.searched.map { ($0, .waiting) })
        shopTask?.cancel()
        shopTask = Task { await run(target, force: false) }
    }

    func unlock() {
        shopTask?.cancel()
        runID = UUID()
        target = nil
    }

    func refresh() {
        guard let target else { return }
        shopTask?.cancel()
        shopTask = Task { await run(target, force: true) }
    }

    private func run(_ initial: CDShoppingTarget, force: Bool) async {
        if !force, let hit = cache.first(where: { key, _ in
            key.edition == initial.edition && key.releaseGroupId == initial.releaseGroupId
                && (!initial.isByName || (key.album == initial.album && key.artist == initial.artist && key.typedBarcode == initial.typedBarcode))
        }),
           Date().timeIntervalSince(hit.value.at) < Self.cacheAge {
            target = hit.key
            raw = hit.value.offers
            shopStates = hit.value.states
            discogsStats = hit.value.stats
            updateOffers()
            return
        }
        await loadRatesIfNeeded()
        var target = initial
        isResolving = true
        do {
            target.links = try await musicBrainz?.cdShopLinks(releaseId: target.edition?.id, releaseGroupId: target.releaseGroupId) ?? CDShopLinks()
        } catch {
            resolveError = "Couldn't look up the CD's links on MusicBrainz: \(error.localizedDescription)"
        }
        isResolving = false
        guard !Task.isCancelled else { return }
        self.target = target
        raw = []
        offers = []
        shopStates = Dictionary(uniqueKeysWithValues: CDShop.searched.map { ($0, .waiting) })
        let requests = CDShopURLs.requests(for: target)
        if !requests.contains(where: { $0.shop == .discogs }) { shopStates[.discogs] = .notLinked }
        if target.edition != nil, let release = target.links.discogsRelease {
            Task { discogsStats = await Self.stats(release: release) }
        }
        // Stores in parallel; each store's pages one after another.
        let byShop = Dictionary(grouping: requests, by: \.shop)
        let run = UUID()
        runID = run
        let tasks = byShop.map { shop, list in Task { await self.load(shop, list, run: run) } }
        for task in tasks { await task.value }
        guard !Task.isCancelled else { return }
        cache[target] = (raw, shopStates, discogsStats, Date())
    }

    private func load(_ shop: CDShop, _ requests: [CDShopRequest], run: UUID) async {
        shopStates[shop] = .loading
        var count = 0
        var failure: String?
        for request in requests {
            guard runID == run else { return }
            do {
                let html = try await loader.html(request.url, shop: shop)
                guard runID == run else { return }
                let found = CDShopParser.parse(html, request: request)
                raw += found
                count += found.count
                updateOffers()
            } catch {
                failure = error.localizedDescription
            }
        }
        guard runID == run else { return }
        let kept = offers.filter { $0.shop == shop }.count
        if let failure, count == 0 { shopStates[shop] = .failed(failure) } else { shopStates[shop] = .done(kept) }
    }

    private func updateOffers() {
        guard let target else { return }
        offers = CDOfferMatcher.filter(raw, for: target, rates: rates)
    }

    /// Offers left after the filters, in order (best matches, then cheapest).
    var shownOffers: [CDOffer] {
        offers.filter { offer in
            guard !hiddenShops.contains(offer.shop) else { return false }
            guard showsPossible || offer.match != .possible else { return false }
            switch condition {
            case .any: return true
            case .new: return offer.condition == .new
            case .used: return offer.condition == .used
            }
        }
    }

    func count(_ shop: CDShop) -> Int { offers.filter { $0.shop == shop }.count }

    // MARK: Prices

    private func loadRatesIfNeeded() async {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        guard rates.perDollar.isEmpty || rates.date < Self.dayBefore(today) else { return }
        var request = URLRequest(url: ExchangeRates.url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let parsed = try? ExchangeRates.parse(data) else { return }
        rates = parsed
        UserDefaults.standard.set(try? JSONEncoder().encode(parsed), forKey: Self.ratesKey)
    }

    /// Rates are published on working days, so a one-day-old date is current.
    private static func dayBefore(_ day: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        guard let d = f.date(from: day) else { return day }
        return f.string(from: d.addingTimeInterval(-3 * 86_400))
    }

    func dollars(_ offer: CDOffer) -> Decimal? { offer.totalDollars(rates) }

    private static func stats(release: Int) async -> DiscogsMarketStats? {
        guard let url = DiscogsMarketStats.url(release: release) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? DiscogsMarketStats.parse(data)
    }
}
