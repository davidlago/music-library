import ImageIO
import MusicLibraryCore
import SwiftUI
import UIKit

/// An album's `cover.jpg`, decoded off the main thread at the size it's shown.
struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    /// How you got the album (`OwnershipMark`): your label in the top-left corner or a round badge (`CoverOwnershipMark`).
    /// In a `JewelCase`, give it to the case instead, which puts the label on the hinge.
    var ownership: OwnershipMark?
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
            if let ownership { CoverOwnershipMark(mark: ownership, size: size) }
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

/// The white sticker with your label number, like the one on the CD's case: tall, across the top of the hinge
/// (`JewelCase(ownership:)`), or in the top-left corner of a cover shown without its case. The number runs up the
/// sticker, read from bottom to top.
struct LabelSticker: View {
    let number: Int
    /// The sticker's width; it's half again as tall, and taller when the number doesn't fit.
    let width: CGFloat

    var body: some View {
        let font = max(9, width * 0.6)
        let text = String(number)
        // Monospaced digits are about 0.6 em wide.
        let height = max(width * 1.5, CGFloat(text.count) * font * 0.62 + font * 0.7)
        Text(text)
            .font(.system(size: font, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(white: 0.1))
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: max(2, width * 0.14)).fill(Color(white: 0.97)))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .allowsHitTesting(false)
            .accessibilityLabel("Label \(number)")
    }

    /// The sticker for a cover `size` wide shown without its case, in its top-left corner (where the hinge would be).
    static func onCover(_ number: Int, size: CGFloat) -> some View {
        LabelSticker(number: number, width: size * 0.11)
            .padding(size * 0.025)
            .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// The round badge on the cover of a CD you borrowed (two arrows: lent to you) or an album you bought as a download (a
/// dollar sign), in its bottom-right corner.
struct OwnershipBadge: View {
    /// `.borrowed` or `.digital`.
    let mark: OwnershipMark
    /// The cover's side.
    let coverSide: CGFloat

    var body: some View {
        let diameter = max(16, min(30, coverSide * 0.13))
        let digital = mark == .digital
        Image(systemName: digital ? "dollarsign" : "arrow.left.arrow.right")
            .font(.system(size: diameter * 0.48, weight: .bold))
            .foregroundStyle(Color(white: 0.33))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .padding(max(4, coverSide * 0.035))
            .allowsHitTesting(false)
            .accessibilityLabel(digital ? "Bought as a download" : "Borrowed")
    }
}

/// How you got the album, on a cover shown without its case: your CD's label in the top-left corner (where the hinge
/// would be), or the round badge of a borrowed CD or a download.
struct CoverOwnershipMark: View {
    let mark: OwnershipMark
    /// The cover's side.
    let size: CGFloat

    var body: some View {
        switch mark {
        case .cd(let label):
            if let label { LabelSticker.onCover(label, size: size) }
        case .borrowed, .digital:
            OwnershipBadge(mark: mark, coverSide: size).frame(width: size, height: size, alignment: .bottomTrailing)
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
