import MusicLibraryCore
import SwiftUI

// What you own of an album, drawn on its cover: the label sticker, the label pill, the round badges and the copies
// chip. Shared by the Mac and iPhone apps; on the Mac each says what it means on hover, on the iPhone on a press and
// hold (`explainsMeaning(_:)`).

/// Where an album's music is relative to this Mac: all here, partly or only in iCloud (offloaded), or downloading.
/// The iPhone never offloads, so it always passes `.onMac` (the default), which draws nothing.
public enum ICloudPlacement: Equatable, Sendable {
    case onMac
    case partly
    case iCloudOnly
    case downloading
}

/// The colours of the label stickers, fixed like the real ones (the same in light and dark).
public enum StickerColors {
    /// The sticker: a white strip, the same on CDs and records (a case and a sleeve are told apart at a glance).
    public static let sticker = Color(white: 0.97)
    public static let text = Color(white: 0.1)
}

extension CopyMark {
    /// Whether this is a CD or record you own that has no digital copy in the library yet.
    public var needsDigitizing: Bool {
        switch self {
        case .cd(_, let digitized, _), .vinyl(_, let digitized, _): !digitized
        default: false
        }
    }

    /// Copies beyond the one the mark shows.
    public var more: Int {
        switch self {
        case .notInCollection: 0
        case .cd(_, _, let more), .vinyl(_, _, let more), .download(_, let more), .other(let more): more
        }
    }

    /// What a cover's marks mean, in words: its label, its badge, how many copies (the iPhone lists them in context
    /// menus, where a press and hold opens the menu instead).
    public var meanings: [String] {
        var lines: [String] = []
        if let sticker { lines.append("Your label: \(sticker.text)") }
        if let kind = CopyBadge.kind(for: self) { lines.append(kind.label) }
        if more > 0 { lines.append(CopiesChip.label(count: more + 1)) }
        return lines
    }
}

// MARK: Labels

/// The sticker with your label number, like the one on the real thing: a strip, tall, across the top of the case's
/// hinge (`JewelCase(mark:)`) or down the left edge of a record's sleeve in the same place (`RecordSleeve`), the
/// number running up it, read from bottom to top. It's white on both: the case or the sleeve tells the series. A cover
/// shown without its case has a `StickerPill` instead (`CoverCopyMark`).
public struct LabelSticker: View {
    let number: Int
    var series: StickerSeries
    /// The strip's width (it's half again as tall, and taller when the number doesn't fit).
    let width: CGFloat

    public init(number: Int, series: StickerSeries = .cd, width: CGFloat) {
        self.number = number
        self.series = series
        self.width = width
    }

