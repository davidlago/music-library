import MusicLibraryGlance
import SwiftUI
import UIKit
import WidgetKit

// Compiled into the iPhone's widget extension and the watch's: the summary's timeline, covers and shared pieces.

struct GlanceEntry: TimelineEntry {
    var date: Date
    /// Nil until the app has written a summary (it hasn't been opened, or there's no library yet).
    var glance: Glance?
    /// Which item a rotating widget shows.
    var index = 0
}

/// Reads the summary the app wrote. It changes only when the app writes it again (and reloads the widgets), but
/// periods like "the last 7 days" move with the calendar, so it's read again after midnight.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(GlanceEntry(date: Date(), glance: Self.current(preview: context.isPreview)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [GlanceEntry(date: now, glance: Self.current(preview: false))], policy: .after(Self.nextMidnight(after: now))))
    }

    /// The gallery shows sample data until there's a real summary with something in it.
    static func current(preview: Bool) -> Glance? {
        let glance = GlanceStore.shared?.read()
        if preview && (glance?.library.songs ?? 0) == 0 { return .sample }
        return glance
    }

    static func nextMidnight(after date: Date) -> Date {
        Calendar.current.nextDate(after: date, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }
}

// MARK: Covers

/// An album cover from the summary's thumbnails, or a tinted placeholder.
struct CoverArt: View {
    var name: String?
    var title = ""
    var cornerRadius: CGFloat = 6

    var body: some View {
        // A square frame with the image filling it, so covers that aren't square are cropped instead of resizing it.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = Self.image(name) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: Self.placeholderColors(title), startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.title3).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    static func image(_ name: String?) -> UIImage? {
        guard let name, let url = GlanceStore.shared?.coverURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// A gradient picked by the title, so placeholders differ from one another.
    static func placeholderColors(_ title: String) -> [Color] {
        let palettes: [[Color]] = [[.pink, .orange], [.indigo, .purple], [.teal, .blue], [.orange, .red], [.mint, .teal], [.purple, .pink]]
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palettes[abs(sum) % palettes.count]
    }
}

/// A full-bleed cover behind a widget's text, darkened at the top and bottom so the text reads on light covers.
struct CoverBackground: View {
    var name: String?
    var title = ""

    var body: some View {
        Color.clear
            .overlay {
                if let image = CoverArt.image(name) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: CoverArt.placeholderColors(title), startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.3),
                                       .init(color: .black.opacity(0.3), location: 0.55), .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
    }
}

// MARK: Pieces

/// A small caps label with an icon at the top of a widget.
struct WidgetHeader: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .widgetAccentable()
    }
}

/// Listening per day as bars, oldest first.
struct DailyBars: View {
    var days: [Glance.Listening.Day]
    var tint: Color
    var spacing: CGFloat = 2

    var body: some View {
        let peak = max(days.map(\.listened).max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: days.count > 14 ? 1 : spacing) {
                ForEach(days, id: \.date) { day in
                    let fraction = day.listened / peak
                    RoundedRectangle(cornerRadius: days.count > 14 ? 1 : 2, style: .continuous)
                        .fill(day.listened > 0 ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary))
                        .frame(height: max(2, geo.size.height * fraction))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .widgetAccentable()
        .accessibilityLabel("Listening per day")
    }
}

/// Shown when the app hasn't written a summary yet.
struct NoLibraryView: View {
    var systemImage: String
    var message = "Open Music Library to set up its widgets."

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(message).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The period a summary covers, as the widget says it.
extension Glance.Listening {
    var periodText: String { "past \(days) days" }
}
