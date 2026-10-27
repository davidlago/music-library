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
                Image(systemName: "music.note").font(.system(size: size / 3)).foregroundStyle(.secondary)
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

/// The colours of the label stickers, fixed like the real ones (the same in light and dark).
enum StickerColors {
    /// The sticker: a white strip, the same on CDs and records (a case and a sleeve are told apart at a glance).
    static let sticker = Color(white: 0.97)
    static let text = Color(white: 0.1)
}

/// The sticker with your label number: a strip, tall, across the top of the case's hinge (`JewelCase(mark:)`) or
/// down the left edge of a record's sleeve in the same place (`RecordSleeve`), the number running up it, read from
/// bottom to top. It's white on both: the case or the sleeve tells the series. A cover shown without its
/// case has a `StickerPill` instead (`CoverCopyMark`). Hover it for the label in words.
struct LabelSticker: View {
    let number: Int
    var series: StickerSeries = .cd
    /// The strip's width (it's half again as tall, and taller when the number doesn't fit).
    let width: CGFloat

    var body: some View {
        let sticker = Sticker(series: series, number: number)
        // In proportion to the strip, with no floor: a larger number would spill over a small case's hinge.
        let font = width * 0.6
        let text = String(number)
        // Monospaced digits are about 0.6 em wide, plus some room at the ends.
        let height = max(width * 1.5, CGFloat(text.count) * font * 0.62 + font * 0.7)
        Text(text)
            .font(.system(size: font, weight: .semibold).monospacedDigit())
            .foregroundStyle(StickerColors.text)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: max(2, width * 0.14)).fill(StickerColors.sticker))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .contentShape(Rectangle())
            .help(sticker.map { "Your label: \($0.text)" } ?? "Label \(number)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sticker?.spoken ?? "Label \(number)")
    }
}

/// A label in lists and captions: a white pill with a small "CD" or "VINYL", then the
/// number in monospaced digits. Fixed colours, like the stickers. On a cover (`numberOnly`) it's just the number, as
/// on the stickers.
struct StickerPill: View {
    let sticker: Sticker
    /// The number's font size.
    var size: CGFloat = 11
    var numberOnly = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.3) {
            if !numberOnly {
                Text(sticker.series == .cd ? "CD" : "VINYL").font(.system(size: size * 0.66, weight: .bold))
            }
            Text(String(sticker.number)).font(.system(size: size, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(StickerColors.text)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, size * 0.55)
        .padding(.vertical, size * 0.16)
        .background(Capsule().fill(StickerColors.sticker))
        .overlay(Capsule().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
        .help("Your label: \(sticker.text)")
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
        case .notInCollection:
            self.init(symbol: "arrow.left.arrow.right", label: "Borrowed: you don't own a copy", coverSide: coverSide)
        case .download(let partial, _):
            self.init(symbol: "dollarsign", label: partial ? "Some songs bought as downloads" : "Bought as a download",
                      coverSide: coverSide)
        case .cd(_, false, _):
            self.init(symbol: "waveform.slash", label: "Not ripped yet: no digital copy", coverSide: coverSide)
        case .vinyl(_, false, _):
            self.init(symbol: "waveform.slash", label: "Not digitized yet: no digital copy", coverSide: coverSide)
        case .other: self.init(symbol: "shippingbox", label: "Added by a newer version of Music Library", coverSide: coverSide)
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
            .contentShape(Circle())
            .help(label)
            .padding(max(4, coverSide * 0.035))
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
                StickerPill(sticker: sticker, size: max(7, min(13, size * 0.08)), numberOnly: true)
                    .padding(size * 0.03)
                    .frame(width: size, height: size, alignment: .topLeading)
            }
            if let badge = CopyBadge(mark: mark, coverSide: size) {
                badge.frame(width: size, height: size, alignment: .bottomTrailing)
            }
        }
    }
}

/// An item's digital copy in a word or two, with an icon unless it's digitized: "Not ripped", "8 of 12 songs",
/// "From your CD #142", "Digital copy missing".
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
        .foregroundStyle(.secondary)
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
            return "Same album, from elsewhere"
        case .none:
            switch medium {
            case .cd: return "Not ripped"
            case .download: return "Not imported"
            case .vinyl, .other: return "Not digitized"
            }
        case .missing: return "Digital copy missing"
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
                Image(systemName: "photo").font(.system(size: size / 4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
