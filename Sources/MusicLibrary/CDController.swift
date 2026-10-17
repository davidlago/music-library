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
        disc.libraryTracks = [:]
        disc.rows = audio.map { t in
            let mb = mapping[t.number]
            let match = mb.flatMap { mb in
                existing.first { ($0.metadata.discNo == mb.discNo && $0.trackNo == mb.trackNo) || $0.metadata.mbRecordingId == mb.recordingId }
            }
            disc.libraryTracks[t.number] = match
            let inLibrary = match != nil
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
                        volume: volume, cdTrack: number, release: release, releaseTrack: mb, cover: cover, service: service, workDir: work
                    ) { fraction in
                        Task { @MainActor in
                            guard let i = disc.rows.firstIndex(where: { $0.id == number }), disc.rows[i].status.isActive else { return }
                            disc.rows[i].status = fraction >= 0.999 ? .importing : .ripping(fraction)
                        }
                    }
                    if let i = disc.rows.firstIndex(where: { $0.id == number }) { disc.rows[i].status = .done }
                    disc.libraryTracks[number] = track
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
