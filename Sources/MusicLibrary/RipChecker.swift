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
    /// the drive: tracks that weren't ripped are read from it at their edges, for the drive's offset. `files`
    /// replaces a track's library file (a fresh rip being checked before it replaces the file).
    func check(toc: CDTOC, tracks: [Int: Track], volume: AudioCDVolume? = nil, files override: [Int: URL] = [:],
               offsetHint: Int? = nil, save: Bool = true) async throws -> AccurateRipReport? {
        let disc = AccurateRipDisc(toc: toc)
        let pressings: [AccurateRipPressing]?
        if let cached = pressingsCache[disc.url] {
            pressings = cached
        } else {
            pressings = try await AccurateRipClient().pressings(for: disc)
            pressingsCache[disc.url] = pressings
        }
        var report: AccurateRipReport?
        if let pressings {
            var files: [Int: URL] = [:]
            var discFiles: [Int: URL] = [:]
            for (index, cd) in toc.audioTracks.enumerated() {
                if let url = override[cd.number] {
                    files[index] = url
                } else if let t = tracks[cd.number], RipDiscMatcher.isCDAudio(t), let url = t.resolvedFileURL(root: model.libraryRoot) {
                    files[index] = url
                }
                if let url = volume?.trackFiles[cd.number] { discFiles[index] = url }
            }
            let source = RipAudioSource(toc: toc, files: files, disc: discFiles, tools: model.tools)
            report = try await AccurateRipVerifier(toc: toc, pressings: pressings)
                .verify(tracks.keys.sorted(), audio: source, offsetHint: offsetHint)
        }
        if save {
            model.saveRipChecks(tracks.map { RipCheck(trackId: $0.value.id, toc: toc, discTrack: $0.key, report: report) })
        }
        return report
    }

    /// Checks an album from its files: per disc, against the disc it was ripped from (saved when ripped, or found
    /// among the discs MusicBrainz lists for its release).
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
                    guard let (toc, numbers) = try await disc(for: tracks, discNo: discNo, listed: &listed) else { continue }
                    found = true
                    let byNumber = Dictionary(tracks.compactMap { t in numbers[t.id].map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
                    _ = try await check(toc: toc, tracks: byNumber)
                }
                albumStates[key] = found ? .done : .noDisc
            } catch {
                albumStates[key] = .failed(error.localizedDescription)
            }
        }
    }

    private func disc(for tracks: [Track], discNo: Int, listed: inout [String: [Int: [CDTOC]]]) async throws -> (CDTOC, [Int64: Int])? {
        // The disc saved when the tracks were ripped, when they all share one.
        let saved = tracks.compactMap { model.ripChecks[$0.id] }
        if saved.count == tracks.count, let toc = saved.first?.toc, saved.allSatisfy({ $0.toc == toc }) {
            return (toc, Dictionary(uniqueKeysWithValues: saved.map { ($0.trackId, $0.discTrack) }))
        }
        guard let release = tracks.first(where: { $0.metadata.mbReleaseId != nil })?.metadata.mbReleaseId else { return nil }
        if listed[release] == nil { listed[release] = try await model.musicBrainz.discTOCs(releaseId: release) }
        return RipDiscMatcher.disc(for: tracks, among: listed[release]?[discNo] ?? []).map { ($0.toc, $0.discTracks) }
    }
}
