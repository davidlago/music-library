import MusicLibraryCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The colours, type and surfaces both apps draw with, in light and dark; where the Mac and the iPhone have their own
// idiom the difference stays here.

extension Color {
    /// A colour from Core's `RGB` (artwork tints, panels).
    public init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }

    /// A colour with separate sRGB values for the light and dark appearances.
    public init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: .dynamic(light: light, dark: dark))
        #else
        self.init(uiColor: .dynamic(light: light, dark: dark))
        #endif
    }
}

private func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
}

#if os(macOS)
extension NSColor {
    /// A colour with separate sRGB values for the light and dark appearances.
    public static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let (r, g, b) = components(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }
}
#else
extension UIColor {
    /// A colour with separate sRGB values for the light and dark appearances.
    public static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }

    /// The brass accent, for UIKit's tint (alerts, bars, the tab bar's selection).
    public static let appAccent = UIColor.dynamic(light: AppColor.accentHex.light, dark: AppColor.accentHex.dark)
}
#endif

/// The app's palette. Dark is the house look, taken from a record shop at night: warm ink pages, a slightly lighter panel
/// for cards and the sidebar, cream type and a brass accent. Light is the same shop by day: cream paper, near-white
/// cards, ink type and a deeper brass that still reads on paper.
public enum AppColor {
    /// The page.
    public static let background = Color(light: 0xF4EFE6, dark: 0x0F0E0D)
    /// Cards, panels, the sidebar and the player.
    public static let card = Color(light: 0xFCFAF5, dark: 0x1A1816)
    /// A surface on a card (a hovered row, a chip, a field), and the sidebar's selection.
    public static let raised = Color(light: 0xEBE4D7, dark: 0x24211E)
    /// The sidebar, a step away from the page.
    public static let sidebar = Color(light: 0xECE5D8, dark: 0x1A1816)
    /// Type: cream on ink, ink on paper.
    public static let text = Color(light: 0x1A1816, dark: 0xF3EDE2)
    /// Secondary type.
    public static let muted = Color(light: 0x6B655C, dark: 0xA69E91)
    /// Tertiary type and quiet marks.
    public static let faint = Color(light: 0x9C958A, dark: 0x6B655C)
    /// The brass accent: kickers, section bars, the playing song, primary buttons.
    public static let accent = Color(light: accentHex.light, dark: accentHex.dark)
    static let accentHex: (light: UInt32, dark: UInt32) = (0x8F6200, 0xE9B949)
    /// Type and symbols drawn on the accent.
    public static let onAccent = Color(light: 0xFCFAF5, dark: 0x0F0E0D)
    public static let separator = Color(light: 0xDCD3C3, dark: 0x2E2A26)
    public static let series = VizColor.series
    /// The unfilled part of bar and progress tracks.
    public static let track = VizColor.track
    /// Reference marks drawn next to `series`, like the library's share beside your listening.
    public static let neutral = VizColor.neutral
    /// Subtle fills for hover states and chips.
    public static let fill = Color(light: 0x1A1816, dark: 0xF3EDE2).opacity(0.07)
    /// The Listening report's panels when there's no picture to take a colour from.
    public static let defaultPanel = ArtworkTint.panel(from: RGB(0x8F6200))

    public static func tier(_ t: LibraryStats.QualityTier) -> Color { VizColor.tier(t) }

    /// Colours for tags (genres): bright on ink, deeper on paper so they read as text there too.
    static let tags: [Color] = [
        Color(light: 0xB3242B, dark: 0xE2373F), Color(light: 0x2253B5, dark: 0x5B8BE8),
        Color(light: 0x5E3FC0, dark: 0x8F74E6), Color(light: 0x0E7F76, dark: 0x19D3C5),
        Color(light: 0xB35A16, dark: 0xE8833A), Color(light: 0xC23A73, dark: 0xF0679E),
        Color(light: 0x1F7F5F, dark: 0x34B58C), Color(light: 0x9233A6, dark: 0xC04FD4),
        Color(light: 0x2F6E9E, dark: 0x8EC5E8), Color(light: 0x8A5032, dark: 0xC48766),
        Color(light: 0x5A7A18, dark: 0x8DB43C),
    ]

