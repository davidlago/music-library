import MusicLibraryGlance
import SwiftUI
import WidgetKit

// iPhone only.
#if os(iOS)

/// A song you played a lot and haven't heard in months, a different one every couple of hours.
struct RediscoverWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceWidgetKind.rediscover.rawValue, provider: RediscoverProvider()) { entry in
            RediscoverWidgetView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("Rediscover")
        .description("Favorites you haven't played in a while.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct RediscoverProvider: TimelineProvider {
    static let interval: TimeInterval = 2 * 3600

    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        var glance = GlanceProvider.current(preview: context.isPreview)
        if context.isPreview && glance?.rediscover.isEmpty == true { glance = .sample }
        completion(GlanceEntry(date: Date(), glance: glance))
    }

    /// One entry per favorite, `interval` apart, starting where the clock says so it doesn't always begin with the
    /// same one.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let glance = GlanceProvider.current(preview: false)
        let count = glance?.rediscover.count ?? 0
        guard count > 1 else {
            completion(Timeline(entries: [GlanceEntry(date: now, glance: glance)], policy: .after(GlanceProvider.nextMidnight(after: now))))
            return
        }
        let start = Int(now.timeIntervalSince1970 / Self.interval)
        let entries = (0..<min(count, 12)).map { i in
            GlanceEntry(date: now.addingTimeInterval(Double(i) * Self.interval), glance: glance, index: (start + i) % count)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct RediscoverWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GlanceEntry

    static let tint = Color.indigo

    var body: some View {
        if let glance = entry.glance {
            if glance.rediscover.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetHeader(title: "Rediscover", systemImage: "sparkles", tint: Self.tint)
                    Spacer(minLength: 0)
                    Text("Nothing forgotten").font(.headline)
                    Text("Songs you played often and haven't heard in three months show up here.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .widgetURL(GlanceLink.insights(.listening).url)
            } else {
                let pick = glance.rediscover[entry.index % glance.rediscover.count]
                Group {
                    if family == .systemMedium { medium(pick) } else { small(pick) }
                }
                .widgetURL(GlanceLink.album(key: pick.item.albumKey).url)
            }
        } else {
            NoLibraryView(systemImage: "sparkles").padding()
        }
    }

    private func lastPlayed(_ pick: Glance.Ranked<Glance.Song>) -> String {
        guard let date = pick.lastPlayed else { return GlanceFormat.count(pick.plays, "play") }
        return "\(GlanceFormat.count(pick.plays, "play")) · \(date.formatted(.relative(presentation: .named)))"
    }

    private func small(_ pick: Glance.Ranked<Glance.Song>) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverBackground(name: pick.item.cover, title: pick.item.album)
            VStack(alignment: .leading, spacing: 2) {
                Label("REDISCOVER", systemImage: "sparkles").font(.caption2.weight(.bold)).opacity(0.9)
                Spacer(minLength: 0)
                Text(pick.item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(pick.item.artist).font(.caption).opacity(0.85).lineLimit(1)
                Text(lastPlayed(pick)).font(.caption2).opacity(0.8).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
    }

    private func medium(_ pick: Glance.Ranked<Glance.Song>) -> some View {
        HStack(spacing: 14) {
            CoverArt(name: pick.item.cover, title: pick.item.album, cornerRadius: 10)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                WidgetHeader(title: "Rediscover", systemImage: "sparkles", tint: Self.tint)
                Spacer(minLength: 2)
                Text(pick.item.title).font(.headline).lineLimit(2)
                Text(pick.item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(lastPlayed(pick)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if pick.item.playable {
                    Button(intent: PlayAlbumIntent(albumKey: pick.item.albumKey)) {
                        Label("Play \(pick.item.album.isEmpty ? "Album" : pick.item.album)", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .tint(Self.tint)
                } else {
                    Label("Not on this iPhone", systemImage: "icloud.and.arrow.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}
#endif
