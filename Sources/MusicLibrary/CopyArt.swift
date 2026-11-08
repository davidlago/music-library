import AppKit
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

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
    var iCloud: ICloudPlacement = .onMac
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
