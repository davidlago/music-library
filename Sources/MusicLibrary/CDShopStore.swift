import Foundation
import MusicLibraryCore
import MusicLibraryUI

/// The Shop: find the exact CD or record on Discogs (MusicBrainz when Discogs has nothing), then gather copies for sale from marketplaces that ship to
/// the US (`CDShop.searched`), plus links to search a few more, and the price guide (`PriceGuide`: Discogs' figures
/// and, once the user has signed in to eBay in Settings ▸ Shop, recent eBay sales). Nothing else is signed in to.
/// Results are kept in memory for half an hour per CD or record; exchange rates (to compare prices in other
/// currencies) once a day. The Radio DJ can open it on an album too (`find(_:)`), and price albums (`priceGuides`).
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
        /// The CD has no Discogs release or master (MusicBrainz doesn't link it).
        case notLinked
    }

    enum ConditionFilter: String, CaseIterable, Identifiable {
        case any = "Any Condition", new = "New", used = "Used"
        var id: String { rawValue }
    }

    var query = CDSearchQuery()
    private(set) var searchState: SearchState = .idle
    /// The format of the albums and editions listed (the query's when it was searched).
    private(set) var format: ShopFormat = .cd
    /// Where the albums listed come from (being searched while `searchState` is `.searching`): Discogs first, then
    /// MusicBrainz when Discogs finds nothing or can't be reached.
    private(set) var source: CDSearchSource = .discogs
    private(set) var albums: [CDAlbum] = []
    var expandedAlbum: String?
    /// For a search by artist alone on MusicBrainz: the artists it matched, and the one whose albums are listed.
    private(set) var artists: [CDArtist] = []
    private(set) var artist: CDArtist?
    /// For a search by artist alone: the name of the artist whose albums are listed.
    private(set) var discography: String?
    /// Albums whose editions are being looked up.
    private(set) var loadingEditions: Set<String> = []
    private(set) var editionErrors: [String: String] = [:]

    private(set) var target: CDShoppingTarget?
    private(set) var isResolving = false
    private(set) var resolveError: String?
    private(set) var shopStates: [CDShop: ShopState] = [:]
    private(set) var offers: [CDOffer] = []
    private(set) var discogsStats: DiscogsMarketStats?
    /// The price guide for the target (nil while it's read).
    private(set) var priceGuide: PriceGuide?
    /// The target album on Apple Music, with its songs and their previews (nil: not found, or not looked up yet).
    private(set) var appleAlbum: AppleAlbum?
    private(set) var isFindingApple = false
    @ObservationIgnored private let appleFinder = ApplePreviewFinder(client: ApplePreviewClient(country: Locale.current.region?.identifier ?? "US"))
    @ObservationIgnored private var appleCache: [String: AppleAlbum?] = [:]
    @ObservationIgnored private var appleTask: Task<Void, Never>?
    /// The lookup whose answer is wanted (the target itself changes once its store links are read, so it can't be
    /// compared).
    @ObservationIgnored private var appleRun = UUID()
    private(set) var isPricing = false
    private(set) var rates = ExchangeRates()
    /// The eBay sign-in for sold prices (opt-in, Settings ▸ Shop).
    let ebay = EbaySession()
    /// The Discogs account's token and username, for suggested prices and what's in the user's Discogs collection.
    @ObservationIgnored var discogsAccount: () -> (token: String?, username: String?) = { (nil, nil) }
    /// Each price guide read (the Buy List keeps it as the album's latest price when it's on the list).
    @ObservationIgnored var onPriceGuide: (PriceGuide) -> Void = { _ in }
    @ObservationIgnored private var guides: (key: String, guides: PriceGuides)?
    @ObservationIgnored private var guideCache: [CDShoppingTarget: (guide: PriceGuide, at: Date)] = [:]
    @ObservationIgnored private var guideTask: Task<Void, Never>?

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
        guard !query.isEmpty else { return }
        let q = query
        let guides = priceGuides()
        let musicBrainz = musicBrainz
        searchTask?.cancel()
        searchState = .searching
        source = .discogs
        format = q.format
        artists = []
        artist = nil
        discography = nil
        editionErrors = [:]
        searchTask = Task {
            // Discogs first: it lists far more CD and vinyl editions than MusicBrainz.
            var discogsError: String?
            do {
                let found = try await guides.shopAlbums(q)
                guard !Task.isCancelled else { return }
                if !found.isEmpty {
                    albums = found
                    if q.isArtistAlone {
                        let names = Set(found.map(\.artist))
                        discography = names.count == 1 ? found[0].artist : q.artist.trimmingCharacters(in: .whitespaces)
                        expandedAlbum = nil
                    } else {
                        expandedAlbum = found.count == 1 ? found.first?.id : nil
                    }
                    searchState = .done
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                discogsError = error.localizedDescription
            }
            // Nothing there (or Discogs is busy or unreachable): MusicBrainz.
            guard let musicBrainz else {
                albums = []
                searchState = discogsError.map { SearchState.failed($0) } ?? .done
                return
            }
            source = .musicBrainz
            do {
                if q.isArtistAlone {
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
                searchState = .failed(discogsError.map { "Discogs: \($0) MusicBrainz: \(error.localizedDescription)" } ?? error.localizedDescription)
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
        discography = artist.name
        albums = []
        expandedAlbum = nil
        let found = try await musicBrainz.cdAlbums(artist: artist)
        guard !Task.isCancelled, self.artist == artist else { return }
        albums = found
    }

    /// Opens or closes an album, looking up its editions the first time (a Discogs master's versions, or a MusicBrainz
    /// release group's releases).
    func toggle(_ album: CDAlbum) {
        if expandedAlbum == album.id { expandedAlbum = nil; return }
        expandedAlbum = album.id
        guard !album.editionsLoaded, !loadingEditions.contains(album.id) else { return }
        guard album.discogsMasterID != nil || (album.releaseGroupId != nil && musicBrainz != nil) else { return }
        loadingEditions.insert(album.id)
        editionErrors[album.id] = nil
        let format = format
        let guides = priceGuides()
        let musicBrainz = musicBrainz
        Task {
            defer { loadingEditions.remove(album.id) }
            do {
                let editions: [CDEdition]
                if let master = album.discogsMasterID {
                    editions = try await guides.shopEditions(masterID: master, format: format, artist: album.artist)
                } else if let id = album.releaseGroupId, let musicBrainz {
                    editions = try await musicBrainz.cdEditions(releaseGroupId: id, format: format)
                } else {
                    return
                }
                guard self.format == format else { return }
                guard let i = albums.firstIndex(where: { $0.id == album.id }) else { return }
                albums[i].editions = editions
                albums[i].editionsLoaded = true
            } catch {
                editionErrors[album.id] = error.localizedDescription
            }
        }
    }

    /// Opens one edition straight away (an album page's "Shop for This CD"), falling back to a search (also when
    /// the release isn't on `format`).
    func shop(releaseId: String?, album: String, artist: String, format: ShopFormat = .cd) {
        unlock()
        query = CDSearchQuery(album: album, artist: artist, format: format)
        guard let releaseId, let musicBrainz else { search(); return }
        searchState = .searching
        self.format = format
        searchTask?.cancel()
        searchTask = Task {
            if let edition = try? await musicBrainz.cdEdition(releaseId: releaseId, format: format) {
                albums = CDEditionParser.albums([edition])
                expandedAlbum = albums.first?.id
                searchState = .done
                lock(edition: edition, album: albums[0])
            } else {
                search()
            }
        }
    }

    /// The DJ's `open_shop`: searches for the album as the page would and, once Discogs (or MusicBrainz) answers, says
    /// what came up.
    func find(_ request: RadioDJShopRequest) async -> String {
        unlock()
        query = request.query
        search()
        await searchTask?.value
        guard query == request.query else { return "The listener started another search on the Shop page meanwhile." }
        if case .failed(let message) = searchState {
            return RadioDJShopRequest.summary([], request: request, error: message, source: source)
        }
        return RadioDJShopRequest.summary(albums, request: request, source: source)
    }

    // MARK: Shopping

    /// Shops for one edition, or (with `edition` nil) any edition of the album in the format listed. A Discogs album
    /// takes its master and release with it, so the stores and the price guide don't need MusicBrainz's links.
    func lock(edition: CDEdition?, album: CDAlbum) {
        // A Discogs release that isn't a version of a master is an album of its own: any edition is that one.
        let edition = edition ?? (album.isDiscogs && album.discogsMasterID == nil && album.editions.count == 1 ? album.editions.first : nil)
        var target = CDShoppingTarget(album: album.title, artist: album.artist, releaseGroupId: album.releaseGroupId, edition: edition,
                                      format: format)
        target.links.discogsMaster = album.discogsMasterID ?? edition?.discogsMasterID
        target.links.discogsRelease = edition?.discogsReleaseID
        lock(target)
    }

    /// Shops for an album from the Buy List: its Discogs master or release when known, else by name.
    func shop(_ album: WantedAlbum) {
        shop(album: album.album, artist: album.artist, format: album.format, barcode: album.barcode,
             master: album.discogsMasterID, release: album.discogsReleaseID)
    }

    /// Shops for one of the Recent Finds again.
    func shop(_ find: ShopFind) {
        shop(album: find.album, artist: find.artist, format: find.format, barcode: find.barcode, master: find.masterID, release: find.releaseID)
    }

    private func shop(album: String, artist: String, format: PriceGuideRequest.Format, barcode: String, master: Int?, release: Int?) {
        query = CDSearchQuery(album: album, artist: artist, format: format.shopFormat)
        var links = CDShopLinks()
        links.discogsMaster = master
        links.discogsRelease = release
        var target = CDShoppingTarget(album: album, artist: artist, releaseGroupId: nil, edition: nil, links: links,
                                      format: format.shopFormat)
        target.typedBarcode = barcode.isEmpty ? nil : barcode
        lock(target)
    }

    // MARK: Recent Finds

    /// Albums priced in the Shop on this Mac or the iPhone, newest first (`ShopFinds.swift`; in the library database,
    /// so they sync both ways).
    private(set) var finds: [ShopFind] = []
    @ObservationIgnored var database: () -> Database? = { nil }

    func reloadFinds() {
        finds = ShopFind.shown((try? database()?.shopFinds()) ?? [])
    }

    private func recordFind(_ guide: PriceGuide) {
        guard let find = ShopFind(guide: guide), let db = database() else { return }
        _ = try? db.saveShopFinds([find])
        reloadFinds()
    }

    func removeFinds(_ ids: Set<String>) {
        guard let db = database() else { return }
        _ = try? db.saveShopFinds(finds.filter { ids.contains($0.id) }.map { $0.removing() })
        reloadFinds()
    }

    /// Shops for what was typed, for a CD or record neither Discogs nor MusicBrainz lists (new, local or rare releases).
    func shopByName() {
        guard !query.isEmpty else { return }
        lock(CDShoppingTarget(byName: query))
    }

    private func lock(_ target: CDShoppingTarget) {
        self.target = target
        offers = []
        raw = []
        discogsStats = nil
        priceGuide = nil
        resolveError = nil
        shopStates = Dictionary(uniqueKeysWithValues: CDShop.searched.map { ($0, .waiting) })
        shopTask?.cancel()
        shopTask = Task { await run(target, force: false) }
        findOnApple(target)
    }

    /// The album's songs on Apple Music, for the track list and its previews (once per album and format).
    private func findOnApple(_ target: CDShoppingTarget) {
        appleTask?.cancel()
        let key = "\(target.artist)|\(target.album)|\(target.edition?.barcode ?? target.typedBarcode ?? "")".lowercased()
        if let cached = appleCache[key] { appleRun = UUID(); appleAlbum = cached; isFindingApple = false; return }
        appleAlbum = nil
        isFindingApple = true
        let run = UUID()
        appleRun = run
        let finder = appleFinder
        let barcodes = [target.edition?.barcode, target.typedBarcode].compactMap { $0 }.filter { !$0.isEmpty }
        let year = target.edition.flatMap { Int($0.date.prefix(4)) }
        appleTask = Task {
            let tracks = target.edition.map(\.trackCount).flatMap { $0 > 0 ? $0 : nil }
            var found: AppleAlbum?
            do {
                found = try await finder.album(title: target.album, artist: target.artist, barcodes: barcodes, trackCount: tracks, year: year)
                // Only a real answer is remembered (a failed request is tried again next time).
                appleCache[key] = .some(found)
            } catch {}
            guard appleRun == run else { return }
            appleAlbum = found
            isFindingApple = false
        }
    }

    func unlock() {
        shopTask?.cancel()
        appleTask?.cancel()
        appleRun = UUID()
        isFindingApple = false
        guideTask?.cancel()
        isPricing = false
        runID = UUID()
        target = nil
    }

    func refresh() {
        guard let target else { return }
        shopTask?.cancel()
        shopTask = Task { await run(target, force: true) }
    }

    private func run(_ initial: CDShoppingTarget, force: Bool) async {
        if !force, let hit = cache.first(where: { key, _ in Self.isSame(key, initial) }),
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
        // A MusicBrainz edition or album: its Discogs release and master, and its Amazon ASIN, from MusicBrainz's links.
        // Links the target came with (a Discogs search, the Buy List) are kept.
        if target.edition?.musicBrainzID != nil || target.releaseGroupId != nil {
            isResolving = true
            do {
                let found = try await musicBrainz?.cdShopLinks(releaseId: target.edition?.musicBrainzID, releaseGroupId: target.releaseGroupId) ?? CDShopLinks()
                target.links = initial.links.merged(with: found)
            } catch {
                resolveError = "Couldn't look up the \(target.format.noun)'s links on MusicBrainz: \(error.localizedDescription)"
            }
            isResolving = false
        }
        guard !Task.isCancelled else { return }
        self.target = target
        loadPriceGuide(for: target, force: force)
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

    /// Whether a cached run was for this target. MusicBrainz targets gain their links only once looked up, so they're
    /// told apart by edition and album; the rest by what they were made from.
    private static func isSame(_ key: CDShoppingTarget, _ target: CDShoppingTarget) -> Bool {
        guard key.format == target.format, key.edition == target.edition, key.releaseGroupId == target.releaseGroupId else { return false }
        if target.edition?.musicBrainzID != nil || target.releaseGroupId != nil { return true }
        return key.album == target.album && key.artist == target.artist && key.typedBarcode == target.typedBarcode
            && key.links.discogsMaster == target.links.discogsMaster && key.links.discogsRelease == target.links.discogsRelease
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
    /// What Discogs sellers in the US charge to ship the copies found, in the guide's currency (`CDOffer.usShipping`).
    func usShipping(in guide: PriceGuide) -> Money? {
        guard let currency = guide.mostCommon?.fairRange?.low.currency ?? guide.mostCommon?.lowest?.currency else { return nil }
        return CDOffer.usShipping(offers, currency: currency, rates: rates)
    }

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

    /// What the Shop shows, for the Radio DJ: the search and its albums, or the copies of the CD or record picked
    /// (the cheapest few). The title names the target, so picking another is a move to another page.
    var radioDJPage: RadioDJSubject {
        guard let target else {
            var details = ["The listener can search Discogs (and MusicBrainz when Discogs has nothing) for an album's CD or vinyl editions here, pick one and compare copies for sale on Discogs, eBay, CDandLP and Alibris."]
            if searchState != .idle {
                let request = RadioDJShopRequest(album: query.album, artist: query.artist, format: format, code: query.code)
                details.append(RadioDJShopRequest.summary(albums, request: request, source: source))
            }
            return .page("the Shop", details: details)
        }
        let what = [target.isByName ? "found by name" : target.edition == nil ? "any \(target.format.name) edition" : "one \(target.format.name) edition",
                    target.edition.map { e in [e.date, e.country, e.label, e.catalogNumber, e.format].filter { !$0.isEmpty }.joined(separator: " · ") }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        var details = ["Shopping for \(what)", "\(offers.count) copies for sale found so far"]
        details += offers.prefix(6).map { offer in
            let price = dollars(offer).map { Money($0, "USD").formatted() } ?? offer.price.formatted()
            return "\(offer.shop.name): \(offer.title), \(offer.conditionText.isEmpty ? offer.condition.rawValue : offer.conditionText), \(price) (with shipping when the store lists it)"
        }
        return .page("the Shop, \(target.format == .cd ? "CDs" : "records") of *\(target.album)* by \(target.artist)", details: details)
    }

    // MARK: Price guide

    /// The price guides, for the Shop and the Radio DJ (rebuilt when the Discogs account changes). On the Mac the
    /// Shop reads eBay's listings itself, so the guide adds only recent sales, and only once signed in to eBay.
    func priceGuides() -> PriceGuides {
        let account = discogsAccount()
        let key = "\(account.token ?? "")|\(account.username ?? "")"
        if let guides, guides.key == key { return guides.guides }
        let made = PriceGuides(token: account.token, username: account.username,
                               currency: Locale.current.currency?.identifier ?? "USD",
                               ebay: loader.ebayReader(ebay, readsForSale: false), discogsPages: loader.discogsReader())
        Task { await made.prefetchCollection() }
        guides = (key, made)
        return made
    }

    private func loadPriceGuide(for target: CDShoppingTarget, force: Bool) {
        if !force, let hit = guideCache[target], Date().timeIntervalSince(hit.at) < Self.cacheAge {
            priceGuide = hit.guide
            return
        }
        let e = target.edition
        let request = PriceGuideRequest(
            artist: target.artist, album: target.album, format: PriceGuideRequest.Format(target.format),
            barcode: target.barcode ?? "", catalogNumber: e.map { $0.catalogNumber.components(separatedBy: "; ").first ?? "" } ?? "",
            label: e?.label ?? "", country: e?.country ?? "", year: e.flatMap { Int($0.date.prefix(4)) },
            releaseID: e == nil ? nil : target.links.discogsRelease, masterID: target.links.discogsMaster)
        let guides = priceGuides()
        guideTask?.cancel()
        isPricing = true
        priceGuide = nil
        guideTask = Task {
            let guide = await guides.fullGuide(for: request)
            guard !Task.isCancelled, self.target == target else { return }
            priceGuide = guide
            isPricing = false
            guideCache[target] = (guide, Date())
            recordFind(guide)
            onPriceGuide(guide)
        }
    }

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
