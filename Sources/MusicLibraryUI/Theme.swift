import MusicLibraryCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The colours and card surfaces both apps draw with. Native colours throughout, so they follow light and dark; where
// the Mac and the iPhone have their own idiom (a card on a window vs. a grouped list) the difference stays here.

extension Color {
    /// A colour from Core's `RGB` (artwork tints, panels).
    public init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }

    /// A colour with separate sRGB values for the light and dark appearances.
    public init(light: UInt32, dark: UInt32) {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255)
        }
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = components(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

/// The colours views draw with, all native, so they follow the light or dark appearance.
public enum AppColor {
    #if os(macOS)
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let card = Color(nsColor: .controlBackgroundColor)
    public static let separator = Color(nsColor: .separatorColor)
    #else
    public static let background = Color(.systemGroupedBackground)
    public static let card = Color(.secondarySystemGroupedBackground)
    public static let separator = Color(.separator)
    #endif
    public static let accent = Color.accentColor
    public static let series = VizColor.series
    /// The unfilled part of bar and progress tracks.
    public static let track = VizColor.track
    /// Reference marks drawn next to `series`, like the library's share beside your listening.
    public static let neutral = VizColor.neutral
    /// Subtle fills for hover states and chips.
    public static let fill = Color.primary.opacity(0.06)
    /// The Listening report's panels when there's no picture to take a colour from.
    public static let defaultPanel = ArtworkTint.panel(from: RGB(0x2a78d6))

    public static func tier(_ t: LibraryStats.QualityTier) -> Color { VizColor.tier(t) }
}

/// Chart colours, validated for contrast and colour-vision deficiency against the card surface in both appearances.
public enum VizColor {
    /// Single-series marks.
    public static let series = Color(light: 0x2a78d6, dark: 0x3987e5)

    /// Ordinal blue ramp for quality tiers, best quality most prominent; "unknown" is neutral grey.
    public static func tier(_ t: LibraryStats.QualityTier) -> Color {
        switch t {
        case .hiRes: Color(light: 0x104281, dark: 0xcde2fb)
        case .cd: Color(light: 0x256abf, dark: 0x86b6ef)
        case .lossyHigh: Color(light: 0x5598e7, dark: 0x3987e5)
        case .lossy: Color(light: 0x86b6ef, dark: 0x1c5cab)
        case .unknown: neutral
        }
    }

    /// Secondary series (the library next to your listening).
    public static let neutral = Color(light: 0xb5b4ae, dark: 0x5f5e5a)
    public static let card = AppColor.card
    /// The empty part of a bar.
    public static let track = Color.primary.opacity(0.07)
}

/// Sizes that differ between the Mac's window and the iPhone's screen; everything else is shared.
public enum Metrics {
    #if os(macOS)
    public static let cardRadius: CGFloat = 12
    #else
    public static let cardRadius: CGFloat = 14
    #endif
}

extension View {
    /// A rounded card on the page: on the Mac a control-background panel with a hairline edge, on the iPhone a grouped
    /// cell's surface.
    public func card(padding: CGFloat = 0) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
        #if os(macOS)
        return self.padding(padding)
            .background(shape.fill(AppColor.card))
            .overlay(shape.strokeBorder(AppColor.separator.opacity(0.6), lineWidth: 0.5))
        #else
        return self.padding(padding)
            .background(shape.fill(AppColor.card))
        #endif
    }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    static let valueSize: CGFloat = 26, spacing: CGFloat = 4, padding: CGFloat = 14
    #else
    static let valueSize: CGFloat = 22, spacing: CGFloat = 3, padding: CGFloat = 12
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(height: 20)
            Text(value).font(.system(size: Self.valueSize, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
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
    static let valueSize: CGFloat = 22, spacing: CGFloat = 4
    #else
    static let valueSize: CGFloat = 20, spacing: CGFloat = 3
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: Self.valueSize, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A page section's title.
public struct SectionHeader: View {
    let title: String

    public init(title: String) { self.title = title }

    public var body: some View {
        #if os(macOS)
        Text(title).font(.title2.bold())
        #else
        Text(title).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}
