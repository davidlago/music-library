import Foundation
import MusicLibraryCore

/// Checks rips with AccurateRip: right after ripping a CD (reading the tracks around the ripped ones from the disc),
/// and later for any album, from its files alone. Results are saved per track (`AppModel.ripChecks`).
@MainActor @Observable
final class RipChecker {
    enum AlbumState: Equatable {
        case checking
        case failed(String)
        /// None of the discs MusicBrainz lists for the album's release has its tracks' exact lengths.
        case noDisc
        case done
    }

    /// By album key (`AlbumInfoStore.key`).
    private(set) var albumStates: [String: AlbumState] = [:]
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var pressingsCache: [URL: [AccurateRipPressing]?] = [:]

    init(model: AppModel) { self.model = model }

    /// Checks `tracks` (by their number on the disc `toc`) and saves the results. `volume` is the disc when it's in
    /// the drive: tracks that weren't ripped are read from it at their edges, for the drive's offset. `samples`
    /// replaces a track's library file (a fresh rip being checked before it replaces the file), by track number.
    func check(toc: CDTOC, tracks: [Int: Track], volume: AudioCDVolume? = nil, samples: [Int: [UInt32]] = [:],
               offsetHint: Int? = nil, save: Bool = true) async throws -> AccurateRipReport? {
        let pressings = try await pressings(for: toc)
        var report: AccurateRipReport?
        if let pressings {
            var files: [Int: URL] = [:]
            var discFiles: [Int: URL] = [:]
            for (index, cd) in toc.audioTracks.enumerated() {
                // A track given in memory is read from there (the overlay below).
                if samples[cd.number] == nil, let t = tracks[cd.number], RipDiscMatcher.isCDAudio(t),
                   let url = t.resolvedFileURL(root: model.libraryRoot) {
                    files[index] = url
                }
                if let url = volume?.trackFiles[cd.number] { discFiles[index] = url }
            }
            var inMemory: [Int: [UInt32]] = [:]
            for (index, cd) in toc.audioTracks.enumerated() { inMemory[index] = samples[cd.number] }
            let source = AccurateRipAudioOverlay(base: RipAudioSource(toc: toc, files: files, disc: discFiles, tools: model.tools), tracks: inMemory)
            report = try await AccurateRipVerifier(toc: toc, pressings: pressings)
                .verify(tracks.keys.sorted(), audio: source, offsetHint: offsetHint)
        }
        if save {
            model.saveRipChecks(tracks.map { RipCheck(trackId: $0.value.id, toc: toc, discTrack: $0.key, report: report) })
        }
        return report
    }

    /// AccurateRip's pressings of a disc (nil when it isn't listed), downloaded once per session.
    private func pressings(for toc: CDTOC) async throws -> [AccurateRipPressing]? {
        let disc = AccurateRipDisc(toc: toc)
        if let cached = pressingsCache[disc.url] { return cached }
        let pressings = try await AccurateRipClient().pressings(for: disc)
        pressingsCache[disc.url] = pressings
        return pressings
    }

    /// Repairs a misread track from several reads of it, with AccurateRip confirming the result
    /// (`AccurateRipVerifier.repair`); the tracks around it are read from the disc.
    func repair(toc: CDTOC, track number: Int, volume: AudioCDVolume, vote: ReadVote, offsetHint: Int?) async throws -> [UInt32]? {
        guard let pressings = try await pressings(for: toc) else { return nil }
        var discFiles: [Int: URL] = [:]
        for (index, cd) in toc.audioTracks.enumerated() { discFiles[index] = volume.trackFiles[cd.number] }
        let source = RipAudioSource(toc: toc, files: [:], disc: discFiles, tools: model.tools)
        return try await AccurateRipVerifier(toc: toc, pressings: pressings).repair(number, vote: vote, audio: source, offsetHint: offsetHint)
    }

    /// Checks an album from its files: per disc, against each disc it could have been ripped from (saved when ripped,
    /// or one MusicBrainz lists for its release with exactly its tracks' lengths), keeping the results of the one most
    /// of its tracks match. Discs whose tracks only start a few sectors later have the same lengths but are listed
    /// apart in AccurateRip, sometimes as a different pressing.
    func check(album: AlbumSummary) {
        let key = AlbumInfoStore.key(album)
        guard albumStates[key] != .checking else { return }
        albumStates[key] = .checking
        Task {
            do {
                var found = false
                let byDisc = Dictionary(grouping: model.tracks(of: album).filter(RipDiscMatcher.isCDAudio)) { $0.metadata.discNo ?? 1 }
                var listed: [String: [Int: [CDTOC]]] = [:]
                for (discNo, tracks) in byDisc.sorted(by: { $0.key < $1.key }) {
                    var best: (score: (Int, Int), toc: CDTOC, tracks: [Int: Track], report: AccurateRipReport?)?
                    for (toc, numbers) in try await discs(for: tracks, discNo: discNo, listed: &listed) {
                        found = true
                        let byNumber = Dictionary(tracks.compactMap { t in numbers[t.id].map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
                        let report = try await check(toc: toc, tracks: byNumber, save: false)
                        let score = Self.score(report)
                        if best.map({ score > $0.score }) ?? true { best = (score, toc, byNumber, report) }
                    }
                    if let best {
                        model.saveRipChecks(best.tracks.map { RipCheck(trackId: $0.value.id, toc: best.toc, discTrack: $0.key, report: best.report) })
                    }
                }
                albumStates[key] = found ? .done : .noDisc
            } catch {
                albumStates[key] = .failed(error.localizedDescription)
            }
        }
    }

    /// How well a check went: accurate tracks, then their total confidence; a disc AccurateRip doesn't list is worst.
    static func score(_ report: AccurateRipReport?) -> (Int, Int) {
        guard let report else { return (-1, -1) }
        var count = 0, confidence = 0
        for case .accurate(let c) in report.tracks.values {
            count += 1
            confidence += c
        }
        return (count, confidence)
    }

    /// The discs the tracks could have been ripped from: those saved with them, and those MusicBrainz lists for their
    /// release, when every track has its track's exact length.
    private func discs(for tracks: [Track], discNo: Int, listed: inout [String: [Int: [CDTOC]]]) async throws -> [(CDTOC, [Int64: Int])] {
        var tocs: [CDTOC] = []
        for toc in tracks.compactMap({ model.ripChecks[$0.id]?.toc }) where !tocs.contains(toc) { tocs.append(toc) }
        if let release = tracks.first(where: { $0.metadata.mbReleaseId != nil })?.metadata.mbReleaseId {
            do {
                if listed[release] == nil { listed[release] = try await model.musicBrainz.discTOCs(releaseId: release) }
            } catch {
                // Without MusicBrainz, the discs saved with the tracks are enough.
                if tocs.isEmpty { throw error }
            }
            for toc in listed[release]?[discNo] ?? [] where !tocs.contains(toc) { tocs.append(toc) }
        }
        return RipDiscMatcher.discs(for: tracks, among: tocs).map { ($0.toc, $0.discTracks) }
    }
}
