import MusicLibraryCore
import SwiftUI

/// A record's cover drawn as its cardboard sleeve, with the black disc showing on the right. It takes the same space as
/// a `JewelCase` of the same width, so cases and sleeves line up in a grid: the sleeve is as tall as the case, and the
/// disc shows in the rest. Your label is the same white strip as a CD's, down the sleeve's top-left edge where the CD's
/// sits on its case, and a record not digitized yet has a small badge in the bottom-right corner; both say what they
/// mean (on hover on the Mac, on a press and hold on the iPhone). The rest of the decoration doesn't take clicks.
/// Shared by the Mac and iPhone apps.
public struct RecordSleeve<Booklet: View>: View {
    let width: CGFloat
    var mark: CopyMark?
    /// The disc's centre label: this colour (the Mac passes the cover's average), or else the cover itself, blurred
    /// into its own colours.
    var tint: Color?
    /// Whether the album's music is only in iCloud: a cloud badge beside the mark's.
    var iCloud: ICloudPlacement
    var booklet: Booklet

    public init(width: CGFloat, mark: CopyMark?, tint: Color? = nil, iCloud: ICloudPlacement = .onMac,
                @ViewBuilder booklet: () -> Booklet) {
        self.width = width
        self.mark = mark
        self.tint = tint
        self.iCloud = iCloud
        self.booklet = booklet()
    }

    public static func height(width: CGFloat) -> CGFloat { JewelCase<EmptyView>.height(width: width) }
    /// The sleeve's side (the cover's) in a sleeve this wide; the rest is the disc showing.
    public static func sleeveSide(width: CGFloat) -> CGFloat { height(width: width) }

    public var body: some View {
        let h = Self.height(width: width), side = Self.sleeveSide(width: width)
        let radius = max(1.5, side * 0.008)
        ZStack(alignment: .topLeading) {
            disc(diameter: side * 0.97, side: side)
                .offset(x: width - side * 0.97, y: side * 0.015)
            booklet
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay { sleeveFinish(radius: radius) }
                .shadow(color: .black.opacity(0.35), radius: max(1, side * 0.012), x: max(0.5, side * 0.006))
            // The same strip as a CD's, in the same place and size. It and the badges take the pointer only to say
            // what they mean.
            if let sticker = mark?.sticker, sticker.series == .vinyl {
                LabelSticker(number: sticker.number, series: .vinyl, width: JewelCase<EmptyView>.stickerWidth(width: width))
                    .offset(JewelCase<EmptyView>.stickerOffset(width: width))
            }
            CopyBadges(mark: mark, iCloud: iCloud, coverSide: side)
                .frame(width: side, height: side, alignment: .bottomTrailing)
            if let mark, mark.more > 0, width >= 120 {
                CopiesChip(count: mark.more + 1, coverSide: side)
                    .frame(width: side, height: side, alignment: .topTrailing)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // Contact and ambient shadows under the sleeve, scaled with it (as the jewel case's).
            let scale = width / 380
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.22), radius: 0.5, y: 1)
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.3), radius: 14 * scale, y: 14 * scale)
            }
            .frame(width: side, height: side)
        }
    }

    /// Cardboard: a soft darkening along the edges, worn corners and a faint sheen.
    private func sleeveFinish(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return ZStack {
            shape.strokeBorder(.black.opacity(0.18), lineWidth: max(1, width * 0.006))
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            LinearGradient(stops: [.init(color: .white.opacity(0.10), location: 0), .init(color: .clear, location: 0.35),
                                   .init(color: .clear, location: 0.8), .init(color: .black.opacity(0.10), location: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(shape)
        }
        .allowsHitTesting(false)
    }

    /// The black disc: grooves, a sheen, and the centre label with its spindle hole.
    private func disc(diameter d: CGFloat, side: CGFloat) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.12), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: d / 2))
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var r = d * 0.2
                while r < d * 0.48 {
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.05)), lineWidth: 0.5)
                    r += max(1.2, d * 0.012)
                }
            }
            AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear], center: .center)
                .clipShape(Circle())
            centreLabel(diameter: d * 0.34, side: side)
            Circle().fill(Color(white: 0.08)).frame(width: d * 0.025, height: d * 0.025)
            // The rim catching the light, so the disc shows on dark backgrounds too.
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: max(0.5, d * 0.005))
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func centreLabel(diameter: CGFloat, side: CGFloat) -> some View {
        if let tint {
            Circle().fill(tint).frame(width: diameter, height: diameter)
        } else {
            booklet
                .scaleEffect(diameter / max(side, 1))
                .frame(width: diameter, height: diameter)
                .blur(radius: diameter * 0.15)
                .saturation(1.3)
                .clipShape(Circle())
                .overlay(Circle().fill(.black.opacity(0.08)))
        }
    }
}
