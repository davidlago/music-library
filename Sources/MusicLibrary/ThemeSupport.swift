import AppKit
import MusicLibraryCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// The colors views draw with. With no palette (the System theme) everything falls back to native macOS colors.
struct ThemeColors {
    var palette: ThemePalette?

    var isThemed: Bool { palette != nil }
    var background: Color { palette.map { Color($0.base) } ?? Color(nsColor: .windowBackgroundColor) }
    var sidebar: Color { palette.map { Color($0.mantle) } ?? .clear }
    var card: Color { palette.map { Color($0.card) } ?? Color(nsColor: .controlBackgroundColor) }
    var separator: Color { palette.map { Color($0.separator) } ?? Color(nsColor: .separatorColor) }
    var accent: Color { palette.map { Color($0.accent) } ?? .accentColor }
    var series: Color { palette.map { Color($0.series) } ?? VizColor.series }
    /// The unfilled part of bar and progress tracks.
    var track: Color { palette.map { Color($0.surface).opacity(0.7) } ?? Color.primary.opacity(0.07) }
    /// Reference marks drawn next to `series`, like the library's share beside your listening.
    var neutral: Color { palette.map { Color($0.neutral) } ?? VizColor.tier(.unknown) }
    /// Subtle fills for hover states and chips.
    var fill: Color { palette.map { Color($0.surface).opacity(0.55) } ?? Color.primary.opacity(0.06) }

    var primaryText: AnyShapeStyle { palette.map { AnyShapeStyle(Color($0.text)) } ?? AnyShapeStyle(.primary) }
    var secondaryText: AnyShapeStyle { palette.map { AnyShapeStyle(Color($0.subtext)) } ?? AnyShapeStyle(.secondary) }
    var tertiaryText: AnyShapeStyle { palette.map { AnyShapeStyle(Color($0.subtext).opacity(0.75)) } ?? AnyShapeStyle(.tertiary) }

    /// The player bar and other chrome.
    var bar: AnyShapeStyle { palette.map { AnyShapeStyle(Color($0.mantle)) } ?? AnyShapeStyle(.bar) }
    var toolbar: AnyShapeStyle { palette.map { AnyShapeStyle(Color($0.mantle)) } ?? AnyShapeStyle(.windowBackground) }

    func tier(_ t: LibraryStats.QualityTier) -> Color {
        guard let palette else { return VizColor.tier(t) }
        let ramp = palette.ordinalRamp
        switch t {
        case .hiRes: return Color(ramp[0])
        case .cd: return Color(ramp[1])
        case .lossyHigh: return Color(ramp[2])
        case .lossy: return Color(ramp[3])
        case .unknown: return Color(palette.neutral)
        }
    }
}

/// Secondary text that follows the theme. `Text` resolves `.secondary` as the primary color at reduced
/// opacity, ignoring custom hierarchical styles, which is too faint on themed backgrounds; this resolves to
/// the theme's own secondary text color instead (and to the native `.secondary` for the System theme).
struct ThemedSecondaryStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if let p = environment.theme.palette { return AnyShapeStyle(Color(p.subtext)) }
        return AnyShapeStyle(.secondary)
    }
}

extension ShapeStyle where Self == ThemedSecondaryStyle {
    /// Use instead of `.secondary` for text.
    static var subtext: ThemedSecondaryStyle { ThemedSecondaryStyle() }
}

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors()
}

extension EnvironmentValues {
    var theme: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }
}

/// Resolves the chosen theme for the window's appearance and applies it to everything inside.
struct ThemedRoot: ViewModifier {
    let theme: Theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let colors = ThemeColors(palette: theme.palette(dark: scheme == .dark))
        content
            .environment(\.theme, colors)
            .tint(colors.palette.map { Color($0.accent) })
            .foregroundStyle(colors.primaryText, colors.secondaryText, colors.tertiaryText)
            .background(colors.isThemed ? colors.background : Color.clear)
            .preferredColorScheme(theme.forcedDark.map { $0 ? .dark : .light })
    }
}

/// Lets a themed background show through lists, tables and forms instead of their native fill.
struct ThemedScrollBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(theme.isThemed ? .hidden : .automatic)
            .alternatingRowBackgrounds(theme.isThemed ? .disabled : .automatic)
    }
}

/// Background for sheets, which otherwise use the native window color.
struct ThemedSheet: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.isThemed ? theme.background : Color.clear)
    }
}

extension View {
    func themedRoot(_ theme: Theme) -> some View { modifier(ThemedRoot(theme: theme)) }
    func themedScrollBackground() -> some View { modifier(ThemedScrollBackground()) }
    func themedSheet() -> some View { modifier(ThemedSheet()) }
}

/// A small preview of a theme: sidebar, content with a card, accent and chart colors.
struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if theme.isSystem {
                    HStack(spacing: 0) {
                        preview(nil, dark: false)
                        preview(nil, dark: true)
                    }
                } else if let light = theme.light, let dark = theme.dark {
                    HStack(spacing: 0) {
                        preview(light, dark: false)
                        preview(dark, dark: true)
                    }
                } else if let p = theme.light ?? theme.dark {
                    preview(p, dark: p.isDark)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                     lineWidth: selected ? 2.5 : 0.5))
            HStack(spacing: 4) {
                Text(theme.name).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
                if theme.followsSystemAppearance && !theme.isSystem {
                    Image(systemName: "circle.lefthalf.filled").font(.caption2).foregroundStyle(.subtext)
                        .help("Follows the system light/dark setting")
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func preview(_ p: ThemePalette?, dark: Bool) -> some View {
        let base = p.map { Color($0.base) } ?? (dark ? Color(white: 0.16) : Color(white: 0.96))
        let side = p.map { Color($0.mantle) } ?? (dark ? Color(white: 0.12) : Color(white: 0.9))
        let card = p.map { Color($0.card) } ?? (dark ? Color(white: 0.21) : .white)
        let text = p.map { Color($0.text) } ?? (dark ? Color(white: 0.9) : Color(white: 0.15))
        let accent = p.map { Color($0.accent) } ?? .accentColor
        let series = p.map { Color($0.series) } ?? VizColor.series
        return HStack(spacing: 0) {
            side.frame(width: 18)
                .overlay(alignment: .top) {
                    VStack(spacing: 4) {
                        Capsule().fill(accent).frame(width: 10, height: 3)
                        Capsule().fill(text.opacity(0.5)).frame(width: 10, height: 3)
                        Capsule().fill(text.opacity(0.5)).frame(width: 10, height: 3)
                    }
                    .padding(.top, 8)
                }
            base.overlay {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(text).frame(width: 34, height: 4)
                    RoundedRectangle(cornerRadius: 3).fill(card)
                        .overlay(alignment: .bottomLeading) {
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach([0.5, 0.8, 0.6, 1.0], id: \.self) { h in
                                    RoundedRectangle(cornerRadius: 1).fill(series).frame(width: 5, height: 22 * h)
                                }
                            }
                            .padding(4)
                        }
                }
                .padding(7)
            }
        }
    }
}
