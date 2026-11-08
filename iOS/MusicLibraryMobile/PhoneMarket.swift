import Foundation
import MusicLibraryCore
import Observation

/// The Buy List and what copies are worth, on the phone. The Buy List is the copy's (`LibrarySnapshot.wanted`) with
/// the changes made here since (`WantedOutbox`, Application Support `wanted-outbox.json`) merged in; those go to the
/// Mac at the next Wi-Fi sync or through the iCloud inbox, and leave the outbox once a copy shows them applied. Prices
/// read here (Refresh, the Shop) are changes too, so the Mac gets them. Values are the copy's (priced on the Mac) or
/// priced here on an item's page, kept on the phone (`item-values.json`), the newer winning. The sample library has
/// its own outbox (`sample-wanted.json`), never sent and dropped with the sample.
@Observable
final class PhoneMarket {
    private(set) var all: [WantedAlbum] = []
    private(set) var shown: [WantedAlbum] = []
    private(set) var values: [String: CollectionValue] = [:]
    private(set) var valueStats = CollectionValueStats()
    /// Full guides read on item pages this session.
    private(set) var itemGuides: [String: PriceGuide] = [:]
    private(set) var pricing: Set<String> = []
    private(set) var checking: Set<String> = []
    private(set) var progress: (done: Int, total: Int)?

