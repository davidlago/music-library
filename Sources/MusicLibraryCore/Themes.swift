import Foundation

/// An sRGB color with the arithmetic needed to derive and check theme colors.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
    }

    public static let white = RGB(0xffffff)
    public static let black = RGB(0x000000)

    public var hex: UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }

    public var hexString: String { String(format: "#%06x", hex) }

    /// `self` moved toward `other` by `t` (0 = self, 1 = other).
    public func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio (1…21).
    public func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The colors of one light or dark theme variant. Only the base colors are spelled out; the rest is derived,
/// so adding a theme means filling in eight colors.
public struct ThemePalette: Hashable, Sendable {
    public var isDark: Bool
    /// Main content background.
    public var base: RGB
    /// Sidebar and toolbar; usually a step darker than `base`.
    public var mantle: RGB
    /// Raised controls, separators and hover fills.
    public var surface: RGB
    public var text: RGB
    public var subtext: RGB
    /// Selection, buttons and links.
    public var accent: RGB
    /// Single-series chart marks.
    public var series: RGB

    public init(isDark: Bool, base: UInt32, mantle: UInt32, surface: UInt32, text: UInt32, subtext: UInt32, accent: UInt32, series: UInt32) {
        self.isDark = isDark
        self.base = RGB(base); self.mantle = RGB(mantle); self.surface = RGB(surface)
        self.text = RGB(text); self.subtext = RGB(subtext); self.accent = RGB(accent); self.series = RGB(series)
    }

    /// Cards and panels: lifted toward `surface` on dark themes, toward white on light ones.
    public var card: RGB { isDark ? base.mix(surface, 0.45) : base.mix(.white, 0.6) }
    public var separator: RGB { isDark ? surface : base.mix(surface, 0.7) }

    /// Four steps of decreasing prominence for ordered categories (e.g. audio quality tiers), from `series`
    /// toward the card color. The faintest step keeps at least 2:1 contrast against the card.
    public var ordinalRamp: [RGB] {
        let minimum = 2.0
        var lo = 0.0, hi = 1.0
        if card.mix(series, 1).contrast(with: card) <= minimum {
            lo = 1
        } else {
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if card.mix(series, mid).contrast(with: card) >= minimum { hi = mid } else { lo = mid }
            }
            lo = hi
        }
        let faintest = min(1, lo + 0.04)
        return (0..<4).map { i in card.mix(series, 1 - (1 - faintest) * Double(i) / 3) }
    }

    /// Count badges (sidebar): a `subtext` pill with the number in the sidebar color, so it reads as a cut-out.
    public var badgeFill: RGB { subtext }
    public var badgeText: RGB { mantle }

    /// For "unknown" buckets next to the ramp.
    public var neutral: RGB { card.mix(subtext, 0.5) }
}

public struct Theme: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var family: String
    public var light: ThemePalette?
    public var dark: ThemePalette?

    public init(id: String, name: String, family: String, light: ThemePalette? = nil, dark: ThemePalette? = nil) {
        self.id = id; self.name = name; self.family = family; self.light = light; self.dark = dark
    }

    /// The native macOS look: no palette at all.
    public var isSystem: Bool { light == nil && dark == nil }
    /// Whether the theme has both variants and follows the system appearance.
    public var followsSystemAppearance: Bool { isSystem || (light != nil && dark != nil) }
    /// The appearance the theme forces, if it only comes in one variant.
    public var forcedDark: Bool? {
        switch (light, dark) {
        case (nil, .some): true
        case (.some, nil): false
        default: nil
        }
    }

    public func palette(dark isDark: Bool) -> ThemePalette? {
        isDark ? (dark ?? light) : (light ?? dark)
    }

    public static func named(_ id: String?) -> Theme { all.first { $0.id == id } ?? system }
}

extension Theme {
    public static let system = Theme(id: "system", name: "System", family: "System")

