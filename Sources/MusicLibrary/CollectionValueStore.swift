import Foundation
import MusicLibraryCore
import Observation

/// What the CDs and records are worth (`CollectionValues.swift`): each copy's latest value, kept in the library
/// database (so the phone shows them too). An item's page prices its copy with the whole guide (Discogs and eBay);
/// Update Values prices every copy not priced in the last month with Discogs alone, one at a time (its edition only
/// when the item, or Sync to Discogs, knows its release: two requests), in the background, with a Stop.
@MainActor @Observable
final class CollectionValueStore {
    private(set) var values: [String: CollectionValue] = [:]
    /// The Owned pane's figures (rebuilt with the values and the collection).
    private(set) var stats = CollectionValueStats()
    /// The full guide read on an item's page this session, by item id (not saved: the value is).
    private(set) var fullGuides: [String: PriceGuide] = [:]
    private(set) var pricing: Set<String> = []
    private(set) var progress: (done: Int, total: Int)?

    @ObservationIgnored var database: () -> Database? = { nil }
    @ObservationIgnored var priceGuides: () -> PriceGuides? = { nil }
    @ObservationIgnored var collection: () -> MusicCollection = { .empty }
    @ObservationIgnored private var bulk: Task<Void, Never>?

    /// An item's page prices it again when its value is older than this.
    static let pageAge: TimeInterval = 24 * 3600

    func reload() {
        values = (try? database()?.collectionValues()) ?? [:]
        recompute()
    }

    func recompute() {
        stats = CollectionValueStats.make(collection: collection(), values: values)
    }

    /// The release Sync to Discogs matched each item to.
    private func discogsMatches() -> [String: Int] {
        ((try? database()?.discogsSyncRows()) ?? [:]).compactMapValues { $0.releaseID ?? $0.instanceReleaseID }
    }

    /// Prices one copy with the whole guide, when it isn't priced or was priced more than a day ago (or `force`).
    func price(_ item: CollectionItem, force: Bool = false) {
        guard CollectionValue.canValue(item), !pricing.contains(item.id), let guides = priceGuides() else { return }
        if !force, let v = values[item.id], v.matches(item), Date().timeIntervalSince(v.at) < Self.pageAge { return }
        // A new grade: the guide read this session already has Discogs' price for it.
        if !force, let guide = fullGuides[item.id], guide.request == CollectionValue.request(for: item, discogsMatch: discogsMatches()[item.id]) {
            save([CollectionValue(itemID: item.id, guide: guide, grade: item.mediaGrade)])
            return
        }
        pricing.insert(item.id)
        let request = CollectionValue.request(for: item, discogsMatch: discogsMatches()[item.id])
        Task {
            let guide = await guides.fullGuide(for: request, readsForSale: true)
            pricing.remove(item.id)
            fullGuides[item.id] = guide
            save([CollectionValue(itemID: item.id, guide: guide, grade: item.mediaGrade)])
        }
    }

    func guide(for item: CollectionItem) -> PriceGuide? { fullGuides[item.id] }

    /// Prices every CD and record without a value from the last month, Discogs only.
    func updateAll() {
        guard bulk == nil, let guides = priceGuides() else { return }
        let now = Date()
        let items = collection().items.filter(CollectionValue.canValue).filter { item in
            values[item.id].map { now.timeIntervalSince($0.at) >= CollectionValue.staleAge || !$0.matches(item) } ?? true
        }
        guard !items.isEmpty else { return }
        let matches = discogsMatches()
        progress = (0, items.count)
        bulk = Task {
            var batch: [CollectionValue] = []
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                pricing.insert(item.id)
                let guide = await guides.editionGuide(for: CollectionValue.request(for: item, discogsMatch: matches[item.id]))
                pricing.remove(item.id)
                if Task.isCancelled { break }
                // Discogs busy: stop rather than record nothing for the rest.
                if !guide.hasPrices, guide.notes.contains(where: { $0.contains("busy") }) {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                batch.append(CollectionValue(itemID: item.id, guide: guide, grade: item.mediaGrade))
                progress = (i + 1, items.count)
                if batch.count >= 10 { save(batch); batch = [] }
            }
            save(batch)
            progress = nil
            bulk = nil
        }
    }

    func stop() {
        bulk?.cancel()
        bulk = nil
        progress = nil
        pricing = []
    }

    var isUpdating: Bool { bulk != nil }

    private func save(_ new: [CollectionValue]) {
        guard !new.isEmpty else { return }
        for v in new { values[v.itemID] = v }
        try? database()?.saveCollectionValues(new)
        recompute()
    }
}
