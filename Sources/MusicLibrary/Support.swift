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
    /// What you own (`CopyMark`): a label pill in the top-left corner and badges in the bottom-right
    /// (`CoverCopyMark`). Never for a cover inside a `JewelCase` or `RecordSleeve`: give it to the case instead.
    var mark: CopyMark?
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
            if let mark {
                CoverCopyMark(mark: mark, size: size)
            }
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

/// The colours of the label stickers, fixed like the real ones (so every theme shows them the same).
enum StickerColors {
    /// The CD sticker: a white strip.
    static let cd = Color(white: 0.97)
    /// The vinyl sticker: a yellow dot (#F4C542).
    static let vinyl = Color(red: 0xF4 / 255, green: 0xC5 / 255, blue: 0x42 / 255)
    static let text = Color(white: 0.1)
}

/// The sticker with your label number. A CD's is the white strip on the case: tall, across the top of the hinge
/// (`JewelCase(mark:)`), "CD" and the number running up it, read from bottom to top. A record's is a round yellow
/// dot on the sleeve's top-left corner (`RecordSleeve`), read across. A cover shown without its case has a
/// `StickerPill` instead (`CoverCopyMark`).
struct LabelSticker: View {
    let number: Int
    var series: StickerSeries = .cd
    /// The strip's width (it's half again as tall, and taller when the number doesn't fit), or the dot's diameter.
    let width: CGFloat

    var body: some View {
        Group {
            switch series {
            case .cd: strip
            case .vinyl: dot
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Sticker(series: series, number: number)?.spoken ?? "Label \(number)")
    }

    private var strip: some View {
        let font = max(9, width * 0.6)
        let prefix = max(6, font * 0.55)
        let text = String(number)
        // Monospaced digits are about 0.6 em wide; "CD" and the gap before the number about 1.6 em of the prefix.
        let height = max(width * 1.5, CGFloat(text.count) * font * 0.62 + prefix * 1.6 + font * 0.7)
        return HStack(alignment: .firstTextBaseline, spacing: prefix * 0.35) {
            Text("CD").font(.system(size: prefix, weight: .bold))
            Text(text).font(.system(size: font, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(StickerColors.text)
        .fixedSize()
        .rotationEffect(.degrees(-90))
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: max(2, width * 0.14)).fill(StickerColors.cd))
    }

    private var dot: some View {
        let text = String(number)
        // As large as fits across the dot, at most 0.42 of it.
        let font = min(width * 0.42, width * 0.78 / (CGFloat(max(text.count, 1)) * 0.62))
        return Text(text)
            .font(.system(size: max(5, font), weight: .bold).monospacedDigit())
            .foregroundStyle(StickerColors.text)
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, height: width)
            .background(Circle().fill(StickerColors.vinyl))
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

/// A label in lists and captions: a white pill with a small "CD", or a yellow one with a small "VINYL", then the
/// number in monospaced digits. Fixed colours, like the stickers.
struct StickerPill: View {
    let sticker: Sticker
    /// The number's font size.
    var size: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            Text(sticker.series == .cd ? "CD" : "VINYL").font(.system(size: size * 0.66, weight: .bold))
            Text(String(sticker.number)).font(.system(size: size, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(StickerColors.text)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, size * 0.55)
        .padding(.vertical, size * 0.16)
        .background(Capsule().fill(sticker.series == .cd ? StickerColors.cd : StickerColors.vinyl))
        .overlay(Capsule().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sticker.spoken)
    }
}

extension CopyMark {
    /// Whether this is a CD or record you own that has no digital copy in the library yet.
    var needsDigitizing: Bool {
        switch self {
        case .cd(_, let digitized, _), .vinyl(_, let digitized, _): !digitized
        default: false
        }
    }
}

/// The round badge in the bottom-right corner of a cover: two arrows for a CD you borrowed (not in your collection),
/// a dollar sign for a download, a crossed-out waveform for a CD or record not ripped yet, a box for a medium added
/// by a newer version. Nil when the mark has none.
struct CopyBadge: View {
    let symbol: String
    let label: String
    /// The cover's side.
    let coverSide: CGFloat

    init(symbol: String, label: String, coverSide: CGFloat) {
        self.symbol = symbol; self.label = label; self.coverSide = coverSide
    }

    init?(mark: CopyMark, coverSide: CGFloat) {
        switch mark {
        case .notInCollection: self.init(symbol: "arrow.left.arrow.right", label: "Borrowed", coverSide: coverSide)
        case .download: self.init(symbol: "dollarsign", label: "Bought as a download", coverSide: coverSide)
        case .cd(_, false, _): self.init(symbol: "waveform.slash", label: "Not ripped", coverSide: coverSide)
        case .vinyl(_, false, _): self.init(symbol: "waveform.slash", label: "Not digitized", coverSide: coverSide)
        case .other: self.init(symbol: "shippingbox", label: "Added by a newer version", coverSide: coverSide)
        case .cd, .vinyl: return nil
        }
    }

    var body: some View {
        let diameter = max(16, min(30, coverSide * 0.13))
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.48, weight: .bold))
            .foregroundStyle(Color(white: 0.33))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .padding(max(4, coverSide * 0.035))
            .allowsHitTesting(false)
            .accessibilityLabel(label)
    }
}

/// What you own, on a cover shown without its case: the label pill in the top-left corner and the badge
/// (`CopyBadge`) in the bottom-right one.
struct CoverCopyMark: View {
    let mark: CopyMark
    /// The cover's side.
    let size: CGFloat

    var body: some View {
        ZStack {
            if let sticker = mark.sticker {
                StickerPill(sticker: sticker, size: max(7, min(13, size * 0.08)))
                    .padding(size * 0.03)
                    .frame(width: size, height: size, alignment: .topLeading)
            }
            if let badge = CopyBadge(mark: mark, coverSide: size) {
                badge.frame(width: size, height: size, alignment: .bottomTrailing)
            }
        }
        .allowsHitTesting(false)
    }
}

/// An item's digital copy in a word or two, with an icon unless it's digitized: "Not ripped", "8 of 12 songs",
/// "From your CD #142", "Missing from library".
struct DigitalStatusLabel: View {
    let state: DigitalState
    let medium: CollectionMedium
    /// For `.otherCopy`: the copy the music came from (`DigitalState.otherCopy`'s `from`), if one is in the collection.
    var from: CollectionItem?

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .foregroundStyle(.subtext)
        .lineLimit(1)
    }

    var symbol: String? {
        switch state {
        case .digitized: nil
        case .partial: "circle.lefthalf.filled"
        case .otherCopy: "arrow.triangle.2.circlepath"
        case .none: medium.isPhysical ? "waveform.slash" : nil
        case .missing: "exclamationmark.triangle"
        }
    }

    var text: String {
        switch state {
        case .digitized:
            switch medium {
            case .cd: return "Ripped"
            case .download: return "Downloaded"
            case .vinyl, .other: return "Digitized"
            }
        case .partial(let have, let of): return "\(have) of \(of) songs"
        case .otherCopy:
            if let sticker = from?.sticker { return "From your \(sticker.text)" }
            if let from { return "From your \(from.medium.name.lowercased())" }
            return "Same album in library"
        case .none:
            switch medium {
            case .cd: return "Not ripped"
            case .download: return "Not in library"
            case .vinyl, .other: return "Not digitized"
            }
        case .missing: return "Missing from library"
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
