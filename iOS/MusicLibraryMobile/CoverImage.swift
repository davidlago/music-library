import ImageIO
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI
import UIKit

/// An album's `cover.jpg` (or a collection item's own cover), decoded off the main thread at the size it's shown.
struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    /// What you own of it (`CopyMark`): your label in the top-left corner and badges in the bottom-right
    /// (`CoverCopyMark`). In a `JewelCase` or `RecordSleeve`, give it to the case instead.
    var mark: CopyMark?
    /// Nil for the usual rounding; 0 for a booklet in a `JewelCase`.
    var cornerRadius: CGFloat?
    /// Drawn instead of the music note when there's no cover: a trackless item's title.
    var title: String?
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    init(url: URL?, size: CGFloat, mark: CopyMark? = nil, cornerRadius: CGFloat? = nil, title: String? = nil) {
        self.url = url
        self.size = size
        self.mark = mark
        self.cornerRadius = cornerRadius
        self.title = title
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let title, !title.isEmpty, size >= 60 {
                Text(title)
                    .font(.system(size: max(9, size * 0.09), weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .padding(size * 0.1)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.secondary)
            }
            if let mark { CoverCopyMark(mark: mark, size: size) }
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
