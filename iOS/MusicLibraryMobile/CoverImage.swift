import ImageIO
import SwiftUI
import UIKit

/// An album's `cover.jpg`, decoded off the main thread at the size it's shown.
struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    /// Draws the Owned badge in the corner (`model.purchase(for:) != nil`).
    var owned = false
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.secondary)
            }
            if owned { OwnedBadge(size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size >= 120 ? 10 : 5))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverLoader.image(at: url, maxPixel: size * scale)
        }
    }
}

/// A small disc in the top-right corner of an owned album's cover.
struct OwnedBadge: View {
    let size: CGFloat

    var body: some View {
        let diameter = max(14, size * 0.13)
        Image(systemName: "opticaldisc.fill")
            .font(.system(size: diameter * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .padding(max(4, size * 0.04))
            .frame(width: size, height: size, alignment: .topTrailing)
            .allowsHitTesting(false)
    }
}

nonisolated enum CoverLoader {
    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) { thumbnail(url, maxPixel: maxPixel) }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func thumbnail(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
