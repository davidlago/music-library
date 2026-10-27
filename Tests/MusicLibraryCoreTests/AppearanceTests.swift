import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct AppearanceTests {
    /// Every theme ID 1.27 could store, with the mode it becomes: themes with both variants followed the system,
    /// the rest forced their one variant.
    static let legacyThemes: [(String, AppearanceMode)] = [
        ("system", .system),
        ("catppuccin", .system), ("catppuccin-latte", .light), ("catppuccin-frappe", .dark),
        ("catppuccin-macchiato", .dark), ("catppuccin-mocha", .dark),
        ("nord", .dark), ("dracula", .dark),
        ("solarized", .system), ("solarized-light", .light), ("solarized-dark", .dark),
        ("gruvbox", .dark), ("tokyo-night", .dark),
        ("rose-pine", .system), ("rose-pine-main", .dark), ("rose-pine-dawn", .light),
    ]

    @Test func everyLegacyThemeMapsToItsMode() {
        for (id, mode) in Self.legacyThemes {
            #expect(AppearanceMode.migrating(legacyThemeID: id) == mode, "\(id)")
            #expect(AppearanceMode.resolve(stored: nil, legacyTheme: id) == mode, "\(id)")
        }
        // The table above covers every ID the lists know about.
        let known = AppearanceMode.legacyLightThemes.union(AppearanceMode.legacyDarkThemes)
        #expect(known.isSubset(of: Set(Self.legacyThemes.map(\.0))))
    }

    @Test func unknownOrMissingThemesFollowTheSystem() {
        #expect(AppearanceMode.migrating(legacyThemeID: nil) == .system)
        #expect(AppearanceMode.migrating(legacyThemeID: "") == .system)
        #expect(AppearanceMode.migrating(legacyThemeID: "Nord") == .system)
        #expect(AppearanceMode.resolve(stored: nil, legacyTheme: nil) == .system)
    }

    @Test func storedChoiceWinsOverALegacyTheme() {
        #expect(AppearanceMode.resolve(stored: "light", legacyTheme: "nord") == .light)
        #expect(AppearanceMode.resolve(stored: "system", legacyTheme: "dracula") == .system)
        // A value this version can't read falls back to the legacy theme, then the system.
        #expect(AppearanceMode.resolve(stored: "sepia", legacyTheme: "solarized-light") == .light)
        #expect(AppearanceMode.resolve(stored: "sepia", legacyTheme: nil) == .system)
    }

    @Test func readsBackFromUserDefaults() throws {
        let suite = "AppearanceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("catppuccin-mocha", forKey: AppearanceMode.legacyThemeKey)
        let resolve = {
            AppearanceMode.resolve(stored: defaults.string(forKey: AppearanceMode.defaultsKey),
                                   legacyTheme: defaults.string(forKey: AppearanceMode.legacyThemeKey))
        }
        #expect(resolve() == .dark)
        defaults.set(AppearanceMode.light.rawValue, forKey: AppearanceMode.defaultsKey)
        #expect(resolve() == .light)
        #expect(AppearanceMode.allCases.map(\.name) == ["System", "Light", "Dark"])
    }

    @Test func colorMath() {
        #expect(RGB(0x1e66f5).hexString == "#1e66f5")
        #expect(RGB.black.mix(.white, 0.5).hex == 0x808080)
        #expect(abs(RGB.black.contrast(with: .white) - 21) < 0.001)
    }
}
