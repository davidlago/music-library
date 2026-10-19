import ImageIO
import MusicLibraryCore
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

extension CopyMark {
    /// A CD or record with no digital copy (the case or sleeve gets the waveform badge).
    var needsDigitizing: Bool {
        switch self {
        case .cd(_, let digitized, _), .vinyl(_, let digitized, _): !digitized
        default: false
        }
    }

    /// Copies beyond the one the mark shows.
    var more: Int {
        switch self {
        case .notInCollection: 0
        case .cd(_, _, let more), .vinyl(_, _, let more), .download(_, let more), .other(let more): more
        }
    }
}

// MARK: Labels

/// The sticker with your label number, like the one on the real thing: a strip across the top of a jewel case's
/// hinge, or down the left edge of a record's sleeve in the same place, the number read bottom to top. White on both
/// (the case or the sleeve tells the series), whatever the appearance.
struct LabelSticker: View {
    let number: Int
    var series: StickerSeries = .cd
    /// The strip's width; it's half again as tall, and taller when the number doesn't fit.
    let width: CGFloat

    /// The sticker's white, the same on CDs and records.
    static let white = Color(white: 0.97)

    var body: some View {
        let text = String(number)
        // In proportion to the strip, with no floor: a larger number would spill over a small case's hinge.
        let font = width * 0.6
        // Monospaced digits are about 0.6 em wide.
        let height = max(width * 1.5, CGFloat(text.count) * font * 0.62 + font * 0.7)
        Text(text)
            .font(.system(size: font, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(white: 0.1))
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: max(2, width * 0.14)).fill(Self.white))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .explainOnLongPress(Sticker(series: series, number: number).map { "Your label: \($0.text)" } ?? "Label \(number)")
            .accessibilityLabel(Sticker(series: series, number: number)?.spoken ?? "Label \(number)")
    }

    /// The sticker for a cover `size` wide shown without its case, in its top-left corner.
    static func onCover(_ sticker: Sticker, size: CGFloat) -> some View {
        LabelSticker(number: sticker.number, series: sticker.series, width: size * 0.11)
            .padding(size * 0.025)
            .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// A label in text: "CD" or "VINYL" and the number in a white pill, so CD #12 and Vinyl #12 never read alike. Fixed
/// colors, like the stickers.
struct StickerPill: View {
    let sticker: Sticker
    var size: CGFloat = 12
    /// On a cover: just the number, as on the stickers (press and hold it for the label in words).
    var numberOnly = false

    var body: some View {
        HStack(spacing: size * 0.3) {
            if !numberOnly {
                Text(sticker.series == .cd ? "CD" : "VINYL")
                    .font(.system(size: size * 0.66, weight: .heavy))
                    .tracking(size * 0.03)
                    .opacity(0.6)
            }
            Text(String(sticker.number))
                .font(.system(size: size, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Color(white: 0.08))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, size * 0.55)
        .padding(.vertical, size * 0.18)
        .background(Capsule().fill(LabelSticker.white))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sticker.spoken)
    }
}

// MARK: Badges

/// A round badge in the bottom-right corner of a cover: a CD you borrowed (two arrows: lent to you), an album bought as
/// a download (a dollar sign), a CD or record with no digital copy (a crossed-out waveform), or a medium a newer
/// version added.
struct CopyBadge: View {
    enum Kind { case borrowed, download, notRipped, notDigitized, other }
    let kind: Kind
    /// The cover's side.
    let coverSide: CGFloat

    var body: some View {
        let diameter = max(16, min(30, coverSide * 0.13))
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.48, weight: .bold))
            .foregroundStyle(Color(white: 0.33))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .explainOnLongPress(label)
            .padding(max(4, coverSide * 0.035))
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch kind {
        case .borrowed: "arrow.left.arrow.right"
        case .download: "dollarsign"
        case .notRipped, .notDigitized: "waveform.slash"
        case .other: "shippingbox"
        }
    }

    private var label: String { Self.label(kind) }

    static func label(_ kind: Kind) -> String {
        switch kind {
        case .borrowed: "Borrowed: not in your collection"
        case .download: "Bought as a download"
        case .notRipped: "Not ripped yet: no digital copy in your library"
        case .notDigitized: "Not digitized yet: no digital copy in your library"
        case .other: "Added by a newer version of Music Library"
        }
    }

    /// The badge a mark puts on a cover, if any (labels go on stickers).
    static func kind(for mark: CopyMark) -> Kind? {
        switch mark {
        case .notInCollection: .borrowed
        case .download: .download
        case .other: .other
        case .cd(_, let digitized, _): digitized ? nil : .notRipped
        case .vinyl(_, let digitized, _): digitized ? nil : .notDigitized
        }
    }
}

