import AppIntents
import MusicLibraryGlance
import SwiftUI
import WidgetKit

/// How much you've listened in the past 7 or 30 days, with the days as bars, your streak and what you played most.
struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: GlanceWidgetKind.listening.rawValue, intent: ListeningConfiguration.self, provider: ListeningProvider()) { entry in
            ListeningWidgetView(entry: entry)
                .widgetURL(GlanceLink.insights(.listening).url)
                .widgetBackground()
        }
        .configurationDisplayName("Listening")
        .description("How much you've listened, your streak and what you played most.")
        .supportedFamilies(Self.families)
    }

    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
    #else
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #endif
}

enum ListeningPeriod: String, AppEnum {
    case week, month

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [ListeningPeriod: DisplayRepresentation] = [.week: "Past 7 Days", .month: "Past 30 Days"]
}

struct ListeningConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Listening"
    static let description = IntentDescription("How much you've listened, and to what.")

    @Parameter(title: "Period", default: .week) var period: ListeningPeriod

    init() {}

    init(period: ListeningPeriod) {
        self.period = period
    }
}

struct ListeningEntry: TimelineEntry {
    var date: Date
    var glance: Glance?
    var period: ListeningPeriod

    var listening: Glance.Listening? { period == .week ? glance?.week : glance?.month }
}

struct ListeningProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry {
        ListeningEntry(date: Date(), glance: .sample, period: .week)
    }

    func snapshot(for configuration: ListeningConfiguration, in context: Context) async -> ListeningEntry {
        ListeningEntry(date: Date(), glance: GlanceProvider.current(preview: context.isPreview), period: configuration.period)
    }

    func timeline(for configuration: ListeningConfiguration, in context: Context) async -> Timeline<ListeningEntry> {
        let now = Date()
        return Timeline(entries: [ListeningEntry(date: now, glance: GlanceProvider.current(preview: false), period: configuration.period)],
                        policy: .after(GlanceProvider.nextMidnight(after: now)))
    }

    #if os(watchOS)
    func recommendations() -> [AppIntentRecommendation<ListeningConfiguration>] {
        [AppIntentRecommendation(intent: ListeningConfiguration(period: .week), description: "Past 7 Days"),
         AppIntentRecommendation(intent: ListeningConfiguration(period: .month), description: "Past 30 Days")]
    }
    #endif
}

