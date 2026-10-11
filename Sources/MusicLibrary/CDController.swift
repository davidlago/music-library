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
    /// Your answer to "Do you own this CD?" (nil until answered), with the purchase date and price.
    var owned: Bool?
    var purchasedOn: PurchaseDay?
    var price: Decimal?
    /// Set once ripping has started, from then on changes to the answer are saved right away.
    var ownershipSaved = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var removed = false

    init(volume: AudioCDVolume) {
        self.volume = volume
        id = volume.url.path
        rows = volume.toc.audioTracks.map {
            Row(id: $0.number, title: "Track \($0.number)", artist: "", duration: volume.toc.duration(of: $0), selected: true, status: .pending)
        }
    }

    var title: String { release?.album ?? volume.name }
    var selectedCandidate: DiscRelease? { candidates.first { $0.id == selectedCandidateID } }
    var selectedCount: Int { rows.filter { $0.selected && !$0.status.isFinished }.count }
    /// The library album the matched release is imported as (`SearchIndex.albumKey`).
    var albumKey: String? { release.map { SearchIndex.albumKey(album: $0.album, artist: $0.albumArtist) } }
    var remainingCount: Int {
        rows.filter { $0.selected && ($0.status == .pending || $0.status.isActive) }.count
    }
}

extension CDDisc.RowStatus {
    var isFinished: Bool { self == .done || self == .queued }

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
            }
        } catch {
            disc.lookup = .failed(error.localizedDescription)
        }
    }

    func select(_ disc: CDDisc, candidate: DiscRelease) async {
        disc.selectedCandidateID = candidate.id
        disc.message = nil
        do {
            let release = try await model.musicBrainz.fetchRelease(id: candidate.id)
            guard !disc.removed, disc.selectedCandidateID == candidate.id else { return }
            disc.release = release
            disc.medium = candidate.mediumPosition
            prefillOwnership(disc)
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
        disc.rows = audio.map { t in
            let mb = mapping[t.number]
            let inLibrary = mb.map { mb in
                existing.contains { ($0.metadata.discNo == mb.discNo && $0.trackNo == mb.trackNo) || $0.metadata.mbRecordingId == mb.recordingId }
            } ?? false
            return CDDisc.Row(id: t.number, title: mb?.title ?? "Track \(t.number)", artist: mb?.artist ?? "",
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

    // MARK: Ownership

    /// Fills in the ownership answer from the library when the album is already marked as owned (re-ripping a disc).
    private func prefillOwnership(_ disc: CDDisc) {
        guard disc.owned == nil, !disc.ownershipSaved, let key = disc.albumKey, let p = model.purchases[key] else { return }
        disc.owned = true
        disc.purchasedOn = p.purchasedOn
        disc.price = p.price
    }

    /// Saves the answer for the matched album: owned with its details, or not owned. Unanswered changes nothing.
    func saveOwnership(_ disc: CDDisc) {
        guard let owned = disc.owned, let release = disc.release, let key = disc.albumKey else { return }
        model.setPurchase(owned ? AlbumPurchase(album: release.album, artist: release.albumArtist,
                                                purchasedOn: disc.purchasedOn, price: disc.price) : nil,
                          forKey: key)
    }

    // MARK: Ripping

    func toggleAll(_ disc: CDDisc, _ on: Bool) {
        for i in disc.rows.indices where !disc.rows[i].status.isActive { disc.rows[i].selected = on }
    }

    func cancel(_ disc: CDDisc) { disc.task?.cancel() }

    func rip(_ disc: CDDisc) {
        guard !disc.isRipping, let release = disc.release, let service = model.importService else { return }
        let mapping = CDTrackMapping.map(audioTracks: disc.volume.toc.audioTracks, release: release, medium: disc.medium)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-CD-\(UUID().uuidString)")
        let importer = CDImporter(tools: model.tools)
        let volume = disc.volume
        let cover = disc.cover
        saveOwnership(disc)
        disc.ownershipSaved = true
        disc.isRipping = true
        disc.task = Task { [weak self] in
            let targets = disc.rows.filter { $0.selected && !$0.status.isFinished }.map(\.id)
            var failures = 0
            for (n, number) in targets.enumerated() {
                if Task.isCancelled { break }
                guard let idx = disc.rows.firstIndex(where: { $0.id == number }) else { continue }
                disc.statusLine = "Ripping track \(n + 1) of \(targets.count)"
                guard let mb = mapping[number] else {
                    disc.rows[idx].status = .failed("No matching track in this edition")
                    failures += 1
                    continue
                }
                disc.rows[idx].status = .ripping(0)
                do {
                    _ = try await importer.ripAndImport(
                        volume: volume, cdTrack: number, release: release, releaseTrack: mb, cover: cover, service: service, workDir: work
                    ) { fraction in
                        Task { @MainActor in
                            guard let i = disc.rows.firstIndex(where: { $0.id == number }), disc.rows[i].status.isActive else { return }
                            disc.rows[i].status = fraction >= 0.999 ? .importing : .ripping(fraction)
                        }
                    }
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .done }
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
            if failures == 0, self.model.ejectAfterRip { self.eject(disc) }
        }
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
                let dest = folder.appendingPathComponent(String(format: "%02d - Track %02d.flac", number, number))
                var meta = ["track": "\(number)/\(total)", "title": ""]
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
            if !files.isEmpty { self?.model.importURLs(files) }
        }
    }
}
