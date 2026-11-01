import AppKit
import MusicLibraryCore
import SwiftUI

/// A record's cover drawn as its cardboard sleeve, with the black disc showing on the right (its centre label tinted
/// from the cover). It takes the same space as a `JewelCase` of the same width, so cases and sleeves line up in a
/// grid: the sleeve is as tall as the case, and the disc shows in the rest. Your label is the same white strip as a
/// CD's, down the sleeve's top-left edge where the CD's sits on its case, and a record not digitized yet has a small badge
/// in the bottom-right corner; hover either for what it means. The rest of the decoration doesn't take clicks. The
/// iPhone app has the same view (`iOS/MusicLibraryMobile/RecordSleeve.swift`).
struct RecordSleeve<Booklet: View>: View {
    let width: CGFloat
    var mark: CopyMark?
    /// The disc's centre label; by default a deep red.
    var tint: Color?
    /// Whether the album's music is only in iCloud: a cloud badge beside the mark's.
    var iCloud: ICloudMark.Placement
    var booklet: Booklet

    init(width: CGFloat, mark: CopyMark?, tint: Color? = nil, iCloud: ICloudMark.Placement = .onMac, @ViewBuilder booklet: () -> Booklet) {
        self.iCloud = iCloud
        self.width = width
        self.mark = mark
        self.tint = tint
        self.booklet = booklet()
    }

    static func height(width: CGFloat) -> CGFloat { JewelCase<EmptyView>.height(width: width) }
    /// The sleeve's side (the cover's) in a sleeve this wide.
    static func sleeveSide(width: CGFloat) -> CGFloat { height(width: width) }

    var body: some View {
        let h = Self.height(width: width), side = Self.sleeveSide(width: width)
        let radius = max(1.5, side * 0.008)
        ZStack(alignment: .topLeading) {
            disc(diameter: side * 0.97)
                .offset(x: width - side * 0.97, y: side * 0.015)
            booklet
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay { sleeveFinish(radius: radius) }
                .shadow(color: .black.opacity(0.35), radius: max(1, side * 0.012), x: max(0.5, side * 0.006))
            // The same strip as a CD's, in the same place and size. It and the badge take the pointer only
            // to show what they mean.
            if let sticker = mark?.sticker, sticker.series == .vinyl {
                LabelSticker(number: sticker.number, series: .vinyl, width: JewelCase<EmptyView>.stickerWidth(width: width))
                    .offset(JewelCase<EmptyView>.stickerOffset(width: width))
            }
            CopyBadges(mark: mark, iCloud: iCloud, coverSide: side)
                .frame(width: side, height: side, alignment: .bottomTrailing)
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
    private func disc(diameter d: CGFloat) -> some View {
        let label = tint ?? Color(red: 0.55, green: 0.12, blue: 0.12)
        return ZStack {
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
            Circle().fill(label).frame(width: d * 0.34, height: d * 0.34)
            Circle().fill(Color(white: 0.08)).frame(width: d * 0.025, height: d * 0.025)
            // The rim catching the light, so the disc shows on dark backgrounds too.
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: max(0.5, d * 0.005))
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .allowsHitTesting(false)
    }
}

/// The cover of something you own, drawn the way it sits on your shelf: a `JewelCase` for a CD, a `RecordSleeve` for
/// a record, else the flat cover with its badge (a download, a medium added by a newer version, a borrowed CD).
/// Every shape is as tall as a jewel case of the same width, so mixed grids line up.
struct CopyArt: View {
    let mark: CopyMark?
    let url: URL?
    let width: CGFloat
    /// Pass `AppModel.coverRevision` so a replaced cover.jpg is loaded again.
    var revision = 0
    /// Shown on the placeholder when there's no cover.
    var title = ""
    /// Whether the music is only in iCloud (offloaded from this Mac): a cloud badge in the corner.
    var iCloud: ICloudMark.Placement = .onMac
    @State private var tint: Color?

    var body: some View {
        switch mark {
        case .cd?:
            JewelCase(width: width, mark: mark, iCloud: iCloud) { cover(side: JewelCase<EmptyView>.bookletSide(width: width)) }
        case .vinyl?:
            RecordSleeve(width: width, mark: mark, tint: tint, iCloud: iCloud) { cover(side: RecordSleeve<EmptyView>.sleeveSide(width: width)) }
                .task(id: "\(url?.path ?? "")|\(revision)") { tint = await CoverTint.color(of: url) }
        default:
            let side = JewelCase<EmptyView>.height(width: width)
            Group {
                if url == nil, !title.isEmpty {
                    placeholder(side: side).overlay { CoverCopyMark(mark: mark, size: side, iCloud: iCloud) }
                } else {
                    CoverThumb(url: url, size: side, revision: revision, mark: mark, iCloud: iCloud)
                }
            }
            .frame(width: width, height: side)
        }
    }

    @ViewBuilder
    private func cover(side: CGFloat) -> some View {
        if url == nil, !title.isEmpty {
            placeholder(side: side)
        } else {
            CoverThumb(url: url, size: side, revision: revision, cornerRadius: 0)
        }
    }

    /// No cover: the title on a plain booklet.
    private func placeholder(side: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
            Text(title)
                .font(.system(size: max(9, side * 0.09), weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(side * 0.1)
        }
        .frame(width: side, height: side)
    }
}

/// The average colour of a cover, for a record's centre label. Cached by file and modification date.
enum CoverTint {
    @MainActor private static var cache: [String: Color] = [:]

    @MainActor
    static func color(of url: URL?) async -> Color? {
        guard let url else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let known = cache[key] { return known }
        guard let rgb = await Task.detached(operation: { average(url) }).value else { return nil }
        let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = color
        return color
    }

    /// The cover drawn into one pixel.
    nonisolated private static func average(_ url: URL) -> (Double, Double, Double)? {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
