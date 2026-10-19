import MusicLibraryGlance
import SwiftUI
import WidgetKit

// iPhone only.
#if os(iOS)

/// The digital collection at a glance: how big it is, how much of it is on the iPhone, and what came in last.
struct LibraryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceWidgetKind.library.rawValue, provider: GlanceProvider()) { entry in
            LibraryWidgetView(entry: entry)
                .widgetURL(GlanceLink.insights(.library).url)
                .widgetBackground()
        }
        .configurationDisplayName("Digital Collection")
        .description("Your digital collection's size, what's on this iPhone and what you added last.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LibraryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GlanceEntry

    static let tint = Color.teal

    var body: some View {
        if let glance = entry.glance {
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    counts(glance.library)
                    recent(glance.library)
                }
            } else {
                counts(glance.library)
            }
        } else {
            NoLibraryView(systemImage: "square.stack")
        }
    }

    private func counts(_ l: Glance.LibraryCounts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Digital", systemImage: "square.stack", tint: Self.tint)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(l.albums.formatted())
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(l.albums == 1 ? "album" : "albums").font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(GlanceFormat.count(l.songs, "song")) · \(GlanceFormat.listened(l.duration))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let fraction = l.songs == 0 ? 0 : Double(l.songsOnPhone) / Double(l.songs)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction).tint(Self.tint).widgetAccentable()
                Label("\(Int((fraction * 100).rounded()))% on iPhone", systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recent(_ l: Glance.LibraryCounts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENTLY ADDED").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            let albums = Array(l.recentlyAdded.prefix(4))
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            let i = row * 2 + column
                            if i < albums.count {
                                Link(destination: GlanceLink.album(key: albums[i].key).url) {
                                    CoverArt(name: albums[i].cover, title: albums[i].title, cornerRadius: 5)
                                }
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
