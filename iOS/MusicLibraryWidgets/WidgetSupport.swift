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

/// A collection item as it sits on the shelf: a CD in its jewel case with its label on a white sticker across the top of
/// the hinge, a record in its sleeve with its label on a round yellow dot, or just the cover (a download). `height` is
/// the art's height; it's a little wider for a case or a sleeve.
struct ShelfArt: View {
    var item: Glance.Collection.Item
    var height: CGFloat

    var body: some View {
        switch item.mediumKind {
        case "cd": jewelCase
        case "vinyl": sleeve
        default: CoverArt(name: item.cover, title: item.title, cornerRadius: height * 0.08).frame(width: height, height: height)
        }
    }

    private var jewelCase: some View {
        let h = height, w = h * 142 / 125
        let hinge = w * 0.105, side = h * 0.944, margin = h * 0.028
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.08))
            CoverArt(name: item.cover, title: item.title, cornerRadius: 0)
                .frame(width: side, height: side)
                .offset(x: w - margin - side, y: margin)
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.1)], startPoint: .leading, endPoint: .trailing))
                .frame(width: hinge, height: h)
            if let number = item.sticker {
                Text(String(number))
                    .font(.system(size: max(6, hinge * 0.62), weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(white: 0.1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: h * 0.42, height: hinge * 0.8)
                    .background(RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.97)))
                    .rotationEffect(.degrees(-90))
                    .frame(width: hinge * 0.8, height: h * 0.42)
                    .offset(x: hinge * 0.1, y: h * 0.02)
            }
            RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityElement()
        .accessibilityLabel(item.spokenSticker ?? "CD")
    }

    private var sleeve: some View {
        let h = height
        return ZStack(alignment: .topLeading) {
            // The record, part of the way out of its sleeve.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.04)], center: .center, startRadius: 0, endRadius: h / 2))
                .overlay { Circle().fill(Color(white: 0.75)).frame(width: h * 0.3, height: h * 0.3) }
                .frame(width: h * 0.94, height: h * 0.94)
                .offset(x: h * 0.21, y: h * 0.03)
            CoverArt(name: item.cover, title: item.title, cornerRadius: 1.5)
                .frame(width: h, height: h)
                .shadow(color: .black.opacity(0.3), radius: 1, x: 1)
            if let number = item.sticker {
                Text(String(number))
                    .font(.system(size: max(6, h * 0.12), weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(white: 0.1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(h * 0.02)
                    .frame(width: h * 0.26, height: h * 0.26)
                    .background(Circle().fill(Color(red: 1, green: 0.84, blue: 0.2)))
                    .offset(x: h * 0.05, y: h * 0.05)
            }
        }
        .frame(width: h * 1.18, height: h, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(item.spokenSticker ?? "Vinyl")
    }

    nonisolated static func mediumName(_ medium: String) -> String {
        switch Glance.Collection.Item.kind(of: medium) {
        case "cd": "CD"
        case "vinyl": "Vinyl"
        case "download": "Download"
        default: "Other"
        }
    }
}

extension Glance.Collection.Item {
    /// The medium as `GlanceFormat.sticker` reads it ("CD" and " vinyl" are a CD and a record), so the art, the name
    /// and the label always agree.
    static func kind(of medium: String) -> String { medium.trimmingCharacters(in: .whitespaces).lowercased() }

    var mediumKind: String { Self.kind(of: medium) }

    /// "CD label 12", for VoiceOver.
    var spokenSticker: String? {
        guard let sticker else { return nil }
        return "\(ShelfArt.mediumName(medium)) label \(sticker)"
    }

    /// "Added today", "Added 3 days ago", "Added Sep 1" (with the year before this one), from the purchase day, else
    /// the day it went into the collection (nil from a summary that has neither). `short` leaves out "Added".
    func addedText(short: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let parts = (purchasedOn ?? addedOn)?.split(separator: "-").compactMap { Int($0) } ?? []
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        let text: String
        switch days {
        case ..<0: text = day.formatted(.dateTime.month(.abbreviated).day())
        case 0: text = "today"
        case 1: text = "yesterday"
        case 2..<14: text = "\(days) days ago"
        default:
            let sameYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
            text = day.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        }
        if short { return text.prefix(1).uppercased() + text.dropFirst() }
        return "Added " + text
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
