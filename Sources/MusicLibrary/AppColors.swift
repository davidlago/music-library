import AppKit
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

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
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AppColor.accent : Color(nsColor: .separatorColor),
                                                                     lineWidth: selected ? 3 : 0.5))
            Text(mode.name).font(.callout.weight(selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }

    /// The page, sidebar, a card and the brass, drawn in one appearance (the palette's colours resolve by scheme).
    private func preview(dark: Bool) -> some View {
        HStack(spacing: 0) {
            AppColor.sidebar.frame(width: 24)
                .overlay(alignment: .top) {
                    VStack(spacing: 5) {
                        Capsule().fill(AppColor.text).frame(width: 15, height: 4)
                        Capsule().fill(AppColor.accent).frame(width: 13, height: 2)
                        Capsule().fill(AppColor.muted.opacity(0.6)).frame(width: 13, height: 3).padding(.top, 3)
                        Capsule().fill(AppColor.muted.opacity(0.6)).frame(width: 13, height: 3)
                    }
                    .padding(.top, 9)
                }
            AppColor.background.overlay {
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(AppColor.accent).frame(width: 26, height: 3)
                    RoundedRectangle(cornerRadius: 1).fill(AppColor.text).frame(width: 46, height: 7)
                    RoundedRectangle(cornerRadius: 4).fill(AppColor.card)
                        .overlay(alignment: .bottomLeading) {
                            HStack(alignment: .bottom, spacing: 3) {
                                ForEach([0.5, 0.8, 0.6, 1.0], id: \.self) { h in
                                    RoundedRectangle(cornerRadius: 1).fill(VizColor.series).frame(width: 6, height: 26 * h)
                                }
                            }
                            .padding(5)
                        }
                }
                .padding(9)
            }
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