/// Two squares and "2" in a capsule: how many copies of the album you own, when more than one (the glyph keeps it from
/// reading as a label number).
struct CopiesChip: View {
    let count: Int
    let coverSide: CGFloat

    var body: some View {
        let size = max(9, min(13, coverSide * 0.07))
        HStack(spacing: size * 0.25) {
            Image(systemName: "square.on.square").font(.system(size: size * 0.85, weight: .semibold))
            Text(count.formatted()).font(.system(size: size, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.65)))
        .explainOnLongPress("You own \(count) copies of this album")
        .padding(max(4, coverSide * 0.035))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) copies")
    }
}

/// What you own of an album, on a cover shown without its case: your label (a pill) in the top-left corner, badges in
/// the bottom-right and the number of copies in the top-right.
struct CoverCopyMark: View {
    let mark: CopyMark
    /// The cover's side.
    let size: CGFloat

    var body: some View {
        ZStack {
            if let sticker = mark.sticker {
                if size >= 90 {
                    StickerPill(sticker: sticker, size: max(9, min(14, size * 0.075)), numberOnly: true)
                        .explainOnLongPress("Your label: \(sticker.text)")
                        .padding(size * 0.04)
                        .frame(width: size, height: size, alignment: .topLeading)
                } else {
                    LabelSticker.onCover(sticker, size: size)
                }
            }
            if let kind = CopyBadge.kind(for: mark) {
                CopyBadge(kind: kind, coverSide: size).frame(width: size, height: size, alignment: .bottomTrailing)
            }
            if mark.more > 0, size >= 90 {
                CopiesChip(count: mark.more + 1, coverSide: size).frame(width: size, height: size, alignment: .topTrailing)
            }
        }
        .frame(width: size, height: size)
    }
}

extension EnvironmentValues {
    /// Whether a cover's marks say what they mean when pressed and held. Off where the cover has its own context menu
    /// (the long press is the menu's): the menu lists what they mean instead (`CopyMark.meanings`).
    @Entry var explainsMarksOnPress = true
}

extension CopyMark {
    /// What a cover's marks mean, in words: its label, its badge, how many copies.
    var meanings: [String] {
        var lines: [String] = []
        if let sticker { lines.append("Your label: \(sticker.text)") }
        if let kind = CopyBadge.kind(for: self) { lines.append(CopyBadge.label(kind)) }
        if more > 0 { lines.append("You own \(more + 1) copies of this album") }
        return lines
    }
}

/// Press and hold a cover's sticker, badge or copies chip to see what it means in a small bubble: the iPhone's
/// stand-in for the Mac's tooltips.
struct ExplainOnLongPress: ViewModifier {
    let text: String
    @Environment(\.explainsMarksOnPress) private var enabled
    @State private var shown = false

    func body(content: Content) -> some View {
        if enabled { explained(content) } else { content }
    }

    private func explained(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.35) { shown = true }
            .sensoryFeedback(.selection, trigger: shown) { _, new in new }
            .popover(isPresented: $shown) {
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

extension View {
    func explainOnLongPress(_ text: String) -> some View { modifier(ExplainOnLongPress(text: text)) }
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
