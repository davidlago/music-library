import MusicLibraryCore
import SwiftUI

/// An album's cover drawn as a CD jewel case (album pages and the album grid), 142 × 125 mm: the cover is the square
/// booklet behind the clear lid, with the ribbed hinge and its pins on the left, the black tray showing around the
/// booklet, the two tabs that hold it and the lid's bevelled edges and gloss. The decoration doesn't take clicks, so controls in the booklet work.
/// The iPhone app has the same view (`iOS/MusicLibraryMobile/JewelCase.swift`); a record is a `RecordSleeve`.
struct JewelCase<Booklet: View>: View {
    let width: CGFloat
    /// What you own: your CD's label on a sticker across the top of the hinge (where it goes on the real case), a
    /// small badge on the booklet while it isn't ripped, or a round badge for a borrowed CD or a download.
    var mark: CopyMark?
    var booklet: Booklet

    init(width: CGFloat, mark: CopyMark?, @ViewBuilder booklet: () -> Booklet) {
        self.width = width
        self.mark = mark
        self.booklet = booklet()
    }

    static func height(width: CGFloat) -> CGFloat { width * 125 / 142 }
    /// The booklet's side in a case this wide.
    static func bookletSide(width: CGFloat) -> CGFloat { height(width: width) * 0.944 }
    static func cornerRadius(width: CGFloat) -> CGFloat { width * 0.014 }

    var body: some View {
        let w = width, h = Self.height(width: w)
        let radius = Self.cornerRadius(width: w)
        let side = Self.bookletSide(width: w)
        let margin = h * 0.028
        let hinge = w * 0.105
        ZStack(alignment: .topLeading) {
            // The black tray, slightly glossy.
            RoundedRectangle(cornerRadius: radius)
                .fill(RadialGradient(colors: [Color(white: 0.17), Color(white: 0.05)], center: UnitPoint(x: 0.3, y: 0.1),
                                     startRadius: 0, endRadius: w * 0.75))
            booklet
                .frame(width: side, height: side)
                .clipped()
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                .offset(x: w - margin - side, y: margin)
            Group {
                ForEach([h * 0.09, h * 0.83], id: \.self) { y in
                    tab.frame(width: w * 0.026, height: h * 0.08).offset(x: w * 0.962, y: y)
                }
                lid(radius: radius).frame(width: w - hinge, height: h).offset(x: hinge)
                hingeStrip(radius: radius).frame(width: hinge, height: h)
                ForEach([h * 0.022, h * 0.913], id: \.self) { y in
                    knuckle.frame(width: hinge * 0.65, height: h * 0.065).offset(x: hinge * 0.19, y: y)
                }
                if let sticker = mark?.sticker, sticker.series == .cd {
                    LabelSticker(number: sticker.number, series: .cd, width: hinge * 0.88).offset(x: hinge * 0.04, y: h * 0.012)
                }
                if let mark, let badge = CopyBadge(mark: mark, coverSide: side) {
                    badge
                        .frame(width: side, height: side, alignment: .bottomTrailing)
                        .offset(x: w - margin - side, y: margin)
                }
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .background {
            // Three shadows, each on its own shape so they don't compound: contact, near and ambient, scaled with the
            // case (they were tuned at 380 points wide).
            let scale = w / 380
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.25), radius: 0.5, y: 1)
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.18), radius: 5 * scale, y: 6 * scale)
                RoundedRectangle(cornerRadius: radius).fill(.black).shadow(color: .black.opacity(0.35), radius: 18 * scale, y: 18 * scale)
            }
        }
    }

    /// Clear ribbed plastic over the tray's black spine.
    private func hingeStrip(radius: CGFloat) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius)
            .fill(Color(red: 0.08, green: 0.09, blue: 0.10))
            .overlay {
                Canvas { context, size in
                    var x = 0.0
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(.white.opacity(0.16)))
                        x += 2.4
                    }
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0), .init(color: .white.opacity(0.06), location: 0.18),
                                       .init(color: .white.opacity(0.02), location: 0.6), .init(color: .white.opacity(0.22), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.5)).frame(width: 1)
                    Rectangle().fill(.white.opacity(0.45)).frame(width: 1)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius))
    }

    /// The hinge pins: clear cylinders at the top and bottom.
    private var knuckle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(stops: [.init(color: .white.opacity(0.18), location: 0), .init(color: .white.opacity(0.62), location: 0.35),
                                         .init(color: .white.opacity(0.22), location: 0.7), .init(color: .white.opacity(0.45), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
    }

    /// One of the tabs on the right that hold the booklet in.
    private var tab: some View {
        UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5)
            .fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.42)], startPoint: .leading, endPoint: .trailing))
            .overlay { UnevenRoundedRectangle(topLeadingRadius: 1.5, bottomLeadingRadius: 1.5).strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.45), radius: 1, x: -1)
    }

    /// The clear lid right of the hinge: thick bevelled edges and the gloss across it.
    private func lid(radius: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius)
        return shape
            .fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.34), location: 0), .init(color: .white.opacity(0.18), location: 0.14),
                .init(color: .white.opacity(0.10), location: 0.26), .init(color: .white.opacity(0), location: 0.266),
                .init(color: .white.opacity(0), location: 0.58), .init(color: .white.opacity(0.06), location: 0.66),
                .init(color: .white.opacity(0), location: 0.74),
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { shape.fill(Color(red: 0.86, green: 0.91, blue: 0.96).opacity(0.04)) }
            .overlay { shape.strokeBorder(.white.opacity(0.07), lineWidth: 3) }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1.5)
            }
    }
}
