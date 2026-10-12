import Foundation
import MusicLibraryCore
import Observation

/// Upcoming concerts near home on artist pages, with the settings the Mac hands over at each sync (home, distance
/// and the concert services' keys, which go in the keychain). Results are cached in Caches `concerts.json` for a day
/// per artist, because the services' free quotas are small.
@Observable
final class PhoneConcerts {
    private enum Keys {
        static let settings = "concertSettings"
        static let ticketmaster = "ticketmasterAPIKey"
        static let jambase = "jambaseAPIKey"
    }

    static let maxAge: TimeInterval = 24 * 3600

    /// Where and how far, from the Mac (the keys aren't kept here).
    private struct Area: Codable, Equatable {
        var home: HomeLocation
        var radius: Int
        var unit: DistanceUnit
    }

    private var area: Area? {
        didSet { UserDefaults.standard.set(area.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.settings) }
    }
    private var ticketmasterKey: String
    private var jambaseKey: String

    private(set) var nearby: [String: NearbyConcerts] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var warnings: [String: [String]] = [:]

    @ObservationIgnored private var clients: [ConcertSource: any ConcertProvider] = [:]
    @ObservationIgnored private let cacheURL = URL.cachesDirectory.appendingPathComponent("concerts.json")

    init() {
        area = UserDefaults.standard.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(Area.self, from: $0) }
        ticketmasterKey = KeychainStore.app.string(for: Keys.ticketmaster) ?? ""
        jambaseKey = KeychainStore.app.string(for: Keys.jambase) ?? ""
        loadCache()
    }

    var sources: [ConcertSource] {
        ConcertSource.allCases.filter { !key(for: $0).trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var isConfigured: Bool { area != nil && !sources.isEmpty }

    /// "within 50 mi of Cambridge, MA"
    var areaDescription: String {
        guard let area else { return "" }
        return "within \(area.radius) \(area.unit.abbreviation) of \(area.home.place)"
    }

    func distance(_ km: Double?) -> String? {
        guard let km, let unit = area?.unit else { return nil }
        let value = unit.fromKilometers(km)
        return value < 1 ? "< 1 \(unit.abbreviation)" : "\(Int(value.rounded())) \(unit.abbreviation)"
    }

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

    /// The Mac's settings, from a sync. Results for another place, distance or set of services are dropped.
    func adopt(_ settings: SyncConcertSettings) {
        let newArea = Area(home: settings.home, radius: settings.radius, unit: settings.unit)
        let oldContext = context
        if ticketmasterKey != settings.ticketmasterKey {
            ticketmasterKey = settings.ticketmasterKey
            KeychainStore.app.set(settings.ticketmasterKey, for: Keys.ticketmaster)
        }
        if jambaseKey != settings.jambaseKey {
            jambaseKey = settings.jambaseKey
            KeychainStore.app.set(settings.jambaseKey, for: Keys.jambase)
        }
        if area != newArea { area = newArea }
        clients = [:]
        if context != oldContext {
            nearby = [:]
            errors = [:]
            warnings = [:]
            saveCache()
        }
    }

    // MARK: Artists

    private static func key(_ artist: String) -> String { artist.lowercased() }

    func concerts(for artist: String) -> NearbyConcerts? { nearby[Self.key(artist)] }
    func isLoading(_ artist: String) -> Bool { loading.contains(Self.key(artist)) }
    func error(for artist: String) -> String? { errors[Self.key(artist)] }
    func warnings(for artist: String) -> [String] { warnings[Self.key(artist)] ?? [] }

    /// Fetches an artist's concerts unless fresh ones are cached (or `force`).
    func load(artist: String, mbid: String?, force: Bool = false) {
        let key = Self.key(artist)
        guard isConfigured, let area, !artist.isEmpty, !loading.contains(key) else { return }
        if !force, let cached = nearby[key], Date().timeIntervalSince(cached.fetchedAt) < Self.maxAge { return }
        loading.insert(key)
        errors[key] = nil
        let providers = providers
        Task { [weak self] in
            let outcome: Result<(NearbyConcerts, [ConcertError]), Error>
            do {
                outcome = .success(try await ConcertFinder.find(artist: artist, mbid: mbid, near: area.home.point, radius: area.radius,
                                                                unit: area.unit, providers: providers))
            } catch { outcome = .failure(error) }
            guard let self, self.loading.remove(key) != nil else { return }
            switch outcome {
            case .success(let (found, errors)):
                self.nearby[key] = found
                self.warnings[key] = errors.compactMap(\.errorDescription)
                self.saveCache()
            case .failure(let error):
                self.errors[key] = error.localizedDescription
            }
        }
    }

    // MARK: Cache

    private struct Cache: Codable {
        var context: String
        var nearby: [String: NearbyConcerts]
    }

    private var context: String {
        guard let area else { return "" }
        return [area.home.postalCode, area.home.country, String(area.radius), area.unit.rawValue, sources.map(\.rawValue).joined(separator: "+")]
            .joined(separator: "|")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.context == context else { return }
        nearby = cache.nearby.filter { Date().timeIntervalSince($0.value.fetchedAt) < Self.maxAge * 7 }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(Cache(context: context, nearby: nearby)) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
