import AppKit
import Foundation
import MusicLibraryCore

@MainActor @Observable
final class CDDisc: Identifiable {
    enum Lookup: Equatable {
        case looking, matched, notFound, failed(String)
    }

    enum RowStatus: Equatable {
        case pending, ripping(Double), importing, done, queued, inLibrary, failed(String)
    }

    struct Row: Identifiable, Equatable {
        var id: Int
        var title: String
        var artist: String
        var duration: Double
        var selected: Bool
        var status: RowStatus
    }

    let volume: AudioCDVolume
    nonisolated let id: String
    var lookup: Lookup = .looking
    var candidates: [DiscRelease] = []
    var selectedCandidateID: String?
    var release: ReleaseInfo?
    var medium = 1
    var cover: Data?
    var rows: [Row]
    var isRipping = false
    var isSearching = false
    var warning: String?
    var searchAlbum = ""
    var searchArtist = ""
    var statusLine = ""
    var message: String?
    /// The stored CD items this disc may be (`MusicCollection.matches`: by release, barcode, album key or release
    /// group), the ones not ripped yet first.
    var matches: [CollectionItem] = []
    /// Which copy in your collection this CD is: nil until answered (Settings ▸ Collection can ask whether a CD with
    /// no item is yours).
    var collectionChoice: CDCollectionChoice?
    /// The user picked the copy (or answered), so a new lookup doesn't pick for them again.
    var choiceTouched = false
    /// A new copy's label number, purchase date and price, until it's saved.
    var newSticker: Int?
    var newPurchasedOn: PurchaseDay? = PurchaseDay(Date())
    var newPrice: Decimal?
    /// Set once a label number was suggested for a new copy, so clearing it doesn't bring it back.
    var stickerSuggested = false
    /// The number suggested (`newSticker` while the user hasn't changed it), suggested again if another item takes it.
    var suggestedSticker: Int?
    /// The item this disc's page added (when ripping or cataloging started): the only one switching off removes.
    var createdItemID: String?
    /// Set once ripping or cataloging has started: from then on changes to the choice are saved right away.
    var collectionSaved = false
    /// The rip has been linked to the item (when its first track was imported).
    var ripLinked = false
    /// Items that were in the collection before which this page changed (filling in the release, linking the rip):
    /// each as it was before and as the page last saved it, so picking another copy puts back what it set.
    var touched: [String: (before: CollectionItem, after: CollectionItem)] = [:]
    /// The item Catalog Without Ripping saved, while the disc stays in its drive (shown with an Open button).
    var catalogedItemID: String?
    /// Why the collection item couldn't be saved (a label another item has).
    var collectionMessage: String?
    /// The library's tracks from this disc, by track number: ripped now or before (for checking them).
    var libraryTracks: [Int: Track] = [:]
    var isChecking = false
    var checkError: String?
    /// Where this disc's rip lined up with AccurateRip's (`AccurateRipReport.offset`), for checking a track ripped again.
    var matchOffset: Int?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var removed = false

    init(volume: AudioCDVolume) {
        self.volume = volume
        id = volume.url.path
        // The names macOS gives the disc (its CD-Text or Gracenote's) until (or unless) MusicBrainz knows it.
        rows = volume.toc.audioTracks.map {
            Row(id: $0.number, title: volume.names.titles[$0.number] ?? "Track \($0.number)", artist: "",
                duration: volume.toc.duration(of: $0), selected: true, status: .pending)
        }
        searchAlbum = volume.names.title ?? ""
    }

    /// The release's album, else the album on the page (for a disc MusicBrainz doesn't know), else the volume's name.
    var title: String { release?.album ?? (searchAlbum.isEmpty ? volume.name : searchAlbum) }
    var selectedCandidate: DiscRelease? { candidates.first { $0.id == selectedCandidateID } }
    var selectedCount: Int { rows.filter { $0.selected && !$0.status.isFinished }.count }
    /// The library album the matched release is imported as (`SearchIndex.albumKey`).
    var albumKey: String? { release.map { SearchIndex.albumKey(album: $0.album, artist: $0.albumArtist) } }
    var remainingCount: Int {
        rows.filter { $0.selected && ($0.status == .pending || $0.status.isActive) }.count
    }
    /// MusicBrainz doesn't know the disc (or couldn't be asked): it can still be cataloged and ripped to the import
    /// queue, named by the page's album and artist (`searchAlbum`/`searchArtist`, seeded from the disc's names).
    var isUnmatched: Bool {
        guard release == nil else { return false }
        switch lookup {
        case .notFound, .failed: return true
        case .looking, .matched: return false
        }
    }
    /// An unmatched disc can be ripped into the library once the page names its album.
    var canRipUnmatched: Bool { isUnmatched && !searchAlbum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The collection item the rip goes with: the existing copy picked, or the new one once it's saved.
    var itemID: String? {
        switch collectionChoice {
        case .existing(let id)?: id
        case .new?: createdItemID
        default: nil
        }
    }
}

/// Which copy in your collection a disc in a drive is.
enum CDCollectionChoice: Hashable {
    /// A CD item already in the collection (ripped or not).
    case existing(String)
    /// A new CD item, saved when ripping or cataloging starts.
    case new
    /// Not yours: nothing is added (and nothing existing is touched).
    case none
}

extension CDDisc.RowStatus {
    var isFinished: Bool { self == .done || self == .queued }

