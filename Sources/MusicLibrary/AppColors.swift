import AppKit
import MusicLibraryCore
import SwiftUI

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// The colors views draw with, all native macOS colors, so they follow the light or dark appearance.
enum AppColor {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let series = VizColor.series
    /// The unfilled part of bar and progress tracks.
    static let track = Color.primary.opacity(0.07)
    /// Reference marks drawn next to `series`, like the library's share beside your listening.
    static let neutral = VizColor.tier(.unknown)
    /// Subtle fills for hover states and chips.
    static let fill = Color.primary.opacity(0.06)

    static func tier(_ t: LibraryStats.QualityTier) -> Color { VizColor.tier(t) }
}

/// A small preview of an appearance: sidebar, content with a card, accent and chart colors. System shows both halves.
struct AppearanceSwatch: View {
    let mode: AppearanceMode
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                switch mode {
                case .system:
                    preview(dark: false)
                    preview(dark: true)
                case .light: preview(dark: false)
                case .dark: preview(dark: true)
                }
            }
            .frame(width: 150, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                     lineWidth: selected ? 3 : 0.5))
            Text(mode.name).font(.callout.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }

    private func preview(dark: Bool) -> some View {
        let base = dark ? Color(white: 0.16) : Color(white: 0.96)
        let side = dark ? Color(white: 0.12) : Color(white: 0.9)
        let card = dark ? Color(white: 0.21) : .white
        let text = dark ? Color(white: 0.9) : Color(white: 0.15)
        return HStack(spacing: 0) {
            side.frame(width: 24)
                .overlay(alignment: .top) {
                    VStack(spacing: 5) {
                        Capsule().fill(Color.accentColor).frame(width: 13, height: 3)
                        Capsule().fill(text.opacity(0.5)).frame(width: 13, height: 3)
                        Capsule().fill(text.opacity(0.5)).frame(width: 13, height: 3)
                    }
                    .padding(.top, 10)
                }
            base.overlay {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(text).frame(width: 40, height: 5)
                    RoundedRectangle(cornerRadius: 4).fill(card)
                        .overlay(alignment: .bottomLeading) {
                            HStack(alignment: .bottom, spacing: 3) {
                                ForEach([0.5, 0.8, 0.6, 1.0], id: \.self) { h in
                                    RoundedRectangle(cornerRadius: 1).fill(VizColor.series).frame(width: 6, height: 30 * h)
                                }
                            }
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .padding(5)
                        }
                }
                .padding(9)
            }
        }
    }
}
