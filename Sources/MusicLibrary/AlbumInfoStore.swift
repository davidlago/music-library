import Foundation
import MusicLibraryCore

/// Album descriptions, ratings, links and track lists, fetched once and cached in the library database
/// (`album_info`). Opening an album fetches its info first; the rest are filled in in the background.
@MainActor @Observable
final class AlbumInfoStore {
    struct Request: Sendable {
        var key: String
        var title: String
        var artist: String
        var releaseGroupId: String?
        var releaseId: String?
        /// Used for the track list when there's no MusicBrainz release.
        var discogsReleaseId: Int?
    }

    private(set) var infos: [String: AlbumInfo] = [:]
    private(set) var current: String?
    private(set) var remaining = 0
    private(set) var lastError: String?

    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var database: Database?
    /// Called once a batch of fetches is done and saved something, so what's built from the info (the collection's
    /// index, Music DNA's people on CDs and records with no digital copy) is rebuilt.
    @ObservationIgnored var onFetched: (() -> Void)?

    static func key(_ album: AlbumSummary) -> String { SearchIndex.albumKey(album: album.album, artist: album.artist) }

    func info(for album: AlbumSummary) -> AlbumInfo? { infos[Self.key(album)] }

    func isFetching(_ album: AlbumSummary) -> Bool {
        let key = Self.key(album)
        return current == key || queue.contains { $0.key == key }
    }

    func open(database: Database?) {
        cancel()
        self.database = database
        infos = (try? database?.albumInfos()) ?? [:]
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        queue = []
        current = nil
        remaining = 0
    }

    func needsSync(_ key: String, now: Date = Date()) -> Bool {
        guard let info = infos[key] else { return true }
        let age = now.timeIntervalSince(info.fetchedAt)
        return info.notFound ? age > ArtistInfoStore.notFoundRetry : age > ArtistInfoStore.maxAge
    }

    /// Queues albums without (fresh) info, after anything already queued.
    func syncMissing(_ requests: [Request], fetcher: InfoFetcher) {
        enqueue(requests.filter { needsSync($0.key) }, first: false, fetcher: fetcher)
    }

    /// Fetches these next, regardless of the cache.
    func refresh(_ requests: [Request], fetcher: InfoFetcher) {
        enqueue(requests, first: true, fetcher: fetcher)
    }

    /// Fetches an album the user is looking at, ahead of the background queue, if it isn't cached, or if what's
    /// cached has no track list although the request now names a release (a copy picked on MusicBrainz or Discogs
    /// after a search by title found nothing).
    func ensure(_ request: Request, fetcher: InfoFetcher, now: Date = Date()) {
        guard needsSync(request.key) || lacksTrackList(request, now: now) else { return }
        enqueue([request], first: true, fetcher: fetcher)
    }

    /// Cached without a track list for more than a few minutes, while the request has a release to read it from.
    func lacksTrackList(_ request: Request, now: Date = Date()) -> Bool {
        guard let info = infos[request.key], info.tracklist.isEmpty, request.releaseId != nil || request.discogsReleaseId != nil
        else { return false }
        return now.timeIntervalSince(info.fetchedAt) > 600
    }

    private func enqueue(_ requests: [Request], first: Bool, fetcher: InfoFetcher) {
        let keys = Set(requests.map(\.key))
        queue.removeAll { keys.contains($0.key) }
        let fresh = requests.filter { $0.key != current }
        queue = first ? fresh + queue : queue + fresh
        remaining = queue.count + (current == nil ? 0 : 1)
        guard worker == nil, !queue.isEmpty else { return }
        lastError = nil
        worker = Task { [weak self] in await self?.drain(fetcher) }
    }

    private func drain(_ fetcher: InfoFetcher) async {
        var saved = false
        defer { if saved { onFetched?() } }
        while !Task.isCancelled, !queue.isEmpty {
            let next = queue.removeFirst()
            current = next.key
            remaining = queue.count + 1
            do {
                let info = try await fetcher.fetchAlbum(title: next.title, artist: next.artist,
                                                        releaseGroupId: next.releaseGroupId, releaseId: next.releaseId,
                                                        discogsReleaseId: next.discogsReleaseId)
                guard !Task.isCancelled, let database else { break }
                try? database.saveAlbumInfo(key: next.key, info)
                infos[next.key] = info
                saved = true
            } catch {
                lastError = "Couldn't update album info: \(error.localizedDescription)"
                queue = []
            }
        }
        current = nil
        remaining = 0
        worker = nil
    }
}
