import Foundation

/// Light or dark: the app's only look setting. `system` follows the Mac's or iPhone's setting.
/// Custom themes were removed in favor of this; `resolve` maps a theme chosen in an older version to its mode.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The user defaults key holding the choice, on the Mac and the iPhone.
    public static let defaultsKey = "appearance"
    /// Where versions before 1.28 kept the chosen theme's ID (Mac only). Read once to pick the mode, never written.
    public static let legacyThemeKey = "theme"

    /// The mode to use: the stored choice when there is one, else the mode of a theme an older version stored.
    public static func resolve(stored: String?, legacyTheme: String?) -> AppearanceMode {
        if let stored, let mode = AppearanceMode(rawValue: stored) { return mode }
        return migrating(legacyThemeID: legacyTheme)
    }

    /// A removed theme's mode: themes with a light and a dark variant followed the system, the rest forced
    /// the one variant they had. Unknown IDs (and System) follow the system.
    public static func migrating(legacyThemeID id: String?) -> AppearanceMode {
        guard let id else { return .system }
        if legacyLightThemes.contains(id) { return .light }
        if legacyDarkThemes.contains(id) { return .dark }
        return .system
    }

    /// The IDs of 1.27's themes that only came in light or only in dark; every other ID followed the system
    /// ("system", "catppuccin", "solarized", "rose-pine").
    static let legacyLightThemes: Set<String> = ["catppuccin-latte", "solarized-light", "rose-pine-dawn"]
    static let legacyDarkThemes: Set<String> = [
        "catppuccin-frappe", "catppuccin-macchiato", "catppuccin-mocha", "nord", "dracula",
        "solarized-dark", "gruvbox", "tokyo-night", "rose-pine-main",
    ]
}
