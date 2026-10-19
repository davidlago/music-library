import Foundation
import ImageIO
import MusicLibraryCore
import MusicLibraryGlance
import UIKit
import WidgetKit

/// Keeps the summary the widgets and the watch show (`Glance`) up to date: rebuilt off the main thread a moment after
/// the library, history, likes or ownership change, and just its Now Playing part when only the player changed. It's
/// written with the covers it shows to the app group's container (`GlanceStore.shared`), the widgets are reloaded
/// when it changed, and `onChange` passes it on to the watch. Each full build also writes the watch's shelf index
/// (`GlanceShelf`, every labeled CD and record) and hands it to `onShelfChange`; its covers aren't saved here, there
/// can be thousands: the watch asks for the few it shows (`coverFile`).
final class GlanceFeed {
    /// What the summary is made from, read on the main thread.
    struct Inputs: Sendable {
        var root: URL
        var tracks: [Track]
        var present: Set<Int64>
        var plays: [Play]
        var likedDates: [Int64: Date]
        var collection: MusicCollection
        var playTotals: [Int64: PlayTotal]
        var playing: Glance.Playing?
    }

    /// Without the app group (an unsigned build), the summary still goes to the watch, with covers kept in Caches.
    let store = GlanceStore.shared ?? GlanceStore(directory: URL.cachesDirectory.appendingPathComponent("Glance", isDirectory: true))
    var inputs: () -> Inputs? = { nil }
    var onChange: ((Glance) -> Void)?
    /// After each full build, with the shelf index (changed or not: the watch link sends it only when it differs).
    var onShelfChange: ((GlanceShelf) -> Void)?
    private(set) var current: Glance?
    /// The last shelf index and where its covers come from. Until the first build, the one written before (without
    /// its covers), if any.
    private(set) var shelf: Shelf?

    /// The watch's shelf index, and its covers' sources in the library at `root`.
    struct Shelf: Sendable {
        var index: GlanceShelf
        var covers: [String: GlanceCoverSource]
        var root: URL
    }

    private var pending: Task<Void, Never>?
    private var needsFull = false
    /// The last build: each one starts from the one before, so they're written in order.
    private var building: Task<Built?, Never>?

    private struct Built: Sendable {
        var glance: Glance
        var changed: Bool
        /// Made again in a full build, carried over from the last one otherwise.
        var shelf: Shelf?
    }

    init() {
        current = store.read()
        shelf = store.readShelf().map { Shelf(index: $0, covers: [:], root: URL.documentsDirectory) }
    }

    /// The file a cover of the summary or the shelf index is made from: the summary's own thumbnail when it has one,
    /// else the item's cover or album's cover.jpg in the library. Reads the disk: call it off the main thread.
    nonisolated static func coverFile(_ name: String, store: GlanceStore, shelf: Shelf?) -> URL? {
        if let url = store.coverURL(name), FileManager.default.fileExists(atPath: url.path) { return url }
        guard let shelf, let source = shelf.covers[name] else { return nil }
        return source.url(root: shelf.root)
    }

    /// Rebuilds the summary shortly; `full: false` when only the song playing (or its state) changed.
    func setNeedsUpdate(full: Bool = true) {
        needsFull = needsFull || full || current == nil
        pending?.cancel()
        pending = Task { [weak self] in
            // Changes come in bursts (a song ending records a play and starts the next): wait for them to settle.
            try? await Task.sleep(for: .milliseconds(full ? 600 : 250))
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    /// Writes the summary now (after a widget button or the watch changed the player): iOS reloads the widget as soon
    /// as its button's intent returns, so the summary has to be current by then.
    func updateNow() async {
        pending?.cancel()
        pending = nil
        await update()
    }

    private func update() async {
        guard let inputs = inputs() else { return }
        let full = needsFull
        needsFull = false
        let before = building, fallback = current, fallbackShelf = shelf, store = store
        let currency = Locale.current.currency?.identifier ?? "USD"
        let task = Task.detached(priority: .utility) { () -> Built? in
            let last = await before?.value
            let previous = last?.glance ?? fallback, previousShelf = last?.shelf ?? fallbackShelf
            guard let glance = Self.make(inputs, full: full, previous: previous, store: store, currency: currency) else { return nil }
            let shelf = full ? Self.makeShelf(inputs, previous: previousShelf, store: store) : previousShelf
            return Built(glance: glance, changed: previous.map { !glance.sameContent(as: $0) } ?? true, shelf: shelf)
        }
        building = task
        guard let built = await task.value else { return }
        current = built.glance
        shelf = built.shelf
        if full, let shelf = built.shelf { onShelfChange?(shelf.index) }
        guard built.changed else { return }
        if full {
            WidgetCenter.shared.reloadAllTimelines()
        } else {
            WidgetCenter.shared.reloadTimelines(ofKind: GlanceWidgetKind.nowPlaying.rawValue)
        }
        onChange?(built.glance)
    }

    /// Builds (or patches) the summary, saves the thumbnails it needs and writes it. Nil if nothing could be built.
    nonisolated private static func make(_ inputs: Inputs, full: Bool, previous: Glance?, store: GlanceStore, currency: String) -> Glance? {
        var glance: Glance
        var covers: [String: GlanceCoverSource]
        if full || previous == nil {
            (glance, covers) = Glance.build(tracks: inputs.tracks, present: inputs.present, plays: inputs.plays,
                                            likedDates: inputs.likedDates, collection: inputs.collection,
                                            playTotals: inputs.playTotals, playing: inputs.playing, currencyCode: currency)
        } else {
            glance = previous!
            let now = Date()
            let (nowPlaying, nowCovers) = Glance.nowPlaying(inputs.playing, present: inputs.present, likedDates: inputs.likedDates, now: now)
            glance.nowPlaying = nowPlaying
            glance.generatedAt = now
            covers = nowCovers.mapValues(GlanceCoverSource.track)
        }
        // An item's own cover gets a new file name on each change, so a name already saved is still current.
        for (name, source) in covers where !store.hasCover(name) {
            guard let url = source.url(root: inputs.root), let data = thumbnail(url) else { continue }
            try? store.saveCover(data, name: name)
        }
        // Covers of albums no longer shown go, except right after a Now Playing patch (the rest still shows them).
        if full { store.pruneCovers(keeping: glance.coverNames) }
        try? store.write(glance)
        return glance
    }

    /// The shelf index of the collection, written to the store when its entries changed.
    nonisolated private static func makeShelf(_ inputs: Inputs, previous: Shelf?, store: GlanceStore) -> Shelf {
        let (index, covers) = Glance.shelf(collection: inputs.collection)
        let shelf = Shelf(index: index, covers: covers, root: inputs.root)
        if index.contentHash != previous?.index.contentHash || !FileManager.default.fileExists(atPath: store.shelfURL.path) {
            try? store.writeShelf(index)
        }
        return shelf
    }

    /// A small JPEG of an image (an album's cover.jpg; widgets have little memory), also used for the watch's covers.
    nonisolated static func thumbnail(_ url: URL, maxPixel: Int = 320, quality: Double = 0.8) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }
}