    static let catppuccinLatte = ThemePalette(isDark: false, base: 0xeff1f5, mantle: 0xe6e9ef, surface: 0xccd0da,
                                              text: 0x4c4f69, subtext: 0x5c5f77, accent: 0x8839ef, series: 0x1e66f5)
    static let catppuccinFrappe = ThemePalette(isDark: true, base: 0x303446, mantle: 0x292c3c, surface: 0x414559,
                                               text: 0xc6d0f5, subtext: 0xa5adce, accent: 0xca9ee6, series: 0x8caaee)
    static let catppuccinMacchiato = ThemePalette(isDark: true, base: 0x24273a, mantle: 0x1e2030, surface: 0x363a4f,
                                                  text: 0xcad3f5, subtext: 0xa5adcb, accent: 0xc6a0f6, series: 0x8aadf4)
    static let catppuccinMocha = ThemePalette(isDark: true, base: 0x1e1e2e, mantle: 0x181825, surface: 0x313244,
                                              text: 0xcdd6f4, subtext: 0xa6adc8, accent: 0xcba6f7, series: 0x89b4fa)
    static let solarizedLight = ThemePalette(isDark: false, base: 0xfdf6e3, mantle: 0xeee8d5, surface: 0xddd6c1,
                                             text: 0x073642, subtext: 0x586e75, accent: 0x268bd2, series: 0x268bd2)
    static let solarizedDark = ThemePalette(isDark: true, base: 0x002b36, mantle: 0x00212b, surface: 0x073642,
                                            text: 0x93a1a1, subtext: 0x839496, accent: 0x268bd2, series: 0x2aa198)
    static let rosePine = ThemePalette(isDark: true, base: 0x191724, mantle: 0x13111d, surface: 0x26233a,
                                       text: 0xe0def4, subtext: 0x908caa, accent: 0xebbcba, series: 0x9ccfd8)
    static let rosePineDawn = ThemePalette(isDark: false, base: 0xfaf4ed, mantle: 0xf2e9e1, surface: 0xdfdad9,
                                           text: 0x575279, subtext: 0x6e6a86, accent: 0x907aa9, series: 0x286983)

    /// Predefined themes in display order.
    public static let all: [Theme] = [
        system,
        Theme(id: "catppuccin", name: "Catppuccin", family: "Catppuccin", light: catppuccinLatte, dark: catppuccinMocha),
        Theme(id: "catppuccin-latte", name: "Catppuccin Latte", family: "Catppuccin", light: catppuccinLatte),
        Theme(id: "catppuccin-frappe", name: "Catppuccin Frappé", family: "Catppuccin", dark: catppuccinFrappe),
        Theme(id: "catppuccin-macchiato", name: "Catppuccin Macchiato", family: "Catppuccin", dark: catppuccinMacchiato),
        Theme(id: "catppuccin-mocha", name: "Catppuccin Mocha", family: "Catppuccin", dark: catppuccinMocha),
        Theme(id: "nord", name: "Nord", family: "Nord",
              dark: ThemePalette(isDark: true, base: 0x2e3440, mantle: 0x272c36, surface: 0x3b4252,
                                 text: 0xe5e9f0, subtext: 0xa7b1c2, accent: 0x88c0d0, series: 0x81a1c1)),
        Theme(id: "dracula", name: "Dracula", family: "Dracula",
              dark: ThemePalette(isDark: true, base: 0x282a36, mantle: 0x21222c, surface: 0x44475a,
                                 text: 0xf8f8f2, subtext: 0xa9b1d6, accent: 0xbd93f9, series: 0x8be9fd)),
        Theme(id: "solarized", name: "Solarized", family: "Solarized", light: solarizedLight, dark: solarizedDark),
        Theme(id: "solarized-light", name: "Solarized Light", family: "Solarized", light: solarizedLight),
        Theme(id: "solarized-dark", name: "Solarized Dark", family: "Solarized", dark: solarizedDark),
        Theme(id: "gruvbox", name: "Gruvbox", family: "Gruvbox",
              dark: ThemePalette(isDark: true, base: 0x282828, mantle: 0x1d2021, surface: 0x3c3836,
                                 text: 0xebdbb2, subtext: 0xa89984, accent: 0xfe8019, series: 0x83a598)),
        Theme(id: "tokyo-night", name: "Tokyo Night", family: "Tokyo Night",
              dark: ThemePalette(isDark: true, base: 0x1a1b26, mantle: 0x16161e, surface: 0x292e42,
                                 text: 0xc0caf5, subtext: 0x9aa5ce, accent: 0x7aa2f7, series: 0x7dcfff)),
        Theme(id: "rose-pine", name: "Rosé Pine", family: "Rosé Pine", light: rosePineDawn, dark: rosePine),
        Theme(id: "rose-pine-main", name: "Rosé Pine Main", family: "Rosé Pine", dark: rosePine),
        Theme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", family: "Rosé Pine", light: rosePineDawn),
    ]
}
