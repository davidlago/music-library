import AppKit
import Foundation
import MusicLibraryCore

@MainActor @Observable
final class ImportEntry: Identifiable {
    enum Status: Equatable {
        case reading, matching, needsReview, ready, importing, done, duplicate, failed(String)

        var label: String {
            switch self {
            case .reading: return "Reading"
            case .matching: return "Matching"
            case .needsReview: return "Needs review"
            case .ready: return "Ready"
            case .importing: return "Importing"
            case .done: return "Done"
            case .duplicate: return "Duplicate"
            case .failed(let e): return "Failed: \(e)"
            }
        }
    }

    let id = UUID()
    let url: URL
    var status: Status = .reading
    var item: ImportItem?
    var metadata = TrackMetadata()
    var cover: Data?
    var candidates: [MatchCandidate] = []
    var selectedCandidateID: String?
    var searchTitle = ""
    var searchArtist = ""
    var searchAlbum = ""
    var appliedRelease: ReleaseInfo?
    var note: String?
    /// What you paid for the song and when, if you bought it (saved as a `TrackPurchase` when it's imported, and on every
    /// change after that). Change them through `ImportController.setPurchase`.
    var price: Decimal?
    var purchasedOn: PurchaseDay?
    /// The imported track, or the library's copy of a duplicate.
    var trackID: Int64?

    init(url: URL) { self.url = url }

    var displayTitle: String { metadata.title.isEmpty ? url.deletingPathExtension().lastPathComponent : metadata.title }
    var isPending: Bool {
        switch status {
        case .done, .duplicate, .failed: return false
        default: return true
        }
    }
    var canImport: Bool {
        switch status {
        case .needsReview, .ready: return item != nil
        default: return false
        }
    }
    var previewCover: Data? { cover ?? item?.embeddedCover }

    func resetToSourceDetails() {
        guard let tags = item?.tags else { return }
        metadata.composer = tags.composer
        metadata.genre = tags.genre
        metadata.extended = tags.extended
    }
}

@MainActor @Observable
final class ImportController {
    var entries: [ImportEntry] = []
    var selection: UUID?
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var thumbnails: [String: Data] = [:]
    @ObservationIgnored private var missingThumbnails: Set<String> = []

    init(model: AppModel) { self.model = model }

    var pendingCount: Int { entries.filter(\.isPending).count }
    var readyCount: Int { entries.filter { $0.status == .ready }.count }
    var selectedEntry: ImportEntry? { entries.first { $0.id == selection } }

    func enqueue(_ urls: [URL]) {
        // An item's Import Files… / Import a Transfer…, or a CD ripped to the queue: these files are its digital copy.
        let preset = model.importLinkItemID
        model.importLinkItemID = nil
        let files = ImportService.discover(urls)
        let existing = Set(entries.filter(\.isPending).map(\.url))
        // A new batch starts with nothing linked and its songs bought one by one.
        if !entries.contains(where: \.isPending) { resetCollection() }
        var batch: [ImportEntry] = []
        for url in files where !existing.contains(url) {
            let entry = ImportEntry(url: url)
            entries.append(entry)
            batch.append(entry)
            if selection == nil { selection = entry.id }
        }
        guard !batch.isEmpty else { return }
        if let preset, let item = model.item(id: preset), item.isEditable { chooseLink(item) }
        Task {
            for entry in batch { await prepare(entry) }
            for entry in batch where entry.status == .reading { await matchStep(entry) }
        }
    }

    private func matchStep(_ entry: ImportEntry) async {
        if model.autoMatch, let item = entry.item {
            let siblings = entries.compactMap { other -> (tags: TrackMetadata, release: ReleaseInfo)? in
                guard other.id != entry.id, let release = other.appliedRelease, let tags = other.item?.tags else { return nil }
                return (tags, release)
            }
            if let (release, track) = SiblingMatcher.match(tags: item.tags, entryId: entry.id.uuidString, siblings: siblings) {
                release.apply(track, to: &entry.metadata)
                entry.appliedRelease = release
                if entry.cover == nil {
                    entry.cover = entries.first { $0.appliedRelease?.id == release.id && $0.cover != nil }?.cover
                }
                entry.note = "Matched to \(release.album) from another queued track"
                entry.status = .ready
                return
            }
        }
        await search(entry)
    }

