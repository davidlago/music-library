import AppKit
import CryptoKit
import Foundation
import MusicLibraryCore

/// Artist photos, bios and links, fetched in the background and cached in the library
/// (database rows plus photos in `<library>/Artist Images`). A photo the user chose (`artist_photos`) wins over the
/// downloaded one, and updating the info never replaces it.
@MainActor @Observable
final class ArtistInfoStore {
    private enum Keys { static let autoSync = "artistInfoAutoSync" }

    /// Refresh info older than this; artists with nothing online are retried sooner.
    static let maxAge: TimeInterval = 90 * 86_400
    static let notFoundRetry: TimeInterval = 14 * 86_400

    var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Keys.autoSync)
            if autoSync { onAutoSyncEnabled?() }
        }
    }

    private(set) var infos: [String: ArtistInfo] = [:]
    /// Downloaded photos, by artist key.
    private(set) var imageFiles: [String: String] = [:]
    /// Photos the user chose, by artist key.
    private(set) var chosenPhotos: [String: ArtistPhotoChoice] = [:]
    /// The artist being fetched right now.
    private(set) var current: String?
    private(set) var remaining = 0
    private(set) var lastError: String?

    @ObservationIgnored var onAutoSyncEnabled: (() -> Void)?
    @ObservationIgnored private var queue: [(name: String, ids: [String])] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var database: Database?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private let images = NSCache<NSString, NSImage>()

    init() {
        let d = UserDefaults.standard
        autoSync = d.object(forKey: Keys.autoSync) == nil ? true : d.bool(forKey: Keys.autoSync)
    }

    static func key(_ name: String) -> String { name.lowercased() }

    var isSyncing: Bool { current != nil }

    func info(for name: String) -> ArtistInfo? { infos[Self.key(name)] }

    func isFetching(_ name: String) -> Bool { current == Self.key(name) || queue.contains { Self.key($0.name) == Self.key(name) } }

    var imageDirectory: URL? { root?.appendingPathComponent("Artist Images", isDirectory: true) }

    /// The photo shown for an artist: the chosen one, else the downloaded one. Changes whenever the photo does.
    func imageFile(for name: String) -> String? {
        let key = Self.key(name)
        return chosenPhotos[key]?.file ?? imageFiles[key]
    }

    func hasChosenPhoto(_ name: String) -> Bool { chosenPhotos[Self.key(name)] != nil }

    /// Who to credit for the photo shown ("Photo: …"); nil for the user's own images.
    func photoCredit(for name: String) -> (label: String, url: URL?)? {
        if let chosen = chosenPhotos[Self.key(name)] {
            return chosen.credit.map { ($0, chosen.creditURL) }
        }
        return info(for: name)?.imageCreditURL.map { ("Wikimedia Commons", $0) }
    }

    func imageURL(for name: String) -> URL? {
        // File names come from library.sqlite, which may have been made elsewhere.
        guard let file = imageFile(for: name), ArtistPhotoChoice.isSafeFileName(file) else { return nil }
        return imageDirectory?.appendingPathComponent(file)
    }

    /// Loads (and caches) an artist photo off the main thread.
    func image(for name: String) async -> NSImage? {
        guard let url = imageURL(for: name) else { return nil }
        if let cached = images.object(forKey: url.path as NSString) { return cached }
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url.path as NSString)
        return image
    }

    // MARK: Library

    func open(database: Database?, root: URL) {
        worker?.cancel()
        worker = nil
        queue = []
        current = nil
        remaining = 0
        self.database = database
        self.root = root
        images.removeAllObjects()
        let cached = (try? database?.artistInfos()) ?? [:]
        infos = cached.mapValues(\.info)
        imageFiles = cached.compactMapValues(\.imageFile)
        chosenPhotos = (try? database?.artistPhotos()) ?? [:]
    }

    // MARK: Chosen photos

    /// Makes `jpeg` the artist's photo. Saved under a new name each time, so views showing the old one reload.
    func setPhoto(_ jpeg: Data, for name: String, credit: String?, creditURL: URL?) throws {
        guard let database, let dir = imageDirectory else { throw CocoaError(.fileNoSuchFile) }
        let key = Self.key(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(Self.fileStem(name))-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        let url = dir.appendingPathComponent(file)
        try jpeg.write(to: url, options: .atomic)
        let choice = ArtistPhotoChoice(file: file, credit: credit, creditURL: creditURL?.webLink)
        do {
            try database.saveArtistPhoto(key: key, choice)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let old = chosenPhotos[key]?.file
        chosenPhotos[key] = choice
        if let old { removeImageFile(old) }
    }

    /// Goes back to the downloaded photo.
    func removeChosenPhoto(for name: String) throws {
        let key = Self.key(name)
        guard let database, let old = chosenPhotos[key]?.file else { return }
        try database.saveArtistPhoto(key: key, nil)
        chosenPhotos[key] = nil
        removeImageFile(old)
    }

    private func removeImageFile(_ file: String) {
        guard ArtistPhotoChoice.isSafeFileName(file), let url = imageDirectory?.appendingPathComponent(file) else { return }
        images.removeObject(forKey: url.path as NSString)
        try? FileManager.default.removeItem(at: url)
    }

    func needsSync(_ name: String, now: Date = Date()) -> Bool {
        guard let info = infos[Self.key(name)] else { return true }
        let age = now.timeIntervalSince(info.fetchedAt)
        return info.notFound ? age > Self.notFoundRetry : age > Self.maxAge
    }

    /// Queues artists without (fresh) info.
    func syncMissing(_ artists: [(name: String, ids: [String])], fetcher: InfoFetcher) {
        enqueue(artists.filter { !$0.name.isEmpty && needsSync($0.name) }, fetcher: fetcher)
    }

    /// Queues artists regardless of what's cached.
    func refresh(_ artists: [(name: String, ids: [String])], fetcher: InfoFetcher) {
        enqueue(artists.filter { !$0.name.isEmpty }, fetcher: fetcher)
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        queue = []
        current = nil
        remaining = 0
    }

    private func enqueue(_ artists: [(name: String, ids: [String])], fetcher: InfoFetcher) {
        for a in artists where !isFetching(a.name) { queue.append(a) }
        remaining = queue.count + (current == nil ? 0 : 1)
        guard worker == nil, !queue.isEmpty else { return }
        lastError = nil
        worker = Task { [weak self] in
            await self?.drain(fetcher)
        }
    }

    private func drain(_ fetcher: InfoFetcher) async {
        while !Task.isCancelled, !queue.isEmpty {
            let next = queue.removeFirst()
            current = Self.key(next.name)
            remaining = queue.count + 1
            do {
                var info = try await fetcher.fetch(name: next.name, taggedIds: next.ids)
                var file: String?
                if let url = info.imageURL, let data = try? await fetcher.image(url), NSImage(data: data) != nil {
                    file = try? saveImage(data, for: next.name)
                } else if info.imageURL != nil {
                    info.imageURL = nil
                }
                guard !Task.isCancelled, let database else { break }
                try? database.saveArtistInfo(key: Self.key(next.name), info, imageFile: file ?? imageFiles[Self.key(next.name)])
                infos[Self.key(next.name)] = info
                if let file {
                    images.removeAllObjects()
                    imageFiles[Self.key(next.name)] = file
                }
            } catch {
                // Offline or a service is down: stop here and try again on the next sync.
                lastError = "Couldn't update artist info: \(error.localizedDescription)"
                queue = []
            }
        }
        current = nil
        remaining = 0
        worker = nil
    }

    private func saveImage(_ data: Data, for name: String) throws -> String {
        guard let dir = imageDirectory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(Self.fileStem(name)).jpg"
        try data.write(to: dir.appendingPathComponent(file), options: .atomic)
        return file
    }

    private static func fileStem(_ name: String) -> String {
        SHA256.hash(data: Data(key(name).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