    /// A tag's colour: the same for the same name on every launch and device (FNV-1a of its lowercased letters).
    public static func tag(_ name: String) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 where byte != 0x20 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return tags[Int(hash % UInt64(tags.count))]
    }
}

/// Chart colours: brass marks on the card surface in both appearances, checked for contrast against it.
public enum VizColor {
    /// Single-series marks.
    public static let series = Color(light: 0x9A6A00, dark: 0xE9B949)

    /// Ordinal brass ramp for quality tiers, best quality most prominent; "unknown" is neutral.
    public static func tier(_ t: LibraryStats.QualityTier) -> Color {
        switch t {
        case .hiRes: Color(light: 0x5C3E00, dark: 0xF6DC9A)
        case .cd: Color(light: 0x8F6200, dark: 0xE9B949)
        case .lossyHigh: Color(light: 0xC4922C, dark: 0xB0832A)
        case .lossy: Color(light: 0xE3C67F, dark: 0x765923)
        case .unknown: neutral
        }
    }

    /// Secondary series (the library next to your listening).
    public static let neutral = Color(light: 0xC2B8A8, dark: 0x57514A)
    public static let card = AppColor.card
    /// The empty part of a bar.
    public static let track = AppColor.fill
}

/// The app's type. Display type is heavy and condensed, set in capitals like a record sleeve's; labels are small,
/// wide and tracked out; long reading (album notes, biographies) is serif.
public enum AppFont {
    /// Page titles: an album, an artist, a copy, a section's name.
    public static func display(_ size: CGFloat, weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    /// Kickers and section titles; set in capitals with `tracking`.
    public static func label(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    /// Reading text.
    public static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Sizes that differ between the Mac's window and the iPhone's screen; everything else is shared.
public enum Metrics {
    #if os(macOS)
    public static let cardRadius: CGFloat = 10
    #else
    public static let cardRadius: CGFloat = 12
    #endif
}

extension View {
    /// A panel on the page: a step lighter than the page in the dark, near-white on paper in the light, with a hairline.
    public func card(padding: CGFloat = 0) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        return self.padding(padding)
            .background(shape.fill(AppColor.card))
            .overlay(shape.strokeBorder(AppColor.separator.opacity(0.7), lineWidth: 0.5))
    }

    /// A page's surface: the page colour behind it, cream (or ink) type, and lists and forms drawn on the page rather
    /// than on the system's grey.
    public func pageBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(AppColor.background)
    }

    /// The app's colours for everything inside: the brass accent and the palette's type.
    public func appPalette() -> some View {
        self.tint(AppColor.accent)
            .foregroundStyle(AppColor.text)
    }
}

// MARK: Type pieces

/// A small line over a title, tracked out in capitals in the accent ("ALBUM · 1959").
public struct Kicker: View {
    let text: String
    var color: Color

    public init(_ text: String, color: Color = AppColor.accent) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text.uppercased())
            .font(AppFont.label(11)).tracking(2.4)
            .foregroundStyle(color)
    }
}

/// A page's title in poster type: heavy condensed capitals.
public struct PageTitle: View {
    let text: String
    var size: CGFloat
    var lineLimit: Int

    public init(_ text: String, size: CGFloat = PageTitle.defaultSize, lineLimit: Int = 3) {
        self.text = text
        self.size = size
        self.lineLimit = lineLimit
    }

    #if os(macOS)
    public static let defaultSize: CGFloat = 52
    #else
    public static let defaultSize: CGFloat = 40
    #endif