    private func prepare(_ entry: ImportEntry) async {
        guard let service = model.importService else {
            entry.status = .failed("No library open"); return
        }
        do {
            let item = try await service.prepare(entry.url)
            entry.item = item
            entry.metadata = item.tags
            if let dup = item.duplicateOf {
                // Its price goes to the library's copy, which may have one already.
                entry.trackID = dup.id
                entry.price = model.trackPurchases[dup.id]?.price
                entry.purchasedOn = model.trackPurchases[dup.id]?.purchasedOn
                entry.status = .duplicate
                entry.note = "Already in library as \(item.duplicateOf?.path ?? "")"
                return
            }
            if item.tags.title.isEmpty {
                let parsed = FilenameParser.parse(stem: entry.url.deletingPathExtension().lastPathComponent)
                entry.metadata.title = parsed.title
                if entry.metadata.trackNo == nil { entry.metadata.trackNo = parsed.trackNo }
                if entry.metadata.artist.isEmpty, let a = parsed.artist { entry.metadata.artist = a }
            }
            entry.searchTitle = entry.metadata.title
            entry.searchArtist = entry.metadata.artist
            entry.searchAlbum = entry.metadata.album
        } catch {
            entry.status = .failed(error.localizedDescription)
        }
    }

    func search(_ entry: ImportEntry) async {
        let previous = entry.status
        entry.status = .matching
        entry.note = nil
        do {
            let found = try await model.musicBrainz.searchRecordings(
                title: entry.searchTitle, artist: entry.searchArtist, album: entry.searchAlbum)
            entry.candidates = found
            if found.isEmpty { entry.note = "No MusicBrainz matches" }
            if previous != .ready, model.autoMatch, let top = found.first,
               AutoMatch.isConfident(top, trackDuration: entry.item?.duration ?? 0, albumHint: entry.searchAlbum) {
                await choose(entry, candidate: top)
                return
            }
            entry.status = previous == .ready ? .ready : .needsReview
        } catch {
            entry.note = "Search failed: \(error.localizedDescription)"
            entry.status = previous == .ready ? .ready : .needsReview
        }
    }

    func fingerprint(_ entry: ImportEntry) async {
        guard let client = model.acoustID else { return }
        entry.status = .matching
        entry.note = nil
        do {
            entry.candidates = try await client.lookup(file: entry.url)
            if entry.candidates.isEmpty { entry.note = "No fingerprint matches" }
        } catch {
            entry.note = "Fingerprint failed: \(error.localizedDescription)"
        }
        entry.status = .needsReview
    }

    func choose(_ entry: ImportEntry, candidate: MatchCandidate) async {
        entry.selectedCandidateID = candidate.id
        entry.note = nil
        entry.resetToSourceDetails()
        var meta = entry.metadata
        var release: ReleaseInfo?
        if !candidate.releaseId.isEmpty {
            do {
                release = try await model.musicBrainz.fetchRelease(id: candidate.releaseId)
            } catch {
                entry.note = "Could not fetch release: \(error.localizedDescription)"
            }
        }
        if let release, let track = release.track(forRecording: candidate.recordingId) {
            release.apply(track, to: &meta)
        } else {
            meta.title = candidate.title
            meta.artist = candidate.artist
            meta.album = candidate.album
            meta.year = candidate.year ?? meta.year
            meta.mbRecordingId = candidate.recordingId
            meta.mbReleaseId = candidate.releaseId.isEmpty ? nil : candidate.releaseId
            if let release {
                meta.albumArtist = release.albumArtist
                meta.discTotal = release.discTotal
            }
        }
        entry.metadata = meta
        entry.appliedRelease = release
        if let release {
            if let data = try? await model.coverArt.fetchFront(releaseId: release.id, releaseGroupId: release.releaseGroupId) {
                entry.cover = data
            }
        } else if let data = try? await model.coverArt.fetchFront(releaseId: candidate.releaseId, releaseGroupId: candidate.releaseGroupId) {
            entry.cover = data
        }
        entry.status = .ready
    }

