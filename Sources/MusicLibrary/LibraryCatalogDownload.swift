import Foundation
import MusicLibraryCore

/// The downloaded catalog: every music CD the chosen libraries own, scanned page by page from the catalog (newest
/// first) and kept in the library database, then looked up on MusicBrainz in the background. Searches of it run
/// locally, in the app's query language. Availability comes from the last scan, which is repeated when it's
/// more than half a day old; the album page always checks copies live.
extension LibraryCatalogStore {
    static let downloadMaxAge: TimeInterval = 12 * 3600

    var hasDownloads: Bool { !downloadLibraries.isEmpty }

    /// Showing the downloaded catalog rather than searching the website live.
    var showsDownloaded: Bool { hasDownloads && !liveMode && (!records.isEmpty || downloadProgress != nil || downloadError != nil) }

    func isStale(_ library: String, now: Date = Date()) -> Bool {
        guard let date = downloadDates[library] else { return true }
        return now.timeIntervalSince(date) > Self.downloadMaxAge
    }

    var lastDownload: Date? { downloadLibraries.compactMap { downloadDates[$0] }.min() }

    /// Downloaded titles that have MusicBrainz details.
    var detailedCount: Int { records.keys.filter { details[$0]?.isMatched == true }.count }

    /// Downloads (or refreshes) the catalogs that are stale, or all of them with `force`, then queues lookups
    /// for titles without details.
    func downloadCatalogs(force: Bool = false) {
        guard downloadProgress == nil, siteURL != nil else { return }
        let libraries = downloadLibraries.filter { force || isStale($0) }
        guard !libraries.isEmpty else { queueDownloadLookups(); return }
        downloadError = nil
        downloadProgress = DownloadProgress(library: libraries[0], page: 0, pages: nil)
        Task {
            for library in libraries {
                do {
                    try await download(library)
                } catch {
                    downloadError = "Couldn't download \(library)'s catalog: \(error.localizedDescription)"
                    break
                }
            }
            downloadProgress = nil
            rebuildIndex()
            queueDownloadLookups()
        }
    }

