import Foundation
import MusicLibraryCore

/// Upcoming concerts near home: the user's ZIP code, how far they'd travel, the concert services' API keys,
/// and the results (per artist for artist pages, and a scan of the whole library for the Concerts page),
/// cached in `~/Library/Caches/MusicLibrary/concerts.json` because the services' free quotas are small.
@MainActor @Observable
final class ConcertStore {
    private enum Keys {
        static let postalCode = "concertPostalCode"
        static let home = "concertHome"
        static let radius = "concertRadius"
        static let onArtistPages = "concertsOnArtistPages"
        static let ticketmaster = "ticketmasterAPIKey"
        static let jambase = "jambaseAPIKey"
    }

    static let radiusChoices = [10, 25, 50, 100, 200]
    /// Per artist; a whole-library scan costs more requests, so it's kept longer.
    static let artistMaxAge: TimeInterval = 24 * 3600
    static let scanMaxAge: TimeInterval = 48 * 3600

    let country = Locale.current.region?.identifier ?? "US"
    let unit = DistanceUnit.preferred()
    var codeName: String { country == "US" ? "ZIP code" : "Postal code" }

    /// What the user typed (applied with `applyPostalCode`).
    private(set) var postalCode: String
    private(set) var home: HomeLocation? {
        didSet { UserDefaults.standard.set(home.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.home) }
    }
    private(set) var isLocating = false
    private(set) var locationError: String?

    var radius: Int {
        didSet { UserDefaults.standard.set(radius, forKey: Keys.radius); settingsChanged() }
    }
    var showsOnArtistPages: Bool {
        didSet { UserDefaults.standard.set(showsOnArtistPages, forKey: Keys.onArtistPages) }
    }
    var ticketmasterKey: String {
        didSet { keyChanged(.ticketmaster, from: oldValue, to: ticketmasterKey, account: Keys.ticketmaster) }
    }
    var jambaseKey: String {
        didSet { keyChanged(.jambase, from: oldValue, to: jambaseKey, account: Keys.jambase) }
    }

    private(set) var nearby: [String: NearbyConcerts] = [:]
    private(set) var loading: Set<String> = []
    private(set) var artistErrors: [String: String] = [:]
    /// Sources that failed while others answered, per artist.
    private(set) var artistWarnings: [String: [String]] = [:]

    private(set) var scan: ConcertScan?
    private(set) var isScanning = false
    private(set) var scanError: String?
    private(set) var scanWarnings: [String] = []

    @ObservationIgnored private var clients: [ConcertSource: any ConcertProvider] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var locateTask: Task<Void, Never>?
    @ObservationIgnored private let cacheURL: URL

    init(cacheURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicLibrary/concerts.json")) {
        let d = UserDefaults.standard
        self.cacheURL = cacheURL
        postalCode = d.string(forKey: Keys.postalCode) ?? ""
        home = d.data(forKey: Keys.home).flatMap { try? JSONDecoder().decode(HomeLocation.self, from: $0) }
        let storedRadius = d.integer(forKey: Keys.radius)
        radius = Self.radiusChoices.contains(storedRadius) ? storedRadius : 50
        showsOnArtistPages = d.object(forKey: Keys.onArtistPages) == nil ? true : d.bool(forKey: Keys.onArtistPages)
        ticketmasterKey = KeychainStore.app.string(for: Keys.ticketmaster) ?? ""
        jambaseKey = KeychainStore.app.string(for: Keys.jambase) ?? ""
        loadCache()
    }

    // MARK: Settings

    var sources: [ConcertSource] {
        ConcertSource.allCases.filter { key(for: $0).trimmingCharacters(in: .whitespaces).isEmpty == false }
    }

    var hasSource: Bool { !sources.isEmpty }
    var isConfigured: Bool { home != nil && hasSource }

    private func key(for source: ConcertSource) -> String {
        switch source {
        case .ticketmaster: ticketmasterKey
        case .jambase: jambaseKey
        }
    }

    /// Ticketmaster first: when both list a show, its link goes straight to tickets.
    private var providers: [any ConcertProvider] {
        sources.map { source in
            if let client = clients[source] { return client }
            let client: any ConcertProvider = switch source {
            case .ticketmaster: TicketmasterClient(apiKey: ticketmasterKey)
            case .jambase: JamBaseClient(apiKey: jambaseKey)
            }
            clients[source] = client
            return client
        }
    }

    /// "within 50 mi of Cambridge, MA"
    var areaDescription: String {
        "within \(radius) \(unit.abbreviation) of \(home?.place ?? postalCode)"
    }

    func distance(_ km: Double?) -> String? {
        guard let km else { return nil }
        let value = unit.fromKilometers(km)
        return value < 1 ? "< 1 \(unit.abbreviation)" : "\(Int(value.rounded())) \(unit.abbreviation)"
    }