    @discardableResult
    func applyRelease(of entry: ImportEntry) -> Int {
        guard let release = entry.appliedRelease else { return 0 }
        let others = entries.filter { $0.id != entry.id && $0.item != nil && ($0.status == .needsReview || $0.status == .ready) }
        let inputs = others.map {
            ReleaseMatcher.Input(id: $0.id.uuidString, title: $0.metadata.title, trackNo: $0.metadata.trackNo, discNo: $0.metadata.discNo)
        }
        let matches = ReleaseMatcher.match(inputs, to: release)
        var count = 0
        for other in others {
            guard let track = matches[other.id.uuidString] else { continue }
            other.resetToSourceDetails()
            release.apply(track, to: &other.metadata)
            if other.cover == nil { other.cover = entry.cover }
            other.appliedRelease = release
            other.status = .ready
            count += 1
        }
        entry.note = "Applied release to \(count) other item\(count == 1 ? "" : "s")"
        return count
    }

    func importEntry(_ entry: ImportEntry) async {
        guard entry.canImport, let item = entry.item, let service = model.importService else { return }
        entry.status = .importing
        do {
            let track = try await service.commit(item, metadata: entry.metadata, cover: entry.cover)
            entry.trackID = track.id
            entry.status = .done
            linkImported(track)
            model.reloadLibrary()
            savePurchase(entry)
        } catch ImportError.duplicate {
            entry.status = .duplicate
        } catch {
            entry.status = .failed(error.localizedDescription)
        }
    }

    /// The songs a price for the whole batch is split across: all of them but failures, including the ones already
    /// imported and duplicates of songs in the library (their price goes to the library's copy).
    var batch: [ImportEntry] {
        entries.filter { entry in
            switch entry.status {
            case .failed: return false
            case .duplicate: return entry.trackID != nil
            default: return true
            }
        }
    }

    /// What the batch cost: its songs' prices added up (nil when none has one).
    var batchTotal: Decimal? {
        let prices = batch.compactMap(\.price)
        return prices.isEmpty ? nil : prices.reduce(0, +)
    }

    /// The day the batch's songs were bought, when they all share one.
    var batchDay: PurchaseDay? {
        let days = Set(batch.map(\.purchasedOn))
        return days.count == 1 ? days.first ?? nil : nil
    }

    /// For songs bought together (a whole album, say): `total` split evenly across the batch (nil clears their prices).
    /// Songs without a purchase day get `day`.
    func setBatchTotal(_ total: Decimal?, day: PurchaseDay?) {
        let songs = batch
        let prices: [Decimal?] = total.map { TrackPurchase.split($0, into: songs.count) } ?? Array(repeating: nil, count: songs.count)
        for (entry, price) in zip(songs, prices) {
            setPurchase(entry, price: price, day: entry.purchasedOn ?? (price == nil ? nil : day))
        }
    }

    /// Every song in the batch bought on `day`.
    func setBatchDay(_ day: PurchaseDay?) {
        for entry in batch { setPurchase(entry, price: entry.price, day: day) }
    }

    /// Sets what you paid for one song and when; an imported song's purchase is saved at once.
    func setPurchase(_ entry: ImportEntry, price: Decimal?, day: PurchaseDay?) {
        guard entry.price != price || entry.purchasedOn != day else { return }
        entry.price = price
        entry.purchasedOn = day
        savePurchase(entry)
    }

