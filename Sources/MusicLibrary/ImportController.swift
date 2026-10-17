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
        let files = ImportService.discover(urls)
        let existing = Set(entries.filter(\.isPending).map(\.url))
        var batch: [ImportEntry] = []
        for url in files where !existing.contains(url) {
            let entry = ImportEntry(url: url)
            entries.append(entry)
            batch.append(entry)
            if selection == nil { selection = entry.id }
        }
        guard !batch.isEmpty else { return }
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

    private func savePurchase(_ entry: ImportEntry) {
        guard let id = entry.trackID else { return }
        let purchase = entry.price == nil && entry.purchasedOn == nil ? nil : TrackPurchase(purchasedOn: entry.purchasedOn, price: entry.price)
        model.setTrackPurchase(purchase, for: id)
    }

    func importAllReady() async {
        for entry in entries where entry.status == .ready {
            await importEntry(entry)
        }
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
