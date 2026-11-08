import Foundation
import MusicLibraryCore
import Observation

/// The Buy List on the Mac (`BuyList.swift`): the albums you're looking for, kept in the library database (so the
/// phone has them, and its changes are merged in at each sync), and their prices, refreshed with the Shop's price
/// guide (Discogs and eBay) one album at a time.
@MainActor @Observable
final class BuyListStore {
    /// Every album, removed ones too (they're kept so a phone's older change can't bring one back).
    private(set) var all: [WantedAlbum] = []
    /// The albums shown: deals first, then the latest added.
    private(set) var shown: [WantedAlbum] = []
    /// Albums being priced now, and how far a Refresh All is.
    private(set) var checking: Set<String> = []
    private(set) var progress: (done: Int, total: Int)?
    private(set) var lastError: String?

    @ObservationIgnored var database: () -> Database? = { nil }
    @ObservationIgnored var guides: () -> PriceGuides? = { nil }
    @ObservationIgnored var currency: () -> String = { Locale.current.currency?.identifier ?? "USD" }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Albums priced more recently than this aren't priced again by Refresh All.
    static let freshAge: TimeInterval = 6 * 3600

    /// The list changed (the catalog marks the CDs on it).
    @ObservationIgnored var onChanged: ([WantedAlbum]) -> Void = { _ in }

    func reload() {
        all = (try? database()?.wantedAlbums()) ?? []
        shown = BuyList.shown(all)
        onChanged(shown)
    }

    var totals: BuyList.Totals { BuyList.totals(shown) }

    func entry(artist: String, album: String, format: PriceGuideRequest.Format) -> WantedAlbum? {
        BuyList.entry(in: all, artist: artist, album: album, format: format)
    }

    func album(id: String) -> WantedAlbum? { all.first { $0.id == id && !$0.removed } }

    // MARK: Editing

    /// Adds an album priced in the Shop (or moves it up, with this guide as its latest price, when it's on already).
    @discardableResult
    func add(_ guide: PriceGuide) -> WantedAlbum {
        let fresh = WantedAlbum(guide: guide, currency: currency())
        if var existing = entry(artist: fresh.artist, album: fresh.album, format: fresh.format) {
            existing.take(guide)
            save([existing])
            return existing
        }
        save([fresh])
        return fresh
    }

    /// Adds an album by name (typed, or a Local Library CD), priced right away.
    @discardableResult
    func add(artist: String, album: String, format: PriceGuideRequest.Format, barcode: String = "", maxPrice: Decimal? = nil,
             notes: String = "") -> WantedAlbum {
        if let existing = entry(artist: artist, album: album, format: format) { return existing }
        let w = WantedAlbum(artist: artist, album: album, format: format, barcode: barcode, maxPrice: maxPrice,
                            currency: currency(), notes: notes)
        save([w])
        refresh(ids: [w.id])
        return w
    }

    /// Saves the user's edit (the album's fields; its checks are kept).
    func update(_ album: WantedAlbum) {
        var edited = album
        edited.updatedAt = Date()
        save([edited])
    }

    /// Replaces an album with another edition (or album): a new entry with the same notes and price limit, priced
    /// afresh, so the old one's prices don't mix in.
    func replace(_ edited: WantedAlbum) {
        var fresh = WantedAlbum(artist: edited.artist, album: edited.album, format: edited.format, barcode: edited.barcode,
                                catalogNumber: edited.catalogNumber, maxPrice: edited.maxPrice, currency: edited.currency,
                                notes: edited.notes, addedAt: Date())
        fresh.addedAt = edited.addedAt
        remove([edited.id])
        save([fresh])
        refresh(ids: [fresh.id])
    }

    func remove(_ ids: Set<String>) {
        let now = Date()
        save(all.filter { ids.contains($0.id) && !$0.removed }.map { var w = $0; w.removed = true; w.updatedAt = now; return w })
    }

    private func save(_ albums: [WantedAlbum]) {
        guard let db = database(), !albums.isEmpty else { return }
        do {
            try db.saveWanted(albums)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    /// A price guide read elsewhere (the Shop) for an album on the list: its latest price.
    func noteGuide(_ guide: PriceGuide) {
        guard guide.hasPrices else { return }
        let title = guide.title.isEmpty ? guide.request.album : guide.title
        let artist = guide.artist.isEmpty ? guide.request.artist : guide.artist
        guard var w = entry(artist: artist, album: title, format: guide.request.format) ?? entry(artist: guide.request.artist, album: guide.request.album, format: guide.request.format) else { return }
        w.take(guide)
        save([w])
    }

    // MARK: Prices

    /// Prices the albums again, one at a time: those given, else every album not priced in the last few hours.
    func refresh(ids: Set<String>? = nil) {
        guard let guides = guides() else { return }
        let targets = ids.map { ids in shown.filter { ids.contains($0.id) } }
            ?? shown.filter { $0.needsCheck(age: Self.freshAge) }
        let queued = targets.filter { !checking.contains($0.id) }
        guard !queued.isEmpty else { return }
        checking.formUnion(queued.map(\.id))
        let previous = refreshTask
        let isAll = ids == nil
        if isAll { progress = (0, queued.count) }
        refreshTask = Task {
            await previous?.value
            for (i, album) in queued.enumerated() {
                if Task.isCancelled { break }
                let guide = await guides.fullGuide(for: album.request, readsForSale: true)
                if Task.isCancelled { break }
                // The album as it is now (it may have been edited or removed meanwhile).
                if var current = self.album(id: album.id) {
                    current.take(guide)
                    save([current])
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

    var isRefreshing: Bool { !checking.isEmpty }
}