    /// A song's own purchase, unless what you paid is on a collection item: the record or CD the files are the
    /// digital copy of, or the album download for songs bought as a whole album.
    private func savePurchase(_ entry: ImportEntry) {
        guard let id = entry.trackID, !(songsPricedElsewhere && entry.status == .done) else { return }
        let purchase = entry.price == nil && entry.purchasedOn == nil ? nil : TrackPurchase(purchasedOn: entry.purchasedOn, price: entry.price)
        model.setTrackPurchase(purchase, for: id)
    }

    func importAllReady() async {
        for entry in entries where entry.status == .ready {
            await importEntry(entry)
        }
    }

    // MARK: Collection

    /// The item these files are the digital copy of, as picked (or preset by Import a Transfer…). Until one is
    /// picked, the best match among the items waiting to be digitized is used (`suggestedLinkItem`).
    private(set) var linkItemID: String?
    /// The user (or a preset) decided the link, None included.
    private(set) var linkChosen = false
    /// How the files relate to the item: digitized from it (a rip or needle-drop), or a download that came with it.
    var linkSource: DigitalSource = .rip
    /// Songs bought as a whole album: one album download in the collection with the batch's day and total, instead
    /// of a purchase per song.
    var boughtAsAlbum = false {
        didSet { if boughtAsAlbum != oldValue, boughtAsAlbum, albumDay == nil { albumDay = batchDay ?? PurchaseDay(Date()) } }
    }
    private(set) var albumPrice: Decimal?
    private(set) var albumDay: PurchaseDay?
    /// The album download made (or found) for a whole album, once its first song was imported.
    private(set) var albumItemID: String?
    /// Items already linked to the imported album (the first imported song decides which album that is).
    @ObservationIgnored private var linkedItems: Set<String> = []

    /// The item the batch is linked to: the one picked, else the suggestion.
    var effectiveLinkItem: CollectionItem? {
        if linkChosen { return linkItemID.flatMap { model.item(id: $0) } }
        return suggestedLinkItem
    }

    /// What you paid is on a collection item, not the songs.
    var songsPricedElsewhere: Bool { effectiveLinkItem != nil || boughtAsAlbum }

    func chooseLink(_ item: CollectionItem?) {
        linkChosen = true
        linkItemID = item?.id
        if let item { linkSource = item.medium.isPhysical ? .rip : .download }
    }

