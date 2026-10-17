import AppKit
import MusicLibraryCore
import SwiftUI

extension Track {
    var yearSort: Int { year ?? 0 }
    var trackSort: Int { trackNo ?? 0 }
    var formatSort: String { audioFormat?.codec ?? format }
    var formatLabel: String { audioFormat?.compact ?? format.uppercased() }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "3 hr 12 min", "2 days 4 hr"
func formatLongDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return formatTime(seconds) }
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
    f.unitsStyle = .short
    f.maximumUnitCount = 2
    return f.string(from: seconds) ?? formatTime(seconds)
}

/// Listening time: "—" for none, "52 sec" under a minute, then "3 hr, 12 min".
func formatListened(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 1 else { return "—" }
    return seconds < 60 ? "\(Int(seconds)) sec" : formatLongDuration(seconds)
}

func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n.formatted()) songs" }

struct CoverThumb: View {
    let url: URL?
    var size: CGFloat = 140
    /// Pass `AppModel.coverRevision` so a replaced cover.jpg is loaded again.
    var revision = 0
    /// How you got the album (`OwnershipMark`): your label in the top-left corner or a round badge (`CoverOwnershipMark`).
    /// In a `JewelCase`, give it to the case instead, which puts the label on the hinge.
    var ownership: OwnershipMark?
    /// 0 for a booklet in a `JewelCase`.
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.system(size: size / 3)).foregroundStyle(.subtext)
            }
            if let ownership { CoverOwnershipMark(mark: ownership, size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(url?.path ?? "")|\(revision)") {
            guard let url else { image = nil; return }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap { NSImage(data: $0) }
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

struct DataImage: View {
    let data: Data?
    var size: CGFloat = 160

    var body: some View {
        ZStack {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "photo").font(.system(size: size / 4)).foregroundStyle(.subtext)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