struct ListeningWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ListeningEntry

    static let tint = Color.pink

    var body: some View {
        if let l = entry.listening {
            switch family {
            case .accessoryCircular: circular(l)
            case .accessoryRectangular: rectangular(l)
            case .accessoryInline: Label("\(GlanceFormat.listened(l.listened)) in the \(l.periodText)", systemImage: "waveform")
            #if os(watchOS)
            case .accessoryCorner: corner(l)
            #endif
            #if os(iOS)
            case .systemMedium: medium(l)
            case .systemLarge: large(l)
            default: small(l)
            #else
            default: rectangular(l)
            #endif
            }
        } else {
            NoLibraryView(systemImage: "waveform")
        }
    }

    // MARK: Home screen

    private func summary(_ l: Glance.Listening, big: Font = .system(.title, design: .rounded, weight: .bold)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(GlanceFormat.listened(l.listened))
                .font(big)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            HStack(spacing: 4) {
                Text(l.periodText)
                if let change = l.change {
                    Text(GlanceFormat.change(change))
                        .foregroundStyle(change >= 0 ? .green : .orange)
                        .fontWeight(.semibold)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func streakOrPlays(_ l: Glance.Listening) -> some View {
        if l.currentStreak > 1 {
            Label("\(l.currentStreak)-day streak", systemImage: "flame.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            Text(GlanceFormat.count(l.plays, "play"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func small(_ l: Glance.Listening) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Listening", systemImage: "waveform", tint: Self.tint)
            Spacer(minLength: 0)
            summary(l)
            DailyBars(days: l.daily, tint: Self.tint).frame(height: 28)
            streakOrPlays(l)
        }
    }

    private func medium(_ l: Glance.Listening) -> some View {
        HStack(alignment: .top, spacing: 16) {
            small(l)
            VStack(alignment: .leading, spacing: 10) {
                if let artist = l.topArtists.first {
                    TopLine(label: "Top Artist", title: artist.item, detail: GlanceFormat.count(artist.plays, "play"))
                }
                if let song = l.topSongs.first {
                    TopLine(label: "Top Song", title: song.item.title, detail: song.item.artist)
                }
                if let hour = l.peakHour {
                    TopLine(label: "Most Often", title: "Around \(GlanceFormat.hour(hour))", detail: nil)
                }
                if l.topArtists.isEmpty {
                    Text("Nothing played in the \(l.periodText).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func large(_ l: Glance.Listening) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                WidgetHeader(title: "Listening", systemImage: "waveform", tint: Self.tint)
                Spacer()
                streakOrPlays(l)
            }
            HStack(alignment: .bottom, spacing: 12) {
                summary(l, big: .system(.largeTitle, design: .rounded, weight: .bold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(GlanceFormat.count(l.plays, "play")).font(.caption.weight(.semibold))
                    Text("\(l.activeDays) of \(l.days) days").font(.caption2).foregroundStyle(.secondary)
                }
            }
            DailyBars(days: l.daily, tint: Self.tint, spacing: 4).frame(height: 54)
            if !l.topAlbums.isEmpty {
                Text("Top Albums").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(l.topAlbums.prefix(4), id: \.item.key) { album in
                        Link(destination: GlanceLink.album(key: album.item.key).url) {
                            VStack(alignment: .leading, spacing: 3) {
                                CoverArt(name: album.item.cover, title: album.item.title)
                                Text(album.item.title).font(.caption2.weight(.medium)).lineLimit(1)
                                Text(GlanceFormat.count(album.plays, "play")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, 4 - l.topAlbums.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
            if !l.topArtists.isEmpty {
                HStack(spacing: 12) {
                    ForEach(l.topArtists.prefix(3), id: \.item) { artist in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artist.item).font(.caption.weight(.medium)).lineLimit(1)
                            Text(GlanceFormat.count(artist.plays, "play")).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("Nothing played in the \(l.periodText) yet.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Lock screen and watch

    private func shortTime(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 10 { return "\(Int(hours.rounded()))h" }
        if hours >= 1 { return String(format: "%.1fh", hours) }
        return "\(Int((seconds / 60).rounded()))m"
    }

    private func circular(_ l: Glance.Listening) -> some View {
        Gauge(value: Double(l.activeDays), in: 0...Double(max(1, l.days))) {
            Image(systemName: "waveform")
        } currentValueLabel: {
            Text(shortTime(l.listened)).minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel("\(GlanceFormat.listenedLong(l.listened)) in the \(l.periodText), on \(l.activeDays) days")
    }

    private func rectangular(_ l: Glance.Listening) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(GlanceFormat.listened(l.listened), systemImage: "waveform")
                .font(.headline)
                .widgetAccentable()
            Text(l.topArtists.first.map { "Top: \($0.item)" } ?? l.periodText)
                .font(.caption)
                .lineLimit(1)
            Text(l.currentStreak > 1 ? "\(l.currentStreak)-day streak" : GlanceFormat.count(l.plays, "play"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(watchOS)
    private func corner(_ l: Glance.Listening) -> some View {
        Image(systemName: "waveform")
            .font(.title3)
            .widgetAccentable()
            .widgetLabel {
                Gauge(value: Double(l.activeDays), in: 0...Double(max(1, l.days))) {
                    Text("Listened")
                } currentValueLabel: {
                    Text(shortTime(l.listened))
                } minimumValueLabel: {
                    Text("")
                } maximumValueLabel: {
                    Text(shortTime(l.listened))
                }
            }
    }
    #endif
}

/// "TOP ARTIST / Radiohead / 34 plays"
struct TopLine: View {
    var label: String
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

extension View {
    /// The widget's background: the system one on the home screen; on the lock screen and the watch the system draws
    /// its own.
    func widgetBackground() -> some View {
        containerBackground(for: .widget) {
            #if os(iOS)
            Color(uiColor: .systemBackground)
            #else
            Color.clear
            #endif
        }
    }
}
