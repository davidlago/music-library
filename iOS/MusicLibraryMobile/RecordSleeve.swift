import MusicLibraryCore
import SwiftUI

/// A record's cover drawn as its cardboard sleeve with the black disc slid out a little on the right, the centre label
/// tinted from the cover. As tall as a `JewelCase` of the same width, so records and CDs line up in a grid. The
/// label number is a round yellow sticker on the sleeve's top-left corner, and a record with no digital copy gets the
/// waveform badge. The decoration doesn't take taps. The Mac app has the same view (`Sources/MusicLibrary/RecordSleeve.swift`).
struct RecordSleeve<Cover: View>: View {
    let width: CGFloat
    var mark: CopyMark?
    var cover: Cover

    init(width: CGFloat, mark: CopyMark?, @ViewBuilder cover: () -> Cover) {
        self.width = width
        self.mark = mark
        self.cover = cover()
    }

    static func height(width: CGFloat) -> CGFloat { JewelCase<EmptyView>.height(width: width) }
    /// The sleeve's side (the cover's) in a view this wide; the rest is the disc showing.
    static func sleeveSide(width: CGFloat) -> CGFloat { height(width: width) }

    var body: some View {
        let side = Self.sleeveSide(width: width)
        let disc = side * 0.97
        let radius = max(1.5, side * 0.008)
        ZStack(alignment: .topLeading) {
            vinyl(diameter: disc, side: side)
                .offset(x: width - disc, y: (side - disc) / 2)
            cover
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay {
                    // Worn cardboard: a soft edge, lighter at the top, and a little texture of light.
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.25)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(0.5, side * 0.004))
                        .allowsHitTesting(false)
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .white.opacity(0.10), location: 0), .init(color: .clear, location: 0.35),
                                           .init(color: .black.opacity(0.08), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.35), radius: side * 0.015, x: side * 0.01, y: side * 0.012)
            Group {
                if let sticker = mark?.sticker {
                    LabelSticker(number: sticker.number, series: sticker.series, width: max(16, side * 0.13))
                        .padding(side * 0.035)
                }
                if let mark, let kind = CopyBadge.kind(for: mark) {
                    CopyBadge(kind: kind, coverSide: side)
                        .frame(width: side, height: side, alignment: .bottomTrailing)
                }
                if let mark, mark.more > 0, width >= 120 {
                    CopiesChip(count: mark.more + 1, coverSide: side)
                        .frame(width: side, height: side, alignment: .topTrailing)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: width, height: side, alignment: .topLeading)
    }

    /// The disc: grooves, a sheen, and the label (the cover, blurred into its own colors).
    private func vinyl(diameter d: CGFloat, side: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var r = size.width * 0.2
                while r < size.width * 0.49 {
                    let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.05)), lineWidth: 0.5)
                    r += max(1.2, size.width * 0.012)
                }
            }
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.13), .clear, .clear, .white.opacity(0.09), .clear],
                                          center: .center))
            cover
                .scaleEffect(d * 0.34 / max(side, 1))
                .frame(width: d * 0.34, height: d * 0.34)
                .blur(radius: d * 0.05)
                .saturation(1.3)
                .clipShape(Circle())
                .overlay(Circle().fill(.black.opacity(0.08)))
            Circle().fill(Color(white: 0.85)).frame(width: max(2, d * 0.025))
            // The rim catching the light, so the disc shows on dark backgrounds too.
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: max(0.5, d * 0.005))
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.35), radius: d * 0.01, y: d * 0.008)
        .allowsHitTesting(false)
    }
}

/// The art for what you own: a CD (or a library album not in your collection: a borrowed CD) in its `JewelCase`, a
/// record in its `RecordSleeve`, or a flat cover with its badges for a download or another medium. Always as tall as a
/// jewel case `width` wide, so cells line up; a flat cover is that tall and square.
struct CopyArt: View {
    let mark: CopyMark
    let url: URL?
    let width: CGFloat
    /// Drawn on the placeholder when there's no cover.
    var title: String?

    static func height(width: CGFloat) -> CGFloat { JewelCase<EmptyView>.height(width: width) }

    var body: some View {
        switch mark {
        case .cd, .notInCollection:
            JewelCase(width: width, mark: mark) {
                CoverImage(url: url, size: JewelCase<EmptyView>.bookletSide(width: width), cornerRadius: 0, title: title)
            }
        case .vinyl:
            RecordSleeve(width: width, mark: mark) {
                CoverImage(url: url, size: RecordSleeve<EmptyView>.sleeveSide(width: width), cornerRadius: 0, title: title)
            }
        case .download, .other:
            CoverImage(url: url, size: Self.height(width: width), mark: mark, title: title)
                .frame(width: width, alignment: .leading)
        }
    }
}