    public var body: some View {
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
            .explainsMeaning(sticker.map { "Your label: \($0.text)" } ?? "Label \(number)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sticker?.spoken ?? "Label \(number)")
    }

    /// The sticker for a cover `size` wide shown without its case, in its top-left corner.
    public static func onCover(_ sticker: Sticker, size: CGFloat) -> some View {
        LabelSticker(number: sticker.number, series: sticker.series, width: size * 0.11)
            .padding(size * 0.025)
            .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// A label in lists and captions: a white pill with a small "CD" or "VINYL", then the number in monospaced digits, so
/// CD #12 and Vinyl #12 never read alike. Fixed colours, like the stickers. On a cover (`numberOnly`) it's just the
/// number, as on the stickers.
public struct StickerPill: View {
    let sticker: Sticker
    /// The number's font size.
    var size: CGFloat
    var numberOnly: Bool

    public init(sticker: Sticker, size: CGFloat = Self.defaultSize, numberOnly: Bool = false) {
        self.sticker = sticker
        self.size = size
        self.numberOnly = numberOnly
    }

    #if os(macOS)
    public static let defaultSize: CGFloat = 11
    #else
    public static let defaultSize: CGFloat = 12
    #endif

    public var body: some View {
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
        // In a list on the iPhone a press and hold belongs to the row, so only a pill on a cover explains itself there.
        .explainsMeaning("Your label: \(sticker.text)", onPress: numberOnly)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sticker.spoken)
    }
}

// MARK: Badges

/// A round badge in the bottom-right corner of a cover: two arrows for a CD you borrowed (not in your collection),
/// a dollar sign for a download, a crossed-out waveform for a CD or record not digitized yet, a box for a medium added
/// by a newer version, and on the Mac a struck-through cloud for music only in iCloud or an arrow while it downloads.
public struct CopyBadge: View {
    public enum Kind: Hashable, Sendable {
        case borrowed
        case download(partial: Bool)
        case notRipped
        case notDigitized
        case other
        case iCloudOnly
        case partlyInICloud
        case downloading

        public var symbol: String {
            switch self {
            case .borrowed: "arrow.left.arrow.right"
            case .download: "dollarsign"
            case .notRipped, .notDigitized: "waveform.slash"
            case .other: "shippingbox"
            case .iCloudOnly, .partlyInICloud: "icloud.slash"
            case .downloading: "arrow.down"
            }
        }

        public var label: String {
            switch self {
            case .borrowed: "Borrowed: you don't own a copy"
            case .download(let partial): partial ? "Some songs bought as downloads" : "Bought as a download"
            case .notRipped: "Not ripped yet: no digital copy"
            case .notDigitized: "Not digitized yet: no digital copy"
            case .other: "Added by a newer version of Music Library"
            case .iCloudOnly: "Not on this Mac: in iCloud only, downloads when you play it"
            case .partlyInICloud: "Some songs not on this Mac: in iCloud only, they download when you play them"
            case .downloading: "Downloading from iCloud"
            }
        }
    }

    let kind: Kind
    /// The cover's side.
    let coverSide: CGFloat

    public init(kind: Kind, coverSide: CGFloat) {
        self.kind = kind
        self.coverSide = coverSide
    }

    /// The badge a mark puts on a cover, if any (labels go on stickers).
    public static func kind(for mark: CopyMark) -> Kind? {
        switch mark {
        case .notInCollection: .borrowed
        case .download(let partial, _): .download(partial: partial)
        case .other: .other
        case .cd(_, let digitized, _): digitized ? nil : .notRipped
        case .vinyl(_, let digitized, _): digitized ? nil : .notDigitized
        }
    }

    /// The badge for music offloaded to iCloud, if any.
    public static func kind(for iCloud: ICloudPlacement) -> Kind? {
        switch iCloud {
        case .onMac: nil
        case .iCloudOnly: .iCloudOnly
        case .partly: .partlyInICloud
        case .downloading: .downloading
        }
    }

    public var body: some View {
        let diameter = max(16, min(30, coverSide * 0.13))
        Image(systemName: kind.symbol)
            .font(.system(size: diameter * 0.48, weight: .bold))
            .foregroundStyle(Color(white: 0.33))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .contentShape(Circle())
            .explainsMeaning(kind.label)
            .padding(max(4, coverSide * 0.035))
            .accessibilityLabel(kind.label)
    }
}

/// The badges in a cover's bottom-right corner: the copy's (`CopyBadge.kind(for: CopyMark)`) and, to its left, the
/// iCloud one when the album's music, or some of it, is only in iCloud.
public struct CopyBadges: View {
    let mark: CopyMark?
    var iCloud: ICloudPlacement
    let coverSide: CGFloat

    public init(mark: CopyMark?, iCloud: ICloudPlacement = .onMac, coverSide: CGFloat) {
        self.mark = mark
        self.iCloud = iCloud
        self.coverSide = coverSide
    }

    public var body: some View {
        // The badges' own padding, overlapped so they sit as close as one badge sits to the edge.
        HStack(spacing: -max(4, coverSide * 0.035)) {
            if let kind = CopyBadge.kind(for: iCloud) { CopyBadge(kind: kind, coverSide: coverSide) }
            if let mark, let kind = CopyBadge.kind(for: mark) { CopyBadge(kind: kind, coverSide: coverSide) }
        }
    }
}

/// Two squares and "2" in a capsule: how many copies of the album you own, when more than one (the glyph keeps it from
/// reading as a label number).
public struct CopiesChip: View {
    let count: Int
    let coverSide: CGFloat

    public init(count: Int, coverSide: CGFloat) {
        self.count = count
        self.coverSide = coverSide
    }

    static func label(count: Int) -> String { "You own \(count) copies of this album" }

    public var body: some View {
        let size = max(9, min(13, coverSide * 0.07))
        HStack(spacing: size * 0.25) {
            Image(systemName: "square.on.square").font(.system(size: size * 0.85, weight: .semibold))
            Text(count.formatted()).font(.system(size: size, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.65)))
        .explainsMeaning(Self.label(count: count))
        .padding(max(4, coverSide * 0.035))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) copies")
    }
}

/// What you own of an album, on a cover shown without its case: your label in the top-left corner (a pill, or the
/// sticker on a small cover), badges in the bottom-right and the number of copies in the top-right.
public struct CoverCopyMark: View {
    let mark: CopyMark?
    /// The cover's side.
    let size: CGFloat
    var iCloud: ICloudPlacement

    public init(mark: CopyMark?, size: CGFloat, iCloud: ICloudPlacement = .onMac) {
        self.mark = mark
        self.size = size
        self.iCloud = iCloud
    }

    public var body: some View {
        ZStack {
            if let sticker = mark?.sticker {
                if size >= 90 {
                    StickerPill(sticker: sticker, size: max(9, min(14, size * 0.075)), numberOnly: true)
                        .padding(size * 0.04)
                        .frame(width: size, height: size, alignment: .topLeading)
                } else {
                    LabelSticker.onCover(sticker, size: size)
                }
            }
            CopyBadges(mark: mark, iCloud: iCloud, coverSide: size)
                .frame(width: size, height: size, alignment: .bottomTrailing)
            if let mark, mark.more > 0, size >= 90 {
                CopiesChip(count: mark.more + 1, coverSide: size).frame(width: size, height: size, alignment: .topTrailing)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Saying what a mark means

extension EnvironmentValues {
    /// Whether a cover's marks say what they mean when pressed and held (iPhone). Off where the cover has its own
    /// context menu (the long press is the menu's): the menu lists what they mean instead (`CopyMark.meanings`).
    /// (Written out rather than with `@Entry`: the Command Line Tools don't ship SwiftUI's macro plugin.)
    public var explainsMarksOnPress: Bool {
        get { self[ExplainsMarksOnPressKey.self] }
        set { self[ExplainsMarksOnPressKey.self] = newValue }
    }
}

private struct ExplainsMarksOnPressKey: EnvironmentKey {
    static let defaultValue = true
}

extension View {
    /// What a mark means, in words: a tooltip on the Mac, a bubble on a press and hold on the iPhone (unless
    /// `onPress` is false, for marks in rows whose press and hold is the row's).
    public func explainsMeaning(_ text: String, onPress: Bool = true) -> some View {
        #if os(macOS)
        help(text)
        #else
        modifier(ExplainOnLongPress(text: text, enabledHere: onPress))
        #endif
    }
}

#if !os(macOS)
/// Press and hold a cover's sticker, badge or copies chip to see what it means in a small bubble: the iPhone's
/// stand-in for the Mac's tooltips.
struct ExplainOnLongPress: ViewModifier {
    let text: String
    let enabledHere: Bool
    @Environment(\.explainsMarksOnPress) private var enabled
    @State private var shown = false

    func body(content: Content) -> some View {
        if enabled, enabledHere { explained(content) } else { content }
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
#endif
