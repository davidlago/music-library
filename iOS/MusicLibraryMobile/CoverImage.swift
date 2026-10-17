import ImageIO
import SwiftUI
import UIKit

/// An album's `cover.jpg`, decoded off the main thread at the size it's shown.
struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    /// Your label number for the album (`model.purchase(for:)?.labelNumber`), drawn as a sticker in the corner.
    var labelNumber: Int?
    var labelScale: CGFloat = 1
    /// Nil for the usual rounding; 0 for a booklet in a `JewelCase`.
    var cornerRadius: CGFloat?
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
            if let labelNumber { LabelSticker(number: labelNumber, size: size, scale: labelScale) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? (size >= 120 ? 10 : 5)))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverLoader.image(at: url, maxPixel: size * scale)
        }
    }
}

/// The white sticker with your label number, in the top-right corner of a cover: like the one on the CD's case.
struct LabelSticker: View {
    let number: Int
    /// The cover's size.
    let size: CGFloat
    /// Smaller on the big covers of album pages.
    var scale: CGFloat = 1

    var body: some View {
        let font = max(9, size * 0.075 * scale)
        Text(String(number))
            .font(.system(size: font, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(white: 0.1))
            .padding(.horizontal, font * 0.45).padding(.vertical, font * 0.15)
            .background(RoundedRectangle(cornerRadius: font * 0.25).fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .padding(max(4, size * 0.04))
            .frame(width: size, height: size, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityLabel("Label \(number)")
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