    public var body: some View {
        Text(text.uppercased())
            .font(AppFont.display(size))
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.45)
            .lineSpacing(-size * 0.12)
            .foregroundStyle(AppColor.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tag in a capsule: tinted text on a faint wash of its colour with an edge (genres, formats, states).
public struct TagChip: View {
    let text: String
    var tint: Color

    public init(_ text: String, tint: Color = AppColor.accent) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.13)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

/// A list's or a form's section title: small tracked-out capitals in brass, for `Section { } header: { }`.
public struct ListHeader: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title.uppercased())
            .font(AppFont.label(11))
            .tracking(1.8)
            .foregroundStyle(AppColor.accent)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Buttons

/// The page's main action (Play): a brass capsule with ink type.
public struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(small ? .callout.weight(.semibold) : .body.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, small ? 10 : 16).padding(.vertical, small ? 4 : 7)
            .foregroundStyle(AppColor.onAccent)
            .background(Capsule().fill(AppColor.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// A page's other actions (Shuffle, Open in Music): an outlined capsule.
public struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(small ? .callout.weight(.medium) : .body.weight(.medium))
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 4 : 7)
            .foregroundStyle(AppColor.text)
            .background(Capsule().fill(configuration.isPressed ? AppColor.fill : .clear))
            .overlay(Capsule().strokeBorder(AppColor.text.opacity(0.35), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == ProminentButtonStyle {
    /// The page's main action: a brass capsule.
    public static var prominent: ProminentButtonStyle { ProminentButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    /// A page's other actions: an outlined capsule.
    public static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

// MARK: Cards and tiles

/// A titled card. The accessory (a picker, a link) sits beside the title on the Mac and under it on the iPhone.
public struct InsightCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var accessory: Accessory
    var content: Content

    public init(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            HStack(alignment: .firstTextBaseline) {
                heading
                Spacer()
                accessory
            }
            #else
            heading
            accessory
            #endif
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(AppFont.label(11.5)).tracking(1.8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(AppColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension InsightCard where Accessory == EmptyView {
    public init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A big number with a label, and optionally a line of context under it.
public struct InsightTile: View {
    let value: String
    let label: String
    let icon: String
    var detail: String?

    public init(value: String, label: String, icon: String, detail: String? = nil) {
        self.value = value
        self.label = label
        self.icon = icon
        self.detail = detail
    }

    #if os(macOS)
    static let valueSize: CGFloat = 32, spacing: CGFloat = 4, padding: CGFloat = 14
    #else
    static let valueSize: CGFloat = 28, spacing: CGFloat = 3, padding: CGFloat = 12
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Image(systemName: icon).font(.callout).foregroundStyle(AppColor.accent).frame(height: 20)
            Text(value).font(AppFont.display(Self.valueSize, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(AppFont.label(9.5)).tracking(1.4).foregroundStyle(AppColor.muted).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(AppColor.muted).lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A smaller number with a label (album and artist pages).
public struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    public init(value: String, label: String, icon: String) {
        self.value = value
        self.label = label
        self.icon = icon
    }

    #if os(macOS)
    static let valueSize: CGFloat = 28, spacing: CGFloat = 4
    #else
    static let valueSize: CGFloat = 24, spacing: CGFloat = 3
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Image(systemName: icon).font(.callout).foregroundStyle(AppColor.accent)
            Text(value).font(AppFont.display(Self.valueSize, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(AppFont.label(9.5)).tracking(1.4).foregroundStyle(AppColor.muted).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A page section's title: a short brass bar and the title in tracked-out capitals.
public struct SectionHeader: View {
    let title: String
    var tint: Color

    public init(title: String, tint: Color = AppColor.accent) {
        self.title = title
        self.tint = tint
    }

    #if os(macOS)
    static let size: CGFloat = 13, bar: CGFloat = 26
    #else
    static let size: CGFloat = 12.5, bar: CGFloat = 22
    #endif

    public var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(tint).frame(width: Self.bar, height: 4)
            Text(title.uppercased()).font(AppFont.label(Self.size)).tracking(2.2).foregroundStyle(AppColor.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
