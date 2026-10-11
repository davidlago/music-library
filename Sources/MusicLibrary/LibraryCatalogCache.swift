import CryptoKit
import Foundation
import MusicLibraryCore

/// What the catalog pages remember between launches, in `~/Library/Caches/MusicLibrary/Catalog`: cover images
/// and work pages (which hardly change) for good, and results pages for a while (they carry availability, which
/// does). The MusicBrainz details live in the library database instead (`catalog_info`).
struct LibraryCatalogCache: Sendable {
    let directory: URL

    static let shared = LibraryCatalogCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicLibrary/Catalog", isDirectory: true))

    /// A results page as cached, with when it was fetched.
    struct Page: Codable {
        var items: [CatalogItem]
        var total: Int
        var page: Int
        var searchId: String?
        var fetchedAt: Date

        var catalogPage: CatalogPage { CatalogPage(items: items, total: total, page: page, searchId: searchId) }
    }

    static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ kind: String, _ key: String, _ ext: String) -> URL {
        directory.appendingPathComponent(kind, isDirectory: true).appendingPathComponent(Self.fileName(key) + "." + ext)
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func age(_ url: URL) -> TimeInterval? {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return Date().timeIntervalSince(date)
    }

    // MARK: Covers

    func cover(_ key: String) -> Data? { try? Data(contentsOf: url("covers", key, "img")) }
    func saveCover(_ data: Data, key: String) { write(data, to: url("covers", key, "img")) }

    // MARK: Work pages

    func work(_ workId: String, maxAge: TimeInterval = 30 * 86_400) -> CatalogWorkDetails? {
        let file = url("works", workId, "json")
        guard let age = age(file), age < maxAge, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(CatalogWorkDetails.self, from: data)
    }

    func saveWork(_ work: CatalogWorkDetails, workId: String) {
        if let data = try? JSONEncoder().encode(work) { write(data, to: url("works", workId, "json")) }
    }

    // MARK: Results pages

    func page(_ path: String, maxAge: TimeInterval) -> Page? {
        guard let data = try? Data(contentsOf: url("pages", path, "json")),
              let page = try? JSONDecoder().decode(Page.self, from: data),
              Date().timeIntervalSince(page.fetchedAt) < maxAge else { return nil }
        return page
    }

    func savePage(_ page: CatalogPage, path: String) {
        let cached = Page(items: page.items, total: page.total, page: page.page, searchId: page.searchId, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(cached) { write(data, to: url("pages", path, "json")) }
    }

    // MARK: Interrupted downloads

    /// How far a library's download got, so it can pick up there after a pause or a relaunch.
    struct ScanState: Codable {
        var library: String
        var nextPage: Int
        var seen: [String]
        var total: Int
        var firstDownload: Bool
        var startedAt: Date
    }

    func scanState(_ library: String) -> ScanState? {
        guard let data = try? Data(contentsOf: url("scans", library, "json")) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    func saveScanState(_ state: ScanState) {
        if let data = try? JSONEncoder().encode(state) { write(data, to: url("scans", state.library, "json")) }
    }

    func clearScanState(_ library: String) {
        try? FileManager.default.removeItem(at: url("scans", library, "json"))
    }

    /// Drops cached results pages (Reload), keeping covers and work pages.
    func clearPages() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pages", isDirectory: true))
    }
}