    @ObservationIgnored let outbox = WantedOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("wanted-outbox.json"))
    @ObservationIgnored let sampleOutbox = WantedOutbox(url: URL.applicationSupportDirectory.appendingPathComponent("sample-wanted.json"))
    @ObservationIgnored private let valuesURL = URL.applicationSupportDirectory.appendingPathComponent("item-values.json")
    @ObservationIgnored private var localValues: [String: CollectionValue] = [:]
    @ObservationIgnored private var base: [WantedAlbum] = []
    @ObservationIgnored private var baseValues: [String: CollectionValue] = [:]
    @ObservationIgnored private var collection = MusicCollection.empty
    @ObservationIgnored private var isSample = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    @ObservationIgnored var guides: () -> PriceGuides? = { nil }
    /// Something for the Mac changed (sent through iCloud a few seconds later).
    @ObservationIgnored var onChange: () -> Void = {}

    init() {
        if let data = try? Data(contentsOf: valuesURL),
           let saved = try? JSONDecoder().decode([CollectionValue].self, from: data) {
            localValues = Dictionary(saved.map { ($0.itemID, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
        }
    }

    private var activeOutbox: WantedOutbox { isSample ? sampleOutbox : outbox }

    /// The changes waiting for the Mac (none from the sample library).
    var pendingChanges: [WantedAlbum] { isSample ? [] : outbox.changes }

    /// A new copy, or the collection changed: the list and values again, and the outbox without what the copy has.
    func update(library: LibrarySnapshot?, collection: MusicCollection, isSample: Bool) {
        self.isSample = isSample
        self.collection = collection
        base = library?.wanted ?? []
        baseValues = library?.collectionValues ?? [:]
        if !isSample { outbox.remove(BuyList.applied(outbox.changes, in: base)) }
        rebuild()
    }

    func forgetSample() { sampleOutbox.removeAll() }

    private func rebuild() {
        all = BuyList.overlay(base, activeOutbox.changes)
        shown = BuyList.shown(all)
        var merged = baseValues
        for (id, v) in localValues where merged[id].map({ $0.at < v.at }) ?? true { merged[id] = v }
        values = merged
        valueStats = CollectionValueStats.make(collection: collection, values: merged)
    }

    // MARK: Buy List

    func entry(artist: String, album: String, format: PriceGuideRequest.Format) -> WantedAlbum? {
        BuyList.entry(in: all, artist: artist, album: album, format: format)
    }

    func album(id: String) -> WantedAlbum? { all.first { $0.id == id && !$0.removed } }

    private func put(_ albums: [WantedAlbum]) {
        for a in albums { activeOutbox.put(a) }
        rebuild()
        if !isSample { onChange() }
    }

    @discardableResult
    func add(_ guide: PriceGuide) -> WantedAlbum {
        let fresh = WantedAlbum(guide: guide, currency: guides()?.currency ?? currencyCode)
        if var existing = entry(artist: fresh.artist, album: fresh.album, format: fresh.format) {
            existing.take(guide)
            put([existing])
            return existing
        }
        put([fresh])
        return fresh
    }

    /// Adds an album by name (typed); the caller prices it.
    @discardableResult
    func add(artist: String, album: String, format: PriceGuideRequest.Format, barcode: String = "", maxPrice: Decimal? = nil,
             notes: String = "") -> WantedAlbum {
        if let existing = entry(artist: artist, album: album, format: format) { return existing }
        let w = WantedAlbum(artist: artist, album: album, format: format, barcode: barcode, maxPrice: maxPrice,
                            currency: guides()?.currency ?? currencyCode, notes: notes)
        put([w])
        return w
    }

    func update(_ album: WantedAlbum) {
        var edited = album
        edited.updatedAt = Date()
        put([edited])
    }

    func remove(_ ids: Set<String>) {
        let now = Date()
        put(all.filter { ids.contains($0.id) && !$0.removed }.map { var w = $0; w.removed = true; w.updatedAt = now; return w })
    }

    /// A guide read in the Shop for an album on the list: its latest price.
    func noteGuide(_ guide: PriceGuide) {
        guard guide.hasPrices else { return }
        let title = guide.title.isEmpty ? guide.request.album : guide.title
        let artist = guide.artist.isEmpty ? guide.request.artist : guide.artist
        guard var w = entry(artist: artist, album: title, format: guide.request.format)
                ?? entry(artist: guide.request.artist, album: guide.request.album, format: guide.request.format) else { return }
        w.take(guide)
        put([w])
    }

    /// Prices the albums again one at a time: those given, else every album not priced in the last few hours.
    func refresh(ids: Set<String>? = nil) {
        guard let guides = guides() else { return }
        let targets = ids.map { ids in shown.filter { ids.contains($0.id) } } ?? shown.filter { $0.needsCheck(age: 6 * 3600) }
        let queued = targets.filter { !checking.contains($0.id) }
        guard !queued.isEmpty else { return }
        checking.formUnion(queued.map(\.id))
        let isAll = ids == nil
        if isAll { progress = (0, queued.count) }
        let previous = refreshTask
        refreshTask = Task {
            await previous?.value
            for (i, album) in queued.enumerated() {
                if Task.isCancelled { break }
                let guide = await guides.fullGuide(for: album.request)
                if Task.isCancelled { break }
                if var current = self.album(id: album.id) {
                    current.take(guide)
                    put([current])
                }
                checking.remove(album.id)
                if isAll { progress = (i + 1, queued.count) }
            }
            checking.subtract(queued.map(\.id))
            if isAll { progress = nil }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        checking = []
        progress = nil
    }

    // MARK: Values

    /// Prices a copy with the whole guide when it isn't priced or was priced over a day ago (or `force`).
    func price(_ item: CollectionItem, force: Bool = false) {
        guard CollectionValue.canValue(item), !pricing.contains(item.id), let guides = guides() else { return }
        if !force, let v = values[item.id], Date().timeIntervalSince(v.at) < 24 * 3600 { return }
        pricing.insert(item.id)
        let request = CollectionValue.request(for: item)
        Task {
            let guide = await guides.fullGuide(for: request)
            pricing.remove(item.id)
            itemGuides[item.id] = guide
            localValues[item.id] = CollectionValue(itemID: item.id, guide: guide)
            saveValues()
            rebuild()
        }
    }

    private func saveValues() {
        let list = Array(localValues.values), url = valuesURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
    }
}