    /// Physical items with no digital copy yet: the ones that are this batch's release, release group or album
    /// first, then the rest (`matching` tells which).
    var linkCandidates: (matching: [CollectionItem], others: [CollectionItem]) {
        let waiting = model.collection.items.filter { item in
            item.isEditable && item.medium.isPhysical && model.collection.digitalState(item).needsDigitizing
        }
        var releases = Set<String>(), groups = Set<String>(), keys = Set<String>()
        for entry in entries where entry.status != .duplicate {
            if let id = entry.appliedRelease?.id ?? entry.metadata.mbReleaseId { releases.insert(id) }
            if let id = entry.appliedRelease?.releaseGroupId ?? MBID.validated(entry.metadata.extended.mbReleaseGroupId) { groups.insert(id) }
            let artist = entry.metadata.albumArtist.isEmpty ? entry.metadata.artist : entry.metadata.albumArtist
            if !entry.metadata.album.isEmpty { keys.insert(SearchIndex.albumKey(album: entry.metadata.album, artist: artist)) }
        }
        func rank(_ item: CollectionItem) -> Int? {
            if let id = item.releaseID, releases.contains(id) { return 0 }
            if let id = item.releaseGroupID, groups.contains(id) { return 1 }
            if keys.contains(item.albumKey) { return 2 }
            return nil
        }
        let ranked = waiting.compactMap { item in rank(item).map { (item, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let matched = Set(ranked.map(\.id))
        return (ranked, waiting.filter { !matched.contains($0.id) })
    }

    /// The item the batch would be linked to without a choice: the best match waiting to be digitized.
    var suggestedLinkItem: CollectionItem? {
        guard entries.contains(where: \.isPending) else { return nil }
        return linkCandidates.matching.first
    }

    /// What you paid for the whole album and when (Bought as: Whole album): on its album download once it's saved.
    func setAlbumPurchase(price: Decimal?, day: PurchaseDay?) {
        albumPrice = price
        albumDay = day
        guard let id = albumItemID else { return }
        model.changeItem(id: id) {
            $0.price = price
            $0.purchasedOn = day
        }
    }

    /// The whole album's price and day as saved on its download, else as entered.
    var albumPurchase: (price: Decimal?, day: PurchaseDay?) {
        if let id = albumItemID, let item = model.item(id: id) { return (item.price, item.purchasedOn) }
        return (albumPrice, albumDay)
    }

    /// After a song is imported: the item the batch is the digital copy of moves to the song's album and records
    /// how (only an item without music of its own); songs bought as a whole album get their album download.
    private func linkImported(_ track: Track) {
        let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
        if let item = effectiveLinkItem {
            // The first song decides: the choice stays even once the item is digitized and no longer suggested.
            linkChosen = true
            linkItemID = item.id
            if item.isEditable, linkedItems.insert(item.id).inserted,
               item.albumKey == key || model.collection.libraryTracks(item).isEmpty {
                let source = linkSource
                model.changeItem(id: item.id) {
                    $0.albumKey = key
                    $0.digitalSource = source
                }
            }
        } else if boughtAsAlbum {
            saveAlbumDownload(key: key, track: track)
        }
    }

    /// The album download for songs bought as a whole album: a download of the album already in the collection
    /// takes the day and price where it has none; else a new one is added.
    private func saveAlbumDownload(key: String, track: Track) {
        if let id = albumItemID, model.item(id: id) != nil { return }
        if let existing = model.collection.copies(albumKey: key).first(where: { $0.origin == .stored && $0.medium == .download }) {
            albumItemID = existing.id
            let price = albumPrice, day = albumDay
            model.changeItem(id: existing.id) {
                if $0.price == nil { $0.price = price }
                if $0.purchasedOn == nil { $0.purchasedOn = day }
                if $0.digitalSource == nil { $0.digitalSource = .download }
            }
            return
        }
        var item = CollectionItem(medium: .download, album: track.album, artist: track.effectiveAlbumArtist, albumKey: key)
        item.price = albumPrice
        item.purchasedOn = albumDay
        item.digitalSource = .download
        item.releaseID = MBID.validated(track.metadata.mbReleaseId)
        item.releaseGroupID = MBID.validated(track.metadata.extended.mbReleaseGroupId)
        item.year = track.year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        if (track.metadata.discTotal ?? 1) <= 1, let total = track.metadata.trackTotal, (1...999).contains(total) { item.trackCount = total }
        if let saved = model.saveItem(item) { albumItemID = saved.id }
    }

    private func resetCollection() {
        linkItemID = nil
        linkChosen = false
        linkSource = .rip
        boughtAsAlbum = false
        albumPrice = nil
        albumDay = nil
        albumItemID = nil
        linkedItems = []
    }

    func remove(_ entry: ImportEntry) {
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id { selection = entries.first?.id }
    }

    func clearFinished() {
        entries.removeAll { $0.status == .done || $0.status == .duplicate }
        if selectedEntry == nil { selection = entries.first?.id }
    }

    func setCover(_ entry: ImportEntry, from url: URL) {
        if let data = try? Data(contentsOf: url), NSImage(data: data) != nil { entry.cover = data }
    }

    func thumbnail(for c: MatchCandidate) async -> Data? {
        if let d = thumbnails[c.id] { return d }
        if missingThumbnails.contains(c.id) { return nil }
        if let d = await model.coverArt.thumbnail(for: c) {
            thumbnails[c.id] = d
            return d
        }
        missingThumbnails.insert(c.id)
        return nil
    }
}