    /// Looks up the code the user entered; an empty one turns concerts off.
    func applyPostalCode(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != postalCode || home == nil || locationError != nil else { return }
        locateTask?.cancel()
        locationError = nil
        if trimmed.isEmpty {
            postalCode = ""
            UserDefaults.standard.removeObject(forKey: Keys.postalCode)
            home = nil
            isLocating = false
            settingsChanged()
            return
        }
        guard let code = PostalCode.normalized(trimmed, country: country) else {
            locationError = country == "US" ? "Enter a 5-digit ZIP code." : "That doesn't look like a postal code."
            return
        }
        postalCode = code
        UserDefaults.standard.set(code, forKey: Keys.postalCode)
        if home?.postalCode == code, home?.country == country { return }
        isLocating = true
        let country = country
        locateTask = Task { [weak self] in
            let result: Result<HomeLocation?, Error>
            do { result = .success(try await PostalCode.locate(code, country: country)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.isLocating = false
            switch result {
            case .success(let found?):
                self.home = found
            case .success(nil), .failure:
                self.home = nil
                self.locationError = "Couldn't find \(code). Check it, or try again when you're online."
            }
            self.settingsChanged()
        }
    }

    private func keyChanged(_ source: ConcertSource, from old: String, to new: String, account: String) {
        guard old != new else { return }
        KeychainStore.app.set(new.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        clients[source] = nil
        artistErrors = [:]
        scanError = nil
        // Adding or removing a service changes what results there are; editing a key doesn't.
        if old.trimmingCharacters(in: .whitespaces).isEmpty != new.trimmingCharacters(in: .whitespaces).isEmpty { settingsChanged() }
    }

    /// Results for another place, distance or set of services no longer apply.
    private func settingsChanged() {
        clients = [:]
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        nearby = [:]
        loading = []
        artistErrors = [:]
        artistWarnings = [:]
        scan = nil
        scanError = nil
        scanWarnings = []
        saveCache()
    }

    // MARK: Artists

    static func key(_ artist: String) -> String { artist.lowercased() }

    func concerts(for artist: String) -> NearbyConcerts? { nearby[Self.key(artist)] }
    func isLoading(_ artist: String) -> Bool { loading.contains(Self.key(artist)) }
    func error(for artist: String) -> String? { artistErrors[Self.key(artist)] }
    func warnings(for artist: String) -> [String] { artistWarnings[Self.key(artist)] ?? [] }

    /// Fetches an artist's concerts unless fresh ones are cached (or `force`).
    func load(artist: String, mbid: String?, force: Bool = false) {
        let key = Self.key(artist)
        guard isConfigured, let home, !artist.isEmpty, !loading.contains(key) else { return }
        if !force, let cached = nearby[key], Date().timeIntervalSince(cached.fetchedAt) < Self.artistMaxAge { return }
        loading.insert(key)
        artistErrors[key] = nil
        let providers = providers, radius = radius, unit = unit
        Task { [weak self] in
            let outcome: Result<(NearbyConcerts, [ConcertError]), Error>
            do {
                outcome = .success(try await ConcertFinder.find(artist: artist, mbid: mbid, near: home.point, radius: radius,
                                                                unit: unit, providers: providers))
            } catch { outcome = .failure(error) }
            guard let self, self.loading.remove(key) != nil else { return }
            switch outcome {
            case .success(let (found, errors)):
                self.nearby[key] = found
                self.artistWarnings[key] = errors.compactMap(\.errorDescription)
                self.saveCache()
            case .failure(let error):
                self.artistErrors[key] = error.localizedDescription
            }
        }
    }

    // MARK: Library

    var scanIsStale: Bool { scan.map { Date().timeIntervalSince($0.scannedAt) > Self.scanMaxAge } ?? true }

    /// Looks for every library artist's concerts, unless a recent scan is cached (or `force`).
    func scanLibrary(_ artists: [ConcertArtist], force: Bool = false) {
        guard isConfigured, let home, !isScanning, force || scanIsStale, !artists.isEmpty else { return }
        isScanning = true
        scanError = nil
        let providers = providers, radius = radius, unit = unit
        scanTask = Task { [weak self] in
            let outcome: Result<(ConcertScan, [ConcertError]), Error>
            do {
                outcome = .success(try await ConcertFinder.scan(artists, near: home.point, radius: radius, unit: unit, providers: providers))
            } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            self.scanTask = nil
            switch outcome {
            case .success(let (found, errors)):
                self.scan = found
                self.scanWarnings = errors.compactMap(\.errorDescription)
                self.saveCache()
            case .failure(let error):
                self.scanError = error.localizedDescription
            }
        }
    }

    // MARK: Cache

    private struct Cache: Codable {
        var context: String
        var nearby: [String: NearbyConcerts]
        var scan: ConcertScan?
    }

    /// What the cached results were found for.
    private var context: String {
        [home?.postalCode ?? "", home?.country ?? "", String(radius), unit.rawValue, sources.map(\.rawValue).joined(separator: "+")]
            .joined(separator: "|")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.context == context else { return }
        nearby = cache.nearby.filter { Date().timeIntervalSince($0.value.fetchedAt) < Self.artistMaxAge * 7 }
        scan = cache.scan
    }

    private func saveCache() {
        let cache = Cache(context: context, nearby: nearby, scan: scan)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
