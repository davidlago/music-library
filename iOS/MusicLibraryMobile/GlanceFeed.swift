import Foundation
import ImageIO
import MusicLibraryCore
import MusicLibraryGlance
import UIKit
import WidgetKit

/// Keeps the summary the widgets and the watch show (`Glance`) up to date: rebuilt off the main thread a moment after
/// the library, history, likes or ownership change, and just its Now Playing part when only the player changed. It's
/// written with the covers it shows to the app group's container (`GlanceStore.shared`), the widgets are reloaded
/// when it changed, and `onChange` passes it on to the watch.
final class GlanceFeed {
    /// What the summary is made from, read on the main thread.
    struct Inputs: Sendable {
        var root: URL
        var tracks: [Track]
        var present: Set<Int64>
        var plays: [Play]
        var likedDates: [Int64: Date]
        var purchases: [String: AlbumPurchase]
        var playTotals: [Int64: PlayTotal]
        var playing: Glance.Playing?
    }

    /// Without the app group (an unsigned build), the summary still goes to the watch, with covers kept in Caches.
    let store = GlanceStore.shared ?? GlanceStore(directory: URL.cachesDirectory.appendingPathComponent("Glance", isDirectory: true))
    var inputs: () -> Inputs? = { nil }
    var onChange: ((Glance) -> Void)?
    private(set) var current: Glance?

    private var pending: Task<Void, Never>?
    private var needsFull = false
    /// The last build: each one starts from the one before, so they're written in order.
    private var building: Task<Built?, Never>?

    private struct Built: Sendable {
        var glance: Glance
        var changed: Bool
    }

    init() {
        current = store.read()
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
        let before = building, fallback = current, store = store
        let currency = Locale.current.currency?.identifier ?? "USD"
        let task = Task.detached(priority: .utility) { () -> Built? in
            let previous = await before?.value?.glance ?? fallback
            guard let glance = Self.make(inputs, full: full, previous: previous, store: store, currency: currency) else { return nil }
            return Built(glance: glance, changed: previous.map { !glance.sameContent(as: $0) } ?? true)
        }
        building = task
        guard let built = await task.value else { return }
        current = built.glance
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
        var covers: [String: Track]
        if full || previous == nil {
            (glance, covers) = Glance.build(tracks: inputs.tracks, present: inputs.present, plays: inputs.plays,
                                            likedDates: inputs.likedDates, purchases: inputs.purchases,
                                            playTotals: inputs.playTotals, playing: inputs.playing, currencyCode: currency)
        } else {
            glance = previous!
            let now = Date()
            let (nowPlaying, nowCovers) = Glance.nowPlaying(inputs.playing, present: inputs.present, likedDates: inputs.likedDates, now: now)
            glance.nowPlaying = nowPlaying
            glance.generatedAt = now
            covers = nowCovers
        }
        for (name, track) in covers where !store.hasCover(name) {
            guard let source = track.coverURL(root: inputs.root), let data = thumbnail(source) else { continue }
            try? store.saveCover(data, name: name)
        }
        // Covers of albums no longer shown go, except right after a Now Playing patch (the rest still shows them).
        if full { store.pruneCovers(keeping: glance.coverNames) }
        try? store.write(glance)
        return glance
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
