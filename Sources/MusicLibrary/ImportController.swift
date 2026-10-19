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
    /// The files added together with this one, which share what they're the digital copy of (`ImportGroup`).
    let groupID: UUID
    /// What you paid for the song is on a collection item (the copy it was linked to, or its album download), so it
    /// has no purchase of its own. Set only once the song is imported and that item saved.
    var pricedOnItem = false

    init(url: URL, groupID: UUID) {
        self.url = url
        self.groupID = groupID
    }

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
        let preset = model.importLinkItemID.flatMap { model.item(id: $0) }.flatMap { $0.isEditable ? $0 : nil }
        model.importLinkItemID = nil
        let files = ImportService.discover(urls)
        let existing = Set(entries.filter(\.isPending).map(\.url))
        guard files.contains(where: { !existing.contains($0) }) else { return }
        // Files join the batch still waiting, unless either is for one item: those files are a batch of their own, so
        // a preset never changes what other files are linked to, and other files never join an item's.
        let joining = preset == nil ? latestGroup.flatMap { $0.preset || !hasPending($0) ? nil : $0 } : nil
        let group = joining ?? ImportGroup()
        if joining == nil {
            groups[group.id] = group
            if let preset {
                group.preset = true
                choose(preset, in: group)
            }
        }
        latestGroupID = group.id
        var batch: [ImportEntry] = []
        for url in files where !existing.contains(url) {
            let entry = ImportEntry(url: url, groupID: group.id)
            entries.append(entry)
            batch.append(entry)
            if selection == nil || preset != nil && batch.count == 1 { selection = entry.id }
        }
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
                entry.note = "Already in your digital collection as \(item.duplicateOf?.path ?? "")"
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
            linkImported(track, entry: entry)
            model.reloadLibrary()
            savePurchase(entry)
        } catch ImportError.duplicate {
            entry.status = .duplicate
        } catch {
            entry.status = .failed(error.localizedDescription)
        }
    }

    /// The songs a price for the whole batch is split across: all of the current batch's songs but failures,
    /// including the ones already imported and duplicates of songs in the library (their price goes to the library's
    /// copy).
    var batch: [ImportEntry] { batch(of: currentGroup) }

    private func batch(of group: ImportGroup?) -> [ImportEntry] {
        guard let group else { return [] }
        return entries.filter { entry in
            guard entry.groupID == group.id else { return false }
            switch entry.status {
            case .failed: return false
            case .duplicate: return entry.trackID != nil
            default: return true
            }
        }
    }

    /// What the batch cost: its songs' prices added up (nil when none has one).
    var batchTotal: Decimal? { total(of: batch) }

    private func total(of songs: [ImportEntry]) -> Decimal? {
        let prices = songs.compactMap(\.price)
        return prices.isEmpty ? nil : prices.reduce(0, +)
    }

    /// The day the batch's songs were bought, when they all share one.
    var batchDay: PurchaseDay? { day(of: batch) }

    private func day(of songs: [ImportEntry]) -> PurchaseDay? {
        let days = Set(songs.map(\.purchasedOn))
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

    /// A song's own purchase, unless what you paid is on the collection item it was imported for (the record or CD
    /// it's the digital copy of, or the album download of songs bought as a whole album).
    private func savePurchase(_ entry: ImportEntry) {
        guard let id = entry.trackID, !(entry.pricedOnItem && entry.status == .done) else { return }
        let purchase = entry.price == nil && entry.purchasedOn == nil ? nil : TrackPurchase(purchasedOn: entry.purchasedOn, price: entry.price)
        model.setTrackPurchase(purchase, for: id)
    }

    func importAllReady() async {
        for entry in entries where entry.status == .ready {
            await importEntry(entry)
        }
    }

    // MARK: Collection

    /// Each batch of files (added together, or joined while it was waiting) is the digital copy of at most one item,
    /// and is bought as songs or as a whole album. The bar below the list shows the selected song's batch.
    @ObservationIgnored private var groups: [UUID: ImportGroup] = [:]
    private var latestGroupID: UUID?

    private var latestGroup: ImportGroup? { latestGroupID.flatMap { groups[$0] } }

    /// The batch the Import page's bars show and change: the selected song's, else the one added last.
    var currentGroup: ImportGroup? {
        if let entry = selectedEntry, let group = groups[entry.groupID] { return group }
        return latestGroup.flatMap { group in entries.contains { $0.groupID == group.id } ? group : nil }
    }

    /// More than one batch is in the list, so the bars say which one they're for.
    var hasSeveralBatches: Bool { Set(entries.map(\.groupID)).count > 1 }

    private func hasPending(_ group: ImportGroup) -> Bool { entries.contains { $0.groupID == group.id && $0.isPending } }

    /// How the files relate to the item: digitized from it (a rip or needle-drop), or a download that came with it.
    var linkSource: DigitalSource {
        get { currentGroup?.linkSource ?? .rip }
        set { currentGroup?.linkSource = newValue }
    }

    /// Songs bought as a whole album: one album download in the collection with the batch's day and total, instead
    /// of a purchase per song. Switching to it starts from the songs' total and day.
    var boughtAsAlbum: Bool {
        get { currentGroup?.boughtAsAlbum ?? false }
        set {
            guard let group = currentGroup, group.boughtAsAlbum != newValue else { return }
            group.boughtAsAlbum = newValue
            if newValue, group.albumItemID == nil {
                if group.albumDay == nil { group.albumDay = batchDay ?? PurchaseDay(Date()) }
                if group.albumPrice == nil { group.albumPrice = batchTotal }
            }
        }
    }

    /// The item the batch is linked to: the one picked (or preset), else the one its first imported song was linked
    /// to, else the suggestion (unless the songs were bought as a whole album).
    var effectiveLinkItem: CollectionItem? { linkItem(of: currentGroup) }

    private func linkItem(of group: ImportGroup?) -> CollectionItem? {
        guard let group else { return nil }
        if group.linkChosen { return group.linkItemID.flatMap { model.item(id: $0) } }
        if let id = group.linkedItemID { return model.item(id: id) }
        return group.boughtAsAlbum ? nil : suggestedLinkItem(for: group)
    }

    /// Whole album can still be picked: no item was picked for the batch, and none got its songs.
    var canBuyAsAlbum: Bool {
        guard let group = currentGroup else { return false }
        return !(group.linkChosen && group.linkItemID != nil) && group.linkedItemID == nil
    }

    /// What you paid is on a collection item, not the songs: one picked for the batch, or its album download. A
    /// suggestion the user didn't pick never takes the songs' prices.
    var songsPricedElsewhere: Bool { pricedElsewhere(currentGroup) }

    private func pricedElsewhere(_ group: ImportGroup?) -> Bool {
        guard let group else { return false }
        return group.linkChosen && linkItem(of: group) != nil || group.boughtAsAlbum && linkItem(of: group) == nil
    }

    /// The item picked for the selected batch (nil: None).
    func chooseLink(_ item: CollectionItem?) {
        guard let group = currentGroup else { return }
        choose(item, in: group)
    }

    private func choose(_ item: CollectionItem?, in group: ImportGroup) {
        group.linkChosen = true
        group.linkItemID = item?.id
        if let item { group.linkSource = item.medium.isPhysical ? .rip : .download }
    }

    /// Physical items with no digital copy yet: the ones that are the selected batch's release, release group or
    /// album first, then the rest (`matching` tells which).
    var linkCandidates: (matching: [CollectionItem], others: [CollectionItem]) { candidates(for: currentGroup) }

    private func candidates(for group: ImportGroup?) -> (matching: [CollectionItem], others: [CollectionItem]) {
        let waiting = model.collection.items.filter { item in
            item.isEditable && item.medium.isPhysical && model.collection.digitalState(item).needsDigitizing
        }
        var releases = Set<String>(), groupIDs = Set<String>(), keys = Set<String>()
        for entry in entries where entry.groupID == group?.id && entry.status != .duplicate {
            if let id = entry.appliedRelease?.id ?? entry.metadata.mbReleaseId { releases.insert(id) }
            if let id = entry.appliedRelease?.releaseGroupId ?? MBID.validated(entry.metadata.extended.mbReleaseGroupId) { groupIDs.insert(id) }
            let artist = entry.metadata.albumArtist.isEmpty ? entry.metadata.artist : entry.metadata.albumArtist
            if !entry.metadata.album.isEmpty { keys.insert(SearchIndex.albumKey(album: entry.metadata.album, artist: artist)) }
        }
        func rank(_ item: CollectionItem) -> Int? {
            if let id = item.releaseID, releases.contains(id) { return 0 }
            if let id = item.releaseGroupID, groupIDs.contains(id) { return 1 }
            if keys.contains(item.albumKey) { return 2 }
            return nil
        }
        let ranked = waiting.compactMap { item in rank(item).map { (item, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let matched = Set(ranked.map(\.id))
        return (ranked, waiting.filter { !matched.contains($0.id) })
    }

    /// The item a batch would be linked to without a choice: the best match waiting to be digitized.
    private func suggestedLinkItem(for group: ImportGroup) -> CollectionItem? {
        guard hasPending(group) else { return nil }
        return candidates(for: group).matching.first
    }

    /// What you paid for the whole album and when (Bought as: Whole album): on its album download once it's saved.
    func setAlbumPurchase(price: Decimal?, day: PurchaseDay?) {
        guard let group = currentGroup else { return }
        group.albumPrice = price
        group.albumDay = day
        guard let id = group.albumItemID else { return }
        model.changeItem(id: id) {
            $0.price = price
            $0.purchasedOn = day
        }
    }

    /// The whole album's price and day as saved on its download, else as entered.
    var albumPurchase: (price: Decimal?, day: PurchaseDay?) {
        guard let group = currentGroup else { return (nil, nil) }
        if let id = group.albumItemID, let item = model.item(id: id) { return (item.price, item.purchasedOn) }
        return (group.albumPrice, group.albumDay)
    }

    /// After a song is imported: the item its batch is the digital copy of moves to the song's album and records
    /// how (only an item without music of its own, and only for a song of that item's album); songs bought as a
    /// whole album get their album download.
    private func linkImported(_ track: Track, entry: ImportEntry) {
        guard let group = groups[entry.groupID] else { return }
        let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
        if let item = linkItem(of: group) {
            if let linked = group.linkedKey {
                // The batch's item is linked already: only songs of that album are its digital copy.
                entry.pricedOnItem = group.linkChosen && linked == key && group.linkPriced
                return
            }
            guard item.isEditable, item.albumKey == key || model.collection.libraryTracks(item).isEmpty,
                  belongs(track, key: key, to: item) || group.linkChosen && isSingleAlbum(group, key: key)
            else {
                entry.note = "Not linked to \(item.sticker?.text ?? "your \(item.medium.name.lowercased())"): this song is from another album"
                return
            }
            let source = item.medium.isPhysical ? group.linkSource : .download
            // What the album's songs cost goes to the item picked for them, where it has none (nothing typed is
            // dropped). Songs of another album in the batch keep their own purchases.
            let songs = batch(of: group).filter { albumKey(of: $0) == key }
            let price = group.linkChosen ? total(of: songs) : nil
            let day = group.linkChosen ? day(of: songs) : nil
            // Where the item already has a price, the songs keep their own purchases (`takeSongsPurchase`).
            var priced = false
            guard model.changeItem(id: item.id, {
                $0.albumKey = key
                $0.digitalSource = source
                priced = $0.takeSongsPurchase(price: price, day: day)
            }) != nil else { return }
            // The first linked song decides: the item stays even once it's digitized and no longer suggested.
            group.linkedItemID = item.id
            group.linkedKey = key
            group.linkPriced = priced
            entry.pricedOnItem = group.linkChosen && priced
        } else if group.boughtAsAlbum {
            entry.pricedOnItem = saveAlbumDownload(key: key, track: track, group: group)
        }
    }

    /// Whether a song is of an item's album: its key, release or release group, or the item's own title and artist.
    private func belongs(_ track: Track, key: String, to item: CollectionItem) -> Bool {
        if item.albumKey == key || SearchIndex.albumKey(album: item.album, artist: item.artist) == key { return true }
        if let id = item.releaseID, id == MBID.validated(track.metadata.mbReleaseId) { return true }
        if let id = item.releaseGroupID, id == MBID.validated(track.metadata.extended.mbReleaseGroupId) { return true }
        return false
    }

    /// Every song of the batch (but failures and duplicates) is of one album, the imported song's: an item picked
    /// for the batch is then its digital copy, whatever the files' tags say.
    private func isSingleAlbum(_ group: ImportGroup, key: String) -> Bool {
        entries.allSatisfy { entry in
            guard entry.groupID == group.id, entry.status != .duplicate else { return true }
            if case .failed = entry.status { return true }
            return albumKey(of: entry) == key
        }
    }

    /// The album a song is (or will be) imported as.
    private func albumKey(of entry: ImportEntry) -> String {
        let artist = entry.metadata.albumArtist.isEmpty ? entry.metadata.artist : entry.metadata.albumArtist
        return SearchIndex.albumKey(album: entry.metadata.album, artist: artist)
    }

    /// The album download for songs bought as a whole album: a download of the album already in the collection
    /// takes the day and price where it has none; else a new one is added. Returns whether the song's price is on it.
    private func saveAlbumDownload(key: String, track: Track, group: ImportGroup) -> Bool {
        if let id = group.albumItemID, let item = model.item(id: id) { return item.albumKey == key }
        if let existing = model.collection.copies(albumKey: key).first(where: { $0.origin == .stored && $0.medium == .download }) {
            let price = group.albumPrice, day = group.albumDay
            guard model.changeItem(id: existing.id, {
                if $0.price == nil { $0.price = price }
                if $0.purchasedOn == nil { $0.purchasedOn = day }
                if $0.digitalSource == nil { $0.digitalSource = .download }
            }) != nil else { return false }
            group.albumItemID = existing.id
            return true
        }
        var item = CollectionItem(medium: .download, album: track.album, artist: track.effectiveAlbumArtist, albumKey: key)
        item.price = group.albumPrice
        item.purchasedOn = group.albumDay
        item.digitalSource = .download
        item.releaseID = MBID.validated(track.metadata.mbReleaseId)
        item.releaseGroupID = MBID.validated(track.metadata.extended.mbReleaseGroupId)
        item.year = track.year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        if (track.metadata.discTotal ?? 1) <= 1, let total = track.metadata.trackTotal, (1...999).contains(total) { item.trackCount = total }
        guard let saved = model.saveItem(item) else { return false }
        group.albumItemID = saved.id
        return true
    }

    /// Forgets batches with no songs left in the list.
    private func dropEmptyGroups() {
        let used = Set(entries.map(\.groupID))
        groups = groups.filter { used.contains($0.key) }
    }

    func remove(_ entry: ImportEntry) {
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id { selection = entries.first?.id }
        dropEmptyGroups()
    }

    func clearFinished() {
        entries.removeAll { $0.status == .done || $0.status == .duplicate }
        if selectedEntry == nil { selection = entries.first?.id }
        dropEmptyGroups()
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

/// A batch of files on the Import page: what they're the digital copy of, and how they were bought.
@MainActor @Observable
final class ImportGroup {
    let id = UUID()
    /// Added for one item (Import a Transfer…, Import Files… on its page, or a CD ripped to the queue): no other
    /// files join it.
    var preset = false
    /// The item picked (or preset); with `linkChosen` false, the suggestion is used until a song is linked.
    var linkItemID: String?
    /// The user (or a preset) decided the link, None included.
    var linkChosen = false
    var linkSource: DigitalSource = .rip
    /// The item its first song was linked to, and that song's album: later songs of that album are its copy too.
    var linkedItemID: String?
    var linkedKey: String?
    /// What the songs cost went onto that item (it had no price or date of its own to keep): false, each song keeps
    /// its own purchase.
    var linkPriced = false
    var boughtAsAlbum = false
    var albumPrice: Decimal?
    var albumDay: PurchaseDay?
    /// The album download made (or found) for a whole album, once its first song was imported.
    var albumItemID: String?
}