    /// A track in the library from this disc whose AccurateRip result the row shows.
    var showsCheck: Bool {
        switch self {
        case .done, .inLibrary, .failed: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .ripping, .importing: return true
        default: return false
        }
    }
}

@MainActor @Observable
final class CDController {
    nonisolated(unsafe) static var volumesDirectory = URL(fileURLWithPath: "/Volumes")

    var discs: [CDDisc] = []
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(model: AppModel) { self.model = model }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?["NSWorkspaceVolumeURLKey"] as? URL
            MainActor.assumeIsolated {
                guard let url else { return }
                self?.volumeMounted(url)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?["NSWorkspaceVolumeURLKey"] as? URL
            MainActor.assumeIsolated {
                guard let url else { return }
                self?.volumeUnmounted(url)
            }
        })
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: Self.volumesDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
        for v in volumes { volumeMounted(v) }
    }

    func volumeMounted(_ url: URL) {
        let path = url.path
        guard !discs.contains(where: { $0.id == path }) else { return }
        guard let volume = try? AudioCDVolume.load(at: url) else { return }
        let disc = CDDisc(volume: volume)
        discs.append(disc)
        Task { await lookup(disc) }
    }

    func volumeUnmounted(_ url: URL) {
        guard let disc = discs.first(where: { $0.id == url.path }) else { return }
        disc.removed = true
        if disc.isRipping {
            disc.task?.cancel()
            for i in disc.rows.indices where disc.rows[i].selected && disc.rows[i].status != .done && disc.rows[i].status != .inLibrary {
                disc.rows[i].status = .failed("Disc removed")
            }
        }
        discs.removeAll { $0.id == disc.id }
        if model.sidebar == .cd(disc.id) { model.sidebar = .songs }
    }

    // MARK: Lookup

    func lookup(_ disc: CDDisc) async {
        disc.lookup = .looking
        disc.message = nil
        do {
            let found = try await model.musicBrainz.lookupDisc(disc.volume.toc)
            guard !disc.removed else { return }
            disc.candidates = found
            if let first = found.first {
                await select(disc, candidate: first)
            } else {
                disc.lookup = .notFound
                matchCollectionItem(disc)
                await nameDisc(disc)
            }
        } catch {
            disc.lookup = .failed(error.localizedDescription)
            matchCollectionItem(disc)
            await nameDisc(disc)
        }
    }

    /// Fills an unmatched disc's album and artist from the name macOS gives it, which often runs the two together
    /// ("Placido Domingo Popular Favorites"): split where it starts with an artist in your collections, else with
    /// one MusicBrainz finds for it, in that artist's spelling ("Plácido Domingo"). Fields already edited are left
    /// alone.
    func nameDisc(_ disc: CDDisc) async {
        guard let title = disc.volume.names.title else { return }
        func untouched() -> Bool { disc.searchAlbum == title && disc.searchArtist.isEmpty && !disc.removed }
        guard untouched() else { return }
        var split = CDNames.split(title, artists: model.allArtists.map(\.name))
        if split == nil, let best = try? await model.musicBrainz.searchArtists(in: title).first {
            // Only the best match: weaker ones are often a word of the title ("Placido", "Love").
            split = CDNames.split(title, artists: [best.name])
        }
        guard let split, untouched() else { return }
        disc.searchArtist = split.artist
        disc.searchAlbum = split.album
    }

    func select(_ disc: CDDisc, candidate: DiscRelease) async {
        disc.selectedCandidateID = candidate.id
        disc.message = nil
        do {
            let release = try await model.musicBrainz.fetchRelease(id: candidate.id)
            guard !disc.removed, disc.selectedCandidateID == candidate.id else { return }
            disc.release = release
            disc.medium = candidate.mediumPosition
            matchCollectionItem(disc)
            disc.cover = (try? await model.coverArt.fetchFront(releaseId: release.id, releaseGroupId: release.releaseGroupId)) ?? nil
            buildRows(disc)
            disc.lookup = .matched
        } catch {
            guard disc.selectedCandidateID == candidate.id else { return }
            disc.lookup = .failed(error.localizedDescription)
        }
    }

    private func buildRows(_ disc: CDDisc) {
        guard let release = disc.release else { return }
        let audio = disc.volume.toc.audioTracks
        let mapping = CDTrackMapping.map(audioTracks: audio, release: release, medium: disc.medium)
        let mediumCount = release.tracks.filter { $0.discNo == disc.medium }.count
        disc.warning = (mediumCount != audio.count || mapping.count != audio.count)
            ? "The disc has \(audio.count) audio tracks but this edition lists \(mediumCount). Check the track names before ripping." : nil
        let existing = (try? model.database?.tracks(releaseId: release.id)) ?? []
        disc.libraryTracks = [:]
        disc.rows = audio.map { t in
            let mb = mapping[t.number]
            let match = mb.flatMap { mb in
                existing.first { ($0.metadata.discNo == mb.discNo && $0.trackNo == mb.trackNo) || $0.metadata.mbRecordingId == mb.recordingId }
            }
            disc.libraryTracks[t.number] = match
            let inLibrary = match != nil
            return CDDisc.Row(id: t.number, title: mb?.title ?? disc.volume.names.titles[t.number] ?? "Track \(t.number)", artist: mb?.artist ?? "",
                              duration: disc.volume.toc.duration(of: t), selected: !inLibrary,
                              status: inLibrary ? .inLibrary : .pending)
        }
    }

    func searchManually(_ disc: CDDisc) async {
        disc.isSearching = true
        disc.message = nil
        defer { disc.isSearching = false }
        do {
            let found = try await model.musicBrainz.searchReleases(
                album: disc.searchAlbum, artist: disc.searchArtist, trackCount: disc.volume.toc.audioTracks.count)
            guard !disc.removed else { return }
            if found.isEmpty { disc.message = "No releases with \(disc.volume.toc.audioTracks.count) tracks found."; return }
            disc.candidates = found
            await select(disc, candidate: found[0])
        } catch {
            disc.message = "Search failed: \(error.localizedDescription)"
        }
    }

    func submit(_ disc: CDDisc) { NSWorkspace.shared.open(disc.volume.toc.submissionURL) }

    func eject(_ disc: CDDisc) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: disc.volume.url) } catch { model.errorMessage = error.localizedDescription }
    }

    // MARK: Collection

    /// Finds the CD items this disc may be. Until the user picks, the first one (not ripped yet, then the closest
    /// match) is chosen, else a new copy, or the question when Settings ▸ Collection asks. Nothing is matched again
    /// once ripping or cataloging has saved the choice. Records and downloads are never matched.
    func matchCollectionItem(_ disc: CDDisc) {
        guard !disc.collectionSaved else { return }
        guard let release = disc.release else {
            // A disc MusicBrainz doesn't know has no copy to find, but it can still be yours: a new CD.
            guard disc.isUnmatched, !disc.choiceTouched else { return }
            disc.matches = []
            disc.collectionChoice = model.askCDOwnership ? nil : .new
            if disc.collectionChoice == .new { suggestLabel(disc) }
            return
        }
        disc.matches = model.collection.matches(releaseID: release.id, releaseGroupID: release.releaseGroupId, albumKey: disc.albumKey,
                                                barcode: release.barcode, medium: .cd)
        if disc.choiceTouched {
            // A copy picked earlier that this edition doesn't match any more: pick again.
            guard case .existing(let id)? = disc.collectionChoice, !disc.matches.contains(where: { $0.id == id }) else { return }
        }
        disc.collectionChoice = disc.matches.first.map { .existing($0.id) } ?? (model.askCDOwnership ? nil : .new)
        if disc.collectionChoice == .new { suggestLabel(disc) }
    }

    /// Matches every disc in the drives again after the collection changed (or first loaded: a disc looked up before
    /// that was matched against an empty collection).
    func collectionChanged() {
        for disc in discs where !disc.removed { matchCollectionItem(disc) }
    }

    /// Opens a disc's page from its item's (Rip Now): the rip goes with that item, unless ripping or cataloging
    /// already saved another choice.
    func show(_ disc: CDDisc, for item: CollectionItem) {
        // The matches may be from before the item was added or changed.
        matchCollectionItem(disc)
        if !disc.collectionSaved, disc.release != nil, item.medium == .cd, item.isEditable, !disc.matches.contains(where: { $0.id == item.id }) {
            // Saved a moment ago (not in the rebuilt collection yet): it's the item this disc was found for.
            disc.matches.insert(item, at: 0)
        }
        if !disc.collectionSaved, disc.matches.contains(where: { $0.id == item.id }) {
            disc.collectionChoice = .existing(item.id)
            disc.choiceTouched = true
        }
        model.sidebar = .cd(disc.id)
    }

    /// The next number in your CD labels, past the ones saved and the ones suggested for other discs in the drives.
    func nextLabelNumber(for disc: CDDisc? = nil) -> Int {
        let pending = discs.filter { $0 !== disc && $0.createdItemID == nil && $0.collectionChoice == .new }.compactMap(\.newSticker)
        return model.nextNumber(in: .cd, pending: pending)
    }

    /// A new copy gets the next label number the first time, and again when the number suggested (and left as it
    /// is) turns out to be another item's: suggested while the collection was loading, or taken since.
    func suggestLabel(_ disc: CDDisc) {
        guard disc.collectionChoice == .new else { return }
        if disc.stickerSuggested {
            guard disc.createdItemID == nil, let n = disc.newSticker, n == disc.suggestedSticker,
                  let sticker = Sticker(series: .cd, number: n), model.itemLabeled(sticker, excluding: nil) != nil else { return }
            disc.newSticker = nil
        }
        disc.stickerSuggested = true
        if disc.newSticker == nil {
            disc.newSticker = nextLabelNumber(for: disc)
            disc.suggestedSticker = disc.newSticker
        }
    }

    /// Changes which copy the CD is. Moving away from a new copy this page saved removes that one item (never an
    /// item that was in the collection before); once ripping or cataloging has started, the new choice is saved at
    /// once.
    func setChoice(_ disc: CDDisc, _ choice: CDCollectionChoice?) {
        guard disc.collectionChoice != choice else { return }
        disc.choiceTouched = true
        disc.collectionMessage = nil
        if disc.collectionChoice == .new, let created = disc.createdItemID {
            if model.item(id: created) != nil { model.deleteItem(id: created) }
            disc.createdItemID = nil
        }
        // A copy that was there before goes back to how it was before this page filled it in and linked the rip.
        if case .existing(let previous)? = disc.collectionChoice, choice != .existing(previous) { restore(disc, itemID: previous) }
        disc.catalogedItemID = nil
        disc.collectionChoice = choice
        suggestLabel(disc)
        guard disc.collectionSaved else { return }
        _ = saveCollection(disc, cataloging: false)
        disc.ripLinked = false
        if let track = disc.rows.first(where: { $0.status == .done }).flatMap({ disc.libraryTracks[$0.id] }) { linkRip(disc, track: track) }
    }

    /// Saves the CD's copy in the collection: an existing item gets the album key and the release's track and disc
    /// counts, and only the details it lacks (its medium, label and purchase are never changed here); a new one is
    /// added with its label and purchase. Not yours (or unanswered) saves nothing. With `cataloging`, an item with no
    /// cover of its own and no music takes the disc's cover. False (with `collectionMessage`) when it can't be saved.
    func saveCollection(_ disc: CDDisc, cataloging: Bool) -> Bool {
        guard let release = disc.release, let key = disc.albumKey else { return disc.isUnmatched && saveUnmatched(disc) }
        let cover = cataloging ? disc.cover.flatMap(CoverImage.jpeg(from:)) : nil
        switch disc.collectionChoice {
        case .existing(let id)?:
            guard let current = model.item(id: id), current.isEditable, current.medium == .cd else { break }
            let jpeg = current.coverFile == nil && model.collection.libraryTracks(current).isEmpty ? cover : nil
            let saved = model.changeItem(id: id, cover: jpeg) { fill(&$0, release: release, disc: disc, key: key) }
            remember(disc, before: current, after: saved)
        case .new?:
            if let created = disc.createdItemID, model.item(id: created) != nil {
                model.changeItem(id: created) { fill(&$0, release: release, disc: disc, key: key) }
                break
            }
            if let n = disc.newSticker, let sticker = Sticker(series: .cd, number: n), let other = model.itemLabeled(sticker, excluding: nil) {
                disc.collectionMessage = "\(sticker.text) is taken by “\(other.album)”. Pick another number."
                return false
            }
            var item = CollectionItem(medium: .cd, album: release.album, artist: release.albumArtist, albumKey: key)
            item.stickerNumber = disc.newSticker
            item.purchasedOn = disc.newPurchasedOn
            item.price = disc.newPrice
            fill(&item, release: release, disc: disc, key: key)
            guard let saved = model.saveItem(item, cover: cover) else { return false }
            disc.createdItemID = saved.id
        case .none?, nil:
            break
        }
        disc.collectionMessage = nil
        disc.collectionSaved = true
        return true
    }

    /// Saves an unmatched disc's copy: a new CD named by the page's album and artist, with the disc's track count and
    /// the cover chosen on the page (an existing copy picked is left as it is, but takes that cover if it has none and
    /// no music). False (with `collectionMessage`) when there's no album name or the label is taken.
    private func saveUnmatched(_ disc: CDDisc) -> Bool {
        let album = String(disc.searchAlbum.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        let artist = String(disc.searchArtist.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        let cover = disc.cover.flatMap(CoverImage.jpeg(from:))
        switch disc.collectionChoice {
        case .existing(let id)?:
            guard let current = model.item(id: id), current.isEditable, current.medium == .cd else { break }
            if let cover, current.coverFile == nil, model.collection.libraryTracks(current).isEmpty {
                remember(disc, before: current, after: model.changeItem(id: id, cover: cover) { _ in })
            }
        case .new?:
            guard !album.isEmpty else {
                disc.collectionMessage = "Type the album's name above to add this CD to your physical collection."
                return false
            }
            let key = SearchIndex.albumKey(album: album, artist: artist)
            if let created = disc.createdItemID, let current = model.item(id: created) {
                let noMusic = model.collection.libraryTracks(current).isEmpty
                model.changeItem(id: created) {
                    $0.album = album
                    $0.artist = artist
                    if noMusic { $0.albumKey = key }
                }
                break
            }
            if let n = disc.newSticker, let sticker = Sticker(series: .cd, number: n), let other = model.itemLabeled(sticker, excluding: nil) {
                disc.collectionMessage = "\(sticker.text) is taken by “\(other.album)”. Pick another number."
                return false
            }
            var item = CollectionItem(medium: .cd, album: album, artist: artist, albumKey: key)
            item.stickerNumber = disc.newSticker
            item.purchasedOn = disc.newPurchasedOn
            item.price = disc.newPrice
            let tracks = disc.volume.toc.audioTracks.count
            item.trackCount = (1...999).contains(tracks) ? tracks : nil
            item.discCount = 1
            guard let saved = model.saveItem(item, cover: cover) else { return false }
            disc.createdItemID = saved.id
        case .none?, nil:
            break
        }
        disc.collectionMessage = nil
        disc.collectionSaved = true
        return true
    }

    /// A cover for a disc MusicBrainz doesn't know (a file, or an image dropped on it): shown on the page, and the
    /// cover of the CD this page adds to your collection (at once when it's already added).
    func setCover(_ disc: CDDisc, _ data: Data) {
        guard let jpeg = CoverImage.jpeg(from: data) else {
            disc.message = "That isn't an image the app can read."
            return
        }
        disc.cover = jpeg
        if let id = disc.createdItemID, model.item(id: id) != nil { model.changeItem(id: id, cover: jpeg) { _ in } }
    }

    /// The release's details on a CD item: the album key it's ripped as (unless the item is the digital copy of
    /// another album already), the track and disc counts (of the item's own release), and the rest only where blank.
    private func fill(_ item: inout CollectionItem, release: ReleaseInfo, disc: CDDisc, key: String) {
        if item.albumKey != key, model.collection.libraryTracks(item).isEmpty { item.albumKey = key }
        func blank(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
        func text(_ s: String) -> String? {
            let t = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return t.isEmpty ? nil : t
        }
        let tracks = release.tracks.count, discsTotal = max(release.discTotal, Set(release.tracks.map(\.discNo)).count)
        let sameRelease = item.releaseID == nil || item.releaseID == release.id
        if sameRelease || item.trackCount == nil { item.trackCount = (1...999).contains(tracks) ? tracks : item.trackCount }
        if sameRelease || item.discCount == nil { item.discCount = (1...99).contains(discsTotal) ? discsTotal : item.discCount }
        if item.album.isEmpty { item.album = String(release.album.prefix(1000)) }
        if item.artist.isEmpty { item.artist = String(release.albumArtist.prefix(1000)) }
        if item.releaseID == nil { item.releaseID = MBID.validated(release.id) }
        if item.releaseGroupID == nil { item.releaseGroupID = MBID.validated(release.releaseGroupId) }
        if item.year == nil, let y = release.year ?? release.originalYear, (1000...9999).contains(y) { item.year = y }
        // The edition's own details only on an item of this edition (or of none yet): an item that names another
        // release keeps its own (Change Edition changes them).
        guard sameRelease else { return }
        if item.barcode == nil {
            let digits = release.barcode.filter { ("0"..."9").contains($0) }
            if (6...20).contains(digits.count) { item.barcode = digits }
        }
        if blank(item.catalogNumber) { item.catalogNumber = text(release.catalogNumber) ?? item.catalogNumber }
        if blank(item.recordLabel) { item.recordLabel = text(release.label) ?? item.recordLabel }
        if blank(item.country) { item.country = text(release.country) ?? item.country }
        if blank(item.formatDetail), let format = disc.selectedCandidate?.format { item.formatDetail = text(format) ?? item.formatDetail }
    }

    /// Once a track of the disc is imported, the CD it was ripped from is ripped (D4): a cancelled rip leaves it
    /// "Not ripped". Only a CD item, and only when the songs are under its album key (or it has no music of its own).
    private func linkRip(_ disc: CDDisc, track: Track) {
        guard !disc.ripLinked, let id = disc.itemID, let current = model.item(id: id), current.medium == .cd, current.isEditable else { return }
        disc.ripLinked = true
        let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
        guard current.albumKey == key || model.collection.libraryTracks(current).isEmpty else { return }
        let saved = model.changeItem(id: id) {
            $0.albumKey = key
            $0.digitalSource = .rip
        }
        if id != disc.createdItemID { remember(disc, before: current, after: saved) }
    }

    /// Keeps what this page changed on an item that was in the collection before (the first state it saw).
    private func remember(_ disc: CDDisc, before: CollectionItem, after: CollectionItem?) {
        guard let after, after != before || disc.touched[after.id] != nil else { return }
        disc.touched[after.id] = (disc.touched[after.id]?.before ?? before, after)
    }

    /// Puts back what this page set on an item that was in the collection before (the release it filled in, its
    /// link to the rip, the disc's cover), field by field and only where it's still what the page set: anything
    /// changed since, here or elsewhere, stays. Its label, purchase and notes are never touched by the page.
    private func restore(_ disc: CDDisc, itemID: String) {
        guard let t = disc.touched.removeValue(forKey: itemID) else { return }
        if disc.ripLinked, disc.itemID == itemID { disc.ripLinked = false }
        model.changeItem(id: itemID) { item in
            func back<T: Equatable>(_ path: WritableKeyPath<CollectionItem, T>) {
                if item[keyPath: path] == t.after[keyPath: path], t.before[keyPath: path] != t.after[keyPath: path] {
                    item[keyPath: path] = t.before[keyPath: path]
                }
            }
            back(\.albumKey); back(\.digitalSource); back(\.coverFile)
            back(\.trackCount); back(\.discCount); back(\.album); back(\.artist); back(\.year)
            back(\.releaseID); back(\.releaseGroupID); back(\.barcode); back(\.catalogNumber)
            back(\.recordLabel); back(\.country); back(\.formatDetail)
        }
    }

    /// Catalog Without Ripping: saves the CD in your collection (the copy matched, else a new one) with the disc's
    /// cover, and ejects it when Settings ▸ Collection says so, showing its page.
    func catalog(_ disc: CDDisc) {
        guard !disc.isRipping, disc.release != nil || disc.isUnmatched else { return }
        if disc.collectionChoice == nil || disc.collectionChoice == CDCollectionChoice.none {
            setChoice(disc, disc.matches.first.map { .existing($0.id) } ?? .new)
        }
        guard saveCollection(disc, cataloging: true), let id = disc.itemID else { return }
        if model.ejectAfterCataloging {
            model.showShelf()
            model.showItem(id: id)
            eject(disc)
        } else {
            // The disc stays: its page says it's saved, with a way to open the item.
            disc.catalogedItemID = id
        }
    }

    // MARK: Ripping

    func toggleAll(_ disc: CDDisc, _ on: Bool) {
        for i in disc.rows.indices where !disc.rows[i].status.isActive { disc.rows[i].selected = on }
    }

    func cancel(_ disc: CDDisc) { disc.task?.cancel() }

    func rip(_ disc: CDDisc) {
        guard !disc.isRipping, let service = model.importService, let tags = tagging(disc) else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-CD-\(UUID().uuidString)")
        let importer = CDImporter(tools: model.tools)
        let volume = disc.volume
        let cover = disc.cover
        guard saveCollection(disc, cataloging: false) else { return }
        disc.isRipping = true
        disc.task = Task { [weak self] in
            let targets = disc.rows.filter { $0.selected && !$0.status.isFinished }.map(\.id)
            var failures = 0
            for (n, number) in targets.enumerated() {
                if Task.isCancelled { break }
                guard let idx = disc.rows.firstIndex(where: { $0.id == number }) else { continue }
                disc.statusLine = "Ripping track \(n + 1) of \(targets.count)"
                guard let metadata = tags(number) else {
                    disc.rows[idx].status = .failed("No matching track in this edition")
                    failures += 1
                    continue
                }
                disc.rows[idx].status = .ripping(0)
                // Already in the library from this disc: rip it again in place, instead of importing a second copy.
                if let existing = disc.libraryTracks[number] {
                    guard let self else { break }
                    do {
                        if case .kept(let reason) = try await self.ripInPlace(disc, track: number, replacing: existing, work: work) {
                            failures += 1
                            if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .failed(reason) }
                        }
                    } catch is CancellationError {
                        if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .inLibrary }
                        break
                    } catch {
                        failures += 1
                        if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .failed(error.localizedDescription) }
                    }
                    continue
                }
                do {
                    let track = try await importer.ripAndImport(
                        volume: volume, cdTrack: number, metadata: metadata, cover: cover, service: service, workDir: work
                    ) { fraction in
                        Task { @MainActor in
                            guard let i = disc.rows.firstIndex(where: { $0.id == number }), disc.rows[i].status.isActive else { return }
                            disc.rows[i].status = fraction >= 0.999 ? .importing : .ripping(fraction)
                        }
                    }
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .done }
                    disc.libraryTracks[number] = track
                    self?.linkRip(disc, track: track)
                    // The disc is saved with the track right away, so it can be checked later if checking now fails.
                    self?.model.saveRipChecks([RipCheck(trackId: track.id, toc: volume.toc, discTrack: number, result: .unchecked)])
                    self?.model.reloadLibrary()
                } catch is CancellationError {
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .pending }
                    break
                } catch ImportError.duplicate {
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .inLibrary }
                } catch {
                    failures += 1
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .failed(error.localizedDescription) }
                }
            }
            try? FileManager.default.removeItem(at: work)
            disc.isRipping = false
            disc.statusLine = ""
            guard let self, !disc.removed, !Task.isCancelled else { return }
            await self.checkRips(disc)
            // A misread track can be ripped again while the disc is still in.
            if failures == 0, !self.hasInaccurateTracks(disc), self.model.ejectAfterRip { self.eject(disc) }
        }
    }

    /// What each of the disc's tracks is tagged with when ripped: its song of the matched release, or (a disc
    /// MusicBrainz doesn't know) the album, artist and song title on the page. Nil when there's nothing to tag with yet.
    func tagging(_ disc: CDDisc) -> ((Int) -> TrackMetadata?)? {
        if let release = disc.release {
            let mapping = CDTrackMapping.map(audioTracks: disc.volume.toc.audioTracks, release: release, medium: disc.medium)
            return { number in
                mapping[number].map { mb in
                    var m = TrackMetadata()
                    release.apply(mb, to: &m)
                    return m
                }
            }
        }
        guard disc.isUnmatched, disc.canRipUnmatched else { return nil }
        let album = disc.searchAlbum, artist = disc.searchArtist, total = disc.volume.toc.audioTracks.count
        let titles = Dictionary(disc.rows.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return { number in .unmatchedDisc(album: album, artist: artist, title: titles[number] ?? "", track: number, of: total) }
    }

    // MARK: Checking with AccurateRip

    /// The disc's tracks in the library that AccurateRip found misread.
    func hasInaccurateTracks(_ disc: CDDisc) -> Bool {
        disc.libraryTracks.values.contains { model.ripChecks[$0.id]?.result == .inaccurate }
    }

    /// Checks the disc's tracks in the library with AccurateRip, reading the tracks around them from the disc.
    func checkRips(_ disc: CDDisc) async {
        let toc = disc.volume.toc
        // Tracks saved as ripped from another disc (another pressing of the album) keep that disc's result.
        let tracks = disc.libraryTracks.filter { model.ripChecks[$0.value.id].map { $0.toc == toc } ?? true }
        guard !tracks.isEmpty, !disc.isChecking else { return }
        disc.isChecking = true
        disc.checkError = nil
        defer { disc.isChecking = false }
        do {
            let report = try await model.rips.check(toc: toc, tracks: tracks, volume: disc.volume)
            disc.matchOffset = report?.offset ?? disc.matchOffset
        } catch is CancellationError {
        } catch {
            disc.checkError = error.localizedDescription
        }
    }

    /// Rips a misread track again (`ripInPlace`). Can be used again after a round that didn't fix it.
    func ripAgain(_ disc: CDDisc, track number: Int) {
        guard !disc.isRipping, !disc.isChecking, let track = disc.libraryTracks[number],
              let row = disc.rows.firstIndex(where: { $0.id == number }) else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-CD-\(UUID().uuidString)")
        let previous = disc.rows[row].status
        disc.isRipping = true
        disc.statusLine = "Ripping track \(number) again"
        disc.task = Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: work)
                disc.isRipping = false
                disc.statusLine = ""
            }
            guard let self else { return }
            do {
                if case .kept(let reason) = try await self.ripInPlace(disc, track: number, replacing: track, work: work) {
                    disc.rows[row].status = .failed(reason)
                }
            } catch is CancellationError {
                disc.rows[row].status = previous
            } catch {
                disc.rows[row].status = .failed(error.localizedDescription)
            }
        }
    }

    enum InPlaceOutcome {
        case replaced
        /// The earlier rip stays, for this reason.
        case kept(String)
    }

    /// How many times ripping a track again reads it at most; Rip Again can be used again for another round.
    static let readPasses = 5

    /// Rips a track that's already in the library again and swaps the new rip in for the library's file, keeping the
    /// track (its ID, so its plays, likes and playlists). While AccurateRip says the rip is misread, the track is read
    /// again, up to `passes` times, and the reads are combined sample by sample (`ReadVote`): a damaged spot reads
    /// differently each time, so the values most reads agree on can be right where no single read is. When they
    /// aren't, the versions of each damaged spot the reads gave are tried in combination with AccurateRip confirming
    /// (`RipChecker.repair`). The new rip is kept unless it's still misread, or the earlier rip was accurate and the new
    /// one can't be confirmed.
    private func ripInPlace(_ disc: CDDisc, track number: Int, replacing track: Track, work: URL,
                            passes: Int = CDController.readPasses) async throws -> InPlaceOutcome {
        let toc = disc.volume.toc
        guard let source = disc.volume.trackFiles[number], let cd = toc.audioTracks.first(where: { $0.number == number }),
              let destination = track.resolvedFileURL(root: model.libraryRoot) else { throw CDError.missingTrackFile(number) }
        let file = try CDTrackAudioFile(url: source)
        guard file.sampleCount == toc.sectors(of: cd) * AccurateRip.samplesPerSector else { throw CDError.missingTrackFile(number) }
        func setStatus(_ status: CDDisc.RowStatus) {
            if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = status }
        }
        let earlier = model.ripChecks[track.id]
        var vote: ReadVote?
        for pass in 1...passes {
            disc.statusLine = pass == 1 ? "Ripping track \(number) again" : "Reading track \(number) again: \(pass) of \(passes)"
            setStatus(.ripping(Double(pass - 1) / Double(passes)))
            let read = try await file.readAll { fraction in
                Task { @MainActor in
                    guard let i = disc.rows.firstIndex(where: { $0.id == number }), disc.rows[i].status.isActive else { return }
                    disc.rows[i].status = .ripping((Double(pass - 1) + fraction) / Double(passes))
                }
            }
            if vote == nil {
                vote = ReadVote(first: read)
            } else {
                let identical = vote!.add(read)
                if pass == 2, identical {
                    return .kept("The drive reads this track the same way every time, so more reads won't help: the disc is likely damaged there.")
                }
            }
            // Two reads that differ can't outvote each other: read a third time first.
            if pass == 2 { continue }
            var samples = vote!.result
            setStatus(.importing)
            disc.statusLine = "Checking track \(number) with AccurateRip"
            var report: AccurateRipReport?
            var checked = true
            func check(_ samples: [UInt32]) async throws {
                do {
                    report = try await model.rips.check(toc: toc, tracks: [number: track], volume: disc.volume, samples: [number: samples],
                                                        offsetHint: disc.matchOffset ?? earlier?.offset, save: false)
                    checked = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    report = nil
                    checked = false
                }
            }
            try await check(samples)
            // Voting got some spot wrong: try the reads' versions of the damaged spots in combination.
            if report?.tracks[number] == .inaccurate, pass >= 3 {
                disc.statusLine = "Repairing track \(number) from \(pass) reads"
                if let repaired = try await model.rips.repair(toc: toc, track: number, volume: disc.volume, vote: vote!,
                                                              offsetHint: report?.offset ?? disc.matchOffset ?? earlier?.offset) {
                    samples = repaired
                    try await check(samples)
                }
            }
            if let offset = report?.offset { disc.matchOffset = offset }
            if report?.tracks[number] == .inaccurate { continue }
            var accurate = false
            if case .accurate? = report?.tracks[number] { accurate = true }
            if earlier?.result == .accurate, !accurate {
                return .kept("The new rip couldn't be confirmed by AccurateRip, so the earlier, accurate rip was kept.")
            }
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let temp = work.appendingPathComponent(String(format: "%02d-again.flac", number))
            defer { try? FileManager.default.removeItem(at: temp) }
            try await PCMEncoder.writeFLAC(samples, to: temp, tools: model.tools)
            try await replaceFile(of: track, at: destination, with: temp)
            model.saveRipChecks([checked ? RipCheck(trackId: track.id, toc: toc, discTrack: number, report: report)
                                         : RipCheck(trackId: track.id, toc: toc, discTrack: number, result: .unchecked)])
            setStatus(.done)
            model.reloadLibrary()
            return .replaced
        }
        return .kept("Still misread after \(vote?.reads ?? passes) reads, so the earlier rip was kept. Rip Again tries another round.")
    }

    /// Writes the new rip with the track's tags and cover next to the old file, then swaps them.
    private func replaceFile(of track: Track, at destination: URL, with rip: URL) async throws {
        let cover = track.coverURL(root: model.libraryRoot).flatMap { try? Data(contentsOf: $0) }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".rerip-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staged) }
        // Like an import, the track records the hash of the rip it came from (before tags), not of the library file.
        let sha = try ImportService.sha256(of: rip)
        try await TagWriter(tools: model.tools).writeTaggedCopy(source: rip, destination: staged, metadata: track.metadata, cover: cover)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        var updated = track
        updated.sha256 = sha
        try model.database?.updateTrack(updated)
    }

    /// Rips the checked tracks to FLAC files and hands them to the normal import queue.
    func ripToImportQueue(_ disc: CDDisc) {
        guard !disc.isRipping else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibrary-CD", isDirectory: true)
            .appendingPathComponent(disc.volume.toc.discID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ripper = CDRipper(tools: model.tools)
        let volume = disc.volume
        let album = disc.searchAlbum, artist = disc.searchArtist
        let total = volume.toc.audioTracks.count
        disc.isRipping = true
        disc.task = Task { [weak self] in
            let targets = disc.rows.filter { $0.selected && !$0.status.isFinished }.map(\.id)
            var files: [URL] = []
            for (n, number) in targets.enumerated() {
                if Task.isCancelled { break }
                guard let idx = disc.rows.firstIndex(where: { $0.id == number }),
                      let source = volume.trackFiles[number], let cd = volume.toc.tracks.first(where: { $0.number == number }) else { continue }
                disc.statusLine = "Ripping track \(n + 1) of \(targets.count)"
                disc.rows[idx].status = .ripping(0)
                // The disc's own title (as macOS names it), not the row's: here the release, if any, may be the wrong album.
                let title = volume.names.titles[number] ?? ""
                let name = Organizer.sanitize(title).isEmpty ? String(format: "Track %02d", number) : Organizer.sanitize(title)
                let dest = folder.appendingPathComponent(String(format: "%02d - ", number) + name + ".flac")
                var meta = ["track": "\(number)/\(total)", "title": title]
                meta["album"] = album
                meta["artist"] = artist
                do {
                    try await ripper.rip(source, to: dest, expectedDuration: volume.toc.duration(of: cd), metadata: meta) { fraction in
                        Task { @MainActor in
                            guard let i = disc.rows.firstIndex(where: { $0.id == number }), disc.rows[i].status.isActive else { return }
                            disc.rows[i].status = .ripping(fraction)
                        }
                    }
                    disc.rows[idx].status = .queued
                    files.append(dest)
                } catch is CancellationError {
                    disc.rows[idx].status = .pending
                    break
                } catch {
                    disc.rows[idx].status = .failed(error.localizedDescription)
                }
            }
            disc.isRipping = false
            disc.statusLine = ""
            guard let self, !files.isEmpty else { return }
            // The files are the rip of the CD picked on this page: the Import page links them to it (D4).
            if self.saveCollection(disc, cataloging: false), let id = disc.itemID { self.model.importLinkItemID = id }
            self.model.importURLs(files)
        }
    }
}