    /// Scans one library's CDs page by page (newest first), saving each page as it comes so the search fills
    /// in and an interrupted download resumes where it stopped. Rate limits are waited out, not given up on.
    private func download(_ library: String) async throws {
        let query = CatalogQuery(libraries: [library], sort: .recentlyAdded)
        var state = cache.scanState(library).flatMap { Date().timeIntervalSince($0.startedAt) < 2 * 86_400 ? $0 : nil }
            ?? LibraryCatalogCache.ScanState(library: library, nextPage: 1, seen: [], total: 0,
                                             firstDownload: downloadDates[library] == nil, startedAt: Date())
        var scan = CatalogScan(nextPage: state.nextPage, seen: Set(state.seen), total: state.total)
        downloadProgress = DownloadProgress(library: library, page: scan.nextPage - 1, pages: scan.total > 0 ? scan.pageCount : nil)
        var limited = 0, suspect = 0
        while !scan.finished {
            let page = scan.nextPage
            let html: String
            do {
                html = String(decoding: try await client.get(query.path(page: page), priority: .background), as: UTF8.self)
                limited = 0
            } catch CatalogError.rateLimited(let until) {
                limited += 1
                guard limited <= 8 else { throw CatalogError.rateLimited(until) }
                downloadProgress?.pausedUntil = until
                try await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow) + 2))
                downloadProgress?.pausedUntil = nil
                continue
            }
            let result = try await Task.detached { try CatalogParser.parseResults(html, page: page) }.value
            if scan.add(result) == .suspect {
                // An empty or shrunken page mid-scan is the site struggling, not the catalog ending: wait and
                // read it again, then give up (the scan resumes from here next time) rather than prune.
                suspect += 1
                guard suspect <= 3 else { throw CatalogError.badResponse("page \(page) came back incomplete") }
                let until = Date().addingTimeInterval(Double(30 * suspect))
                downloadProgress?.pausedUntil = until
                try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
                downloadProgress?.pausedUntil = nil
                continue
            }
            suspect = 0
            let changed = CatalogRecord.upsert(records, page: result.items, library: library,
                                               startRank: (page - 1) * CatalogPage.pageSize, firstDownload: state.firstDownload)
            try database?.saveCatalogRecords(changed)
            for record in changed { records[record.id] = record }
            state.total = scan.total
            state.nextPage = scan.nextPage
            state.seen = Array(scan.seen)
            cache.saveScanState(state)
            downloadProgress = DownloadProgress(library: library, page: page, pages: scan.pageCount)
            if page % 10 == 0 { scheduleIndexRebuild() }
        }
        // Only drop titles when the scan really saw (nearly) everything the catalog has (`CatalogScan.pruning`).
        if let pruned = scan.pruning(records, library: library) {
            try database?.saveCatalogRecords(pruned.changed, removing: pruned.removed)
            for record in pruned.changed { records[record.id] = record }
            for id in pruned.removed { records[id] = nil }
        }
        cache.clearScanState(library)
        downloadDates[library] = Date()
    }

    /// Queues lookups for downloaded titles without (fresh) details, newest first.
    func queueDownloadLookups() {
        guard autoLookup else { return }
        let queued = Set(downloadQueue.map(\.id))
        let missing = records.values.filter { !queued.contains($0.id) && needsLookup($0.id) }
            .sorted { $0.addedRank < $1.addedRank }.map(\.item)
        guard !missing.isEmpty else { return }
        downloadQueue += missing
        startLookups()
    }

    /// Forgets a library's downloaded titles (those no other downloaded library owns).
    func removeDownload(_ library: String) {
        downloadLibraries.removeAll { $0 == library }
        downloadDates[library] = nil
        var changed: [CatalogRecord] = []
        var removed: [String] = []
        for (id, record) in records where record.libraries.contains(library) {
            var r = record
            r.libraries.removeAll { $0 == library }
            if r.libraries.isEmpty { removed.append(id); records[id] = nil } else { changed.append(r); records[id] = r }
        }
        try? database?.saveCatalogRecords(changed, removing: removed)
        downloadQueue.removeAll { records[$0.id] == nil }
        rebuildIndex()
    }

    // MARK: Index

    func rebuildIndex() {
        indexGeneration += 1
        let generation = indexGeneration
        let all = Array(records.values)
        let known = details
        Task.detached(priority: .userInitiated) {
            let index = CatalogIndex(records: all, details: known)
            await MainActor.run { [weak self] in
                guard let self, self.indexGeneration == generation else { return }
                self.index = index
                self.refreshOwned()
            }
        }
    }

    /// Rebuilds a few seconds from now, so a run of lookups rebuilds once.
    func scheduleIndexRebuild() {
        guard indexRebuild == nil else { return }
        indexRebuild = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.indexRebuild = nil
            self?.rebuildIndex()
        }
    }

    func refreshOwned() {
        ownedIds = Set(records.values.filter { ownership.album(for: $0.item, details: details[$0.id]) != nil }.map(\.id))
        var media: [String: Set<String>] = [:]
        for record in records.values {
            let copies = collectionCopies(record.item)
            if !copies.isEmpty { media[record.id] = Set(copies.map(\.medium.rawValue)) }
        }
        collectionMedia = media
        runLocalSearch()
    }

    // MARK: Searching

    var localQuery: CatalogSearchQuery {
        var query = CatalogSearchQuery.parse(localText)
        switch localAvailability {
        case .any: break
        case .available: query.filters.append(.init(kind: .flag(.available), negated: false))
        case .out: query.filters.append(.init(kind: .flag(.out), negated: false))
        }
        switch localOwnership {
        case .all: break
        case .owned: query.filters.append(.init(kind: .flag(.owned), negated: false))
        case .notOwned: query.filters.append(.init(kind: .flag(.owned), negated: true))
        }
        if localOnList { query.filters.append(.init(kind: .flag(.onList), negated: false)) }
        return query
    }

    func runLocalSearch() {
        let context = CatalogSearchContext(owned: ownedIds, onList: Set(listEntries.map(\.item.id)), siteLibrary: siteLibrary,
                                           collection: collectionMedia)
        localResult = index.search(localQuery, libraries: localLibraries.isEmpty ? nil : Set(localLibraries), context: context, sort: localSort)
    }

    /// Adds a filter to the search text (from a genre or decade chip, or the filter help).
    func addToLocalSearch(_ token: String) {
        let text = localText.trimmingCharacters(in: .whitespaces)
        guard !text.lowercased().contains(token.lowercased()) else { return }
        localText = text.isEmpty ? token : "\(text) \(token)"
    }
}
