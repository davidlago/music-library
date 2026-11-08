import Charts
import MusicLibraryCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The Listening pane of Insights, shared by the Mac and the iPhone: a listening report with a banner of the period's
// plays against the span before, your top artists, albums and songs with their pictures, what was new to you, when
// and what eras you play, and quick facts. Each app supplies the pictures and where a tap or click goes
// (`ListeningLinks`, in the environment), the period picker above it, and the cards it shares with its other panes
// (genres as ranked bars, fun facts).

#if os(macOS)
public typealias ListeningImage = NSImage
#else
public typealias ListeningImage = UIImage
#endif

// MARK: Model

public enum ListeningMeasure: String, CaseIterable, Identifiable, Sendable {
    case plays = "Plays", time = "Time"
    public var id: String { rawValue }
}

/// What a ranked item is, for its picture and where opening it goes.
public enum ListeningKind: Sendable {
    case artist, album, song

    public var plural: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        case .song: "Songs"
        }
    }

    public var top: String {
        switch self {
        case .artist: "Top Artist"
        case .album: "Top Album"
        case .song: "Top Song"
        }
    }

    public func count(_ n: Int) -> String {
        switch self {
        case .artist: n == 1 ? "1 artist" : "\(n.formatted()) artists"
        case .album: n == 1 ? "1 album" : "\(n.formatted()) albums"
        case .song: n == 1 ? "1 song" : "\(n.formatted()) songs"
        }
    }
}

/// Where opening something in the report goes: a ranked item (an artist's page, an album, a song's search), or a
/// search (a decade).
public enum ListeningTarget {
    case item(ListeningStats.Item, ListeningKind)
    case query(String, title: String)
}

/// What the app supplies to the report: pictures and links.
public struct ListeningLinks: Sendable {
    /// The artist's photo (or a cover of theirs), or the cover of the album or song, filling the frame it's given
    /// (`size` is the largest side it's shown at). Usually a `ListeningArt` once the picture is loaded; calls `onLoad`
    /// with the picture (nil when there's none), e.g. to take a colour from it.
    public var art: @MainActor @Sendable (_ item: ListeningStats.Item, _ kind: ListeningKind, _ size: CGFloat,
                                         _ onLoad: (@MainActor (ListeningImage?) -> Void)?) -> AnyView
    /// Makes `label` open `target` (with the app's context menu, if any).
    public var open: @MainActor @Sendable (_ target: ListeningTarget, _ label: AnyView) -> AnyView

    public init(art: @escaping @MainActor @Sendable (ListeningStats.Item, ListeningKind, CGFloat, (@MainActor (ListeningImage?) -> Void)?) -> AnyView,
                open: @escaping @MainActor @Sendable (ListeningTarget, AnyView) -> AnyView) {
        self.art = art
        self.open = open
    }

    /// Placeholders that open nothing (previews).
    public static let none = ListeningLinks(art: { _, kind, _, _ in AnyView(ListeningArt(image: nil, kind: kind)) },
                                            open: { _, label in label })
}

private struct ListeningLinksKey: EnvironmentKey {
    static let defaultValue = ListeningLinks.none
}

extension EnvironmentValues {
    public var listeningLinks: ListeningLinks {
        get { self[ListeningLinksKey.self] }
        set { self[ListeningLinksKey.self] = newValue }
    }
}

/// A fun fact from the listening history, for the app's facts grid.
public struct ListeningFact: Identifiable, Sendable {
    public var id: String { title }
    public var icon: String
    public var title: String
    public var value: String
    public var detail: String
    /// A search it opens.
    public var query: String?
    /// The search page's title (the value when nil).
    public var queryTitle: String?
}

// MARK: Words and numbers

/// Searches and names for listening items, the clock's labels and the report's numbers.
public enum ListeningText {
    public static func songQuery(_ item: ListeningStats.Item) -> String {
        SearchFilterKey.token("title", item.name) + (item.subtitle.isEmpty ? "" : " " + SearchFilterKey.token("artist", item.subtitle))
    }

    public static func albumQuery(_ item: ListeningStats.Item) -> String {
        SearchFilterKey.token("album", item.name) + " " + SearchFilterKey.token("albumartist", item.subtitle)
    }

    public static func artistQuery(_ name: String) -> String? {
        name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", name)
    }

    /// "Night owl", "Early bird"… for the hour most listening happens in.
    public static func daypart(_ hour: Int) -> (name: String, title: String, icon: String) {
        switch hour {
        case 5..<12: ("mornings", "Early bird", "sunrise")
        case 12..<17: ("afternoons", "Afternoon listener", "sun.max")
        case 17..<22: ("evenings", "Evening listener", "sunset")
        default: ("late at night", "Night owl", "moon.stars")
        }
    }

    public static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// Full weekday name for an index in `ListeningStats.clock` order.
    public static func weekdayName(_ index: Int) -> String {
        let c = Calendar.current
        return c.weekdaySymbols[(index + c.firstWeekday - 1) % 7]
    }

    /// The span before the period, as the comparisons name it.
    public static func priorSpan(_ period: ListeningStats.Period) -> String {
        switch period {
        case .week: "the 7 days before"
        case .month: "the 30 days before"
        case .year: "the 12 months before"
        case .all: ""
        }
    }

    /// The change from `previous` to `current` as a fraction; nil when there's nothing to compare with.
    public static func change(_ current: Double, _ previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return current / previous - 1
    }

    /// "1 play", "1,204 plays".
    public static func plays(_ n: Int) -> String { n == 1 ? "1 play" : "\(n.formatted()) plays" }

    /// "3 hr 12 min", "2 days 4 hr".
    public static func longDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return time(seconds) }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? time(seconds)
    }

    /// Listening time: "—" for none, "52 sec" under a minute, then "3 hr, 12 min".
    public static func listened(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "—" }
        return seconds < 60 ? "\(Int(seconds)) sec" : longDuration(seconds)
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The range the report covers: "Since May 3, 2021" or "Oct 9, 2026 – Nov 8, 2026".
    public static func range(_ stats: ListeningStats) -> String {
        if stats.period == .all { return "Since \(stats.firstListen?.formatted(date: .long, time: .omitted) ?? "—")" }
        return "\(stats.start?.formatted(.dateTime.month(.abbreviated).day().year()) ?? "—") – \(stats.now.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// The panel colour when there's no picture to take one from.
    public static let defaultPanel = ArtworkTint.panel(from: RGB(0x2a78d6))

    /// A panel colour taken from a picture, dark enough for white text.
    public static func panelTint(_ image: ListeningImage?) -> RGB? {
        #if os(macOS)
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = image?.cgImage else { return nil }
        #endif
        guard let average = ArtworkTint.average(of: cg) else { return nil }
        return ArtworkTint.panel(from: average)
    }
}

extension ListeningStats {
    /// Only when there's history before the period: otherwise everything is new.
    public var showsDiscoveries: Bool {
        guard period != .all, let first = firstListen, let start else { return false }
        return first < start && artists.total > 0
    }
}

/// The facts the report's Fun Facts card shows.
public enum ListeningFacts {
    public static func facts(_ stats: ListeningStats) -> [ListeningFact] {
        typealias T = ListeningText
        var out: [ListeningFact] = []
        if let s = stats.longestSession, s.songs > 1 {
            out.append(ListeningFact(icon: "hourglass", title: "Longest session", value: T.longDuration(s.listened),
                                     detail: "\(s.songs) songs in a row, \(s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
        }
        if let r = stats.onRepeat {
            out.append(ListeningFact(icon: "repeat", title: "On repeat", value: r.song.name,
                                     detail: "\(r.plays) plays on \(r.date.formatted(.dateTime.month(.abbreviated).day()))\(r.song.subtitle.isEmpty ? "" : " · " + r.song.subtitle)",
                                     query: T.songQuery(r.song)))
        }
        if let h = stats.peakHour {
            let part = T.daypart(h)
            out.append(ListeningFact(icon: part.icon, title: part.title, value: T.hourLabel(h), detail: "Your busiest hour of the day"))
        }
        if let a = stats.artists.byPlays.first, stats.plays > 0, stats.artists.total > 1 {
            let share = Double(a.plays) / Double(stats.plays)
            out.append(ListeningFact(icon: "heart", title: "Most played artist", value: a.name,
                                     detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your plays", query: T.artistQuery(a.name)))
        }
        if stats.skipped > 0 {
            out.append(ListeningFact(icon: "forward.end", title: "Skip rate", value: stats.skipRate.formatted(.percent.precision(.fractionLength(0))),
                                     detail: "\(stats.skipped.formatted()) of \(stats.listens.formatted()) listens stopped early"))
        }
        if stats.neverPlayed > 0 {
            out.append(ListeningFact(icon: "sparkles", title: "Still unplayed", value: stats.neverPlayed.formatted(),
                                     detail: "songs in your digital collection waiting for their first play"))
        }
        if stats.period == .all, let first = stats.firstListen, let song = stats.firstSong {
            out.append(ListeningFact(icon: "flag", title: "First listen", value: first.formatted(date: .abbreviated, time: .omitted),
                                     detail: song.name + (song.subtitle.isEmpty ? "" : " — " + song.subtitle),
                                     query: T.songQuery(song), queryTitle: song.name))
        }
        return out
    }
}

// MARK: Sizes

/// The report's sizes on each device; everything else is the same.
enum ListeningMetrics {
    #if os(macOS)
    static let spacing: CGFloat = 22
    static let gridSpacing: CGFloat = 14
    static let sectionTitle = Font.system(size: 20, weight: .bold, design: .rounded)
    static let rowFont = Font.callout
    static let rowDetailFont = Font.callout
    static let rowArt: CGFloat = 32
    static let heroPlays: CGFloat = 60
    static let heroUnit: CGFloat = 26
    static let heroSummary = Font.callout
    static let heroPadding: CGFloat = 24
    static let heroChartHeight: CGFloat = 150
    static let chartLabels = 6
    static let spotlightCount: CGFloat = 30
    static let spotlightLabel = Font.callout.weight(.semibold)
    static let spotlightAspect: CGFloat = 1.15
    static let showMoreFont = Font.caption
    static let clockSide: CGFloat = 190
    static let clockStat: CGFloat = 22
    static let clockDetail = Font.caption
    static let weekdayBar: CGFloat = 14
    static let weekdayHeight: CGFloat = 44
    static let factValue: CGFloat = 24
    static let factTitle = Font.callout
    static let factPadding: CGFloat = 14
    static let patternsMinWidth: CGFloat = 400
    #else
    static let spacing: CGFloat = 16
    static let gridSpacing: CGFloat = 10
    static let sectionTitle = Font.title3.bold()
    static let rowFont = Font.subheadline
    static let rowDetailFont = Font.footnote
    static let rowArt: CGFloat = 36
    static let heroPlays: CGFloat = 50
    static let heroUnit: CGFloat = 22
    static let heroSummary = Font.footnote
    static let heroPadding: CGFloat = 18
    static let heroChartHeight: CGFloat = 130
    static let chartLabels = 4
    static let spotlightCount: CGFloat = 28
    static let spotlightLabel = Font.subheadline.weight(.semibold)
    static let spotlightAspect: CGFloat = 1.4
    static let showMoreFont = Font.footnote.weight(.medium)
    static let clockSide: CGFloat = 160
    static let clockStat: CGFloat = 20
    static let clockDetail = Font.caption2
    static let weekdayBar: CGFloat = 12
    static let weekdayHeight: CGFloat = 36
    static let factValue: CGFloat = 20
    static let factTitle = Font.caption
    static let factPadding: CGFloat = 12
    static let patternsMinWidth: CGFloat = 300
    #endif
}

// MARK: Report

/// Everything under the period picker: the banner, Top Charts, New to You, Patterns and Quick Facts. `genres` is the
/// Top Genres card (shown when there are genres) and `facts` the Fun Facts card, both in the app's own style.
public struct ListeningReport<Genres: View, Facts: View>: View {
    let stats: ListeningStats
    var genres: Genres
    var facts: Facts
    @AppStorage("listeningMeasure") private var measure = ListeningMeasure.plays

    public init(stats: ListeningStats, @ViewBuilder genres: () -> Genres, @ViewBuilder facts: () -> Facts) {
        self.stats = stats
        self.genres = genres()
        self.facts = facts()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ListeningMetrics.spacing) {
            if stats.listens == 0 {
                InsightCard(title: "Nothing played in the last \(stats.period.rawValue.lowercased())") {
                    Text("Your listening history goes back to \(stats.firstListen?.formatted(date: .long, time: .omitted) ?? "—"). Pick a longer period above, or press play.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !stats.forgotten.isEmpty { ListeningRediscoverCard(stats: stats) }
            } else {
                ListeningHero(stats: stats)
                ListeningSection(title: "Top Charts") {
                    Picker("Rank by", selection: $measure) { ForEach(ListeningMeasure.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Rank by plays or by time spent listening")
                }
                EvenRow(count: stats.albums.byTime.isEmpty ? 2 : 3) {
                    SpotlightCard(kind: .artist, ranking: stats.artists, previous: stats.previous?.artists, measure: measure)
                    if !stats.albums.byTime.isEmpty {
                        SpotlightCard(kind: .album, ranking: stats.albums, previous: stats.previous?.albums, measure: measure)
                    }
                    SpotlightCard(kind: .song, ranking: stats.songs, previous: stats.previous?.songs, measure: measure)
                }
                if stats.showsDiscoveries { DiscoveriesCard(stats: stats) }
                ListeningSection(title: "Patterns")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ListeningMetrics.patternsMinWidth), spacing: ListeningMetrics.gridSpacing, alignment: .top)],
                          alignment: .leading, spacing: ListeningMetrics.gridSpacing) {
                    ListeningClockCard(stats: stats)
                    if !stats.eras.isEmpty { DecadesCard(stats: stats) }
                    if !stats.genres.byPlays.isEmpty { genres }
                    if !stats.mostSkipped.isEmpty { ListeningSkippedCard(stats: stats) }
                    if !stats.forgotten.isEmpty { ListeningRediscoverCard(stats: stats) }
                }
                ListeningSection(title: "Quick Facts")
                QuickFacts(stats: stats)
                facts
            }
        }
    }
}

// MARK: Building blocks

/// A picture in the report: the artist's photo or a cover, filled into its frame, or a placeholder.
public struct ListeningArt: View {
    let image: ListeningImage?
    let kind: ListeningKind

    public init(image: ListeningImage?, kind: ListeningKind) {
        self.image = image
        self.kind = kind
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                // Filled, the picture reaches past the frame: clipping hides that but it would still take clicks.
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFill().allowsHitTesting(false)
                #else
                Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
                #endif
            } else {
                GeometryReader { geo in
                    Image(systemName: kind == .artist ? "music.mic" : "music.note")
                        .font(.system(size: max(10, min(geo.size.width, geo.size.height) / 3)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// `count` cards side by side in equal columns, wrapping into even rows (6 as 3 + 3, not 5 + 1) when they don't fit at
/// `minWidth` each (on an iPhone, one or two to a row); an adaptive grid would leave an empty column on a wide window.
public struct EvenRow<Content: View>: View {
    let count: Int
    var minWidth: CGFloat
    var content: Content
    @State private var width: CGFloat = 0

    public init(count: Int, minWidth: CGFloat = 250, @ViewBuilder content: () -> Content) {
        self.count = count
        self.minWidth = minWidth
        self.content = content()
    }

    public var body: some View {
        let spacing = ListeningMetrics.gridSpacing
        let fit = min(max(count, 1), max(1, Int((width + spacing) / (minWidth + spacing))))
        let columns = (1...fit).last { count % $0 == 0 && $0 > 1 } ?? fit
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
                  alignment: .leading, spacing: spacing) { content }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A bold section title with a short rule under it.
public struct ListeningSection<Accessory: View>: View {
    let title: String
    var accessory: Accessory

    public init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(ListeningMetrics.sectionTitle).fontDesign(.rounded)
                Capsule().fill(VizColor.series).frame(width: 32, height: 3)
            }
            Spacer()
            accessory
        }
        .padding(.top, 6)
    }
}

extension ListeningSection where Accessory == EmptyView {
    public init(title: String) { self.init(title: title, accessory: { EmptyView() }) }
}

/// A trailing chevron for rows that open something (iPhone).
private struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

/// The line above a chart: what's selected, or how to select.
private struct Readout: View {
    let text: String?
    let hint: String

    var body: some View {
        Group {
            if let text { Text(text).foregroundStyle(.primary) } else { Text(hint).foregroundStyle(.secondary) }
        }
        .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        .frame(minHeight: 16, alignment: .leading)
    }
}

/// "Show Top 25" / "Show Less" under a list that expands.
private struct ShowMoreButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title) { withAnimation(.snappy) { action() } }
            #if os(macOS)
            .buttonStyle(.link)
            .padding(.leading, 8)
            #endif
            .font(ListeningMetrics.showMoreFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

/// One ranked item: rank, picture, name and the measure; opening it goes where the app's `ListeningLinks` say.
public struct ListeningRow: View {
    @Environment(\.listeningLinks) private var links
    var rank: Int?
    let item: ListeningStats.Item
    let kind: ListeningKind
    let detail: String
    var size: CGFloat
    @State private var hovered = false

    /// `size` is the picture's side (the device's usual one when nil).
    public init(rank: Int? = nil, item: ListeningStats.Item, kind: ListeningKind, detail: String, size: CGFloat? = nil) {
        self.rank = rank
        self.item = item
        self.kind = kind
        self.detail = detail
        self.size = size ?? ListeningMetrics.rowArt
    }

    public var body: some View {
        links.open(.item(item, kind), AnyView(label))
            #if os(macOS)
            .onHover { hovered = $0 }
            #endif
    }

    private var label: some View {
        HStack(spacing: 10) {
            if let rank {
                Text("#\(rank)").font(ListeningMetrics.rowFont.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .leading)
            }
            links.art(item, kind, size, nil)
                .frame(width: size, height: size)
                .clipShape(kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if kind != .artist, !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(detail).font(ListeningMetrics.rowDetailFont).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            #if !os(macOS)
            RowChevron()
            #endif
        }
        .font(ListeningMetrics.rowFont)
        #if os(macOS)
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? AppColor.fill : .clear))
        #else
        .padding(.vertical, 4)
        #endif
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Rows on the Mac reach into the card's padding so their hover highlight lines up with the text; on the iPhone they
/// sit inside it.
private extension View {
    func rowInset() -> some View {
        #if os(macOS)
        padding(.horizontal, -8)
        #else
        self
        #endif
    }
}

// MARK: Banner

/// The period's plays, big, over a blurred photo of your top artist, with each day (week, month) against the same span
/// before: the chart beside the numbers on the Mac, under them on the iPhone.
public struct ListeningHero: View {
    @Environment(\.listeningLinks) private var links
    let stats: ListeningStats
    @State private var selected: Int?

    public init(stats: ListeningStats) { self.stats = stats }

    public var body: some View {
        Group {
            #if os(macOS)
            HStack(alignment: .center, spacing: 28) {
                numbers.layoutPriority(1)
                Spacer(minLength: 0)
                HeroChart(stats: stats, selected: $selected)
                    .frame(minWidth: 260, maxWidth: 460)
                    .frame(height: ListeningMetrics.heroChartHeight)
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            #else
            VStack(alignment: .leading, spacing: 6) {
                numbers
                HeroChart(stats: stats, selected: $selected)
                    .frame(height: ListeningMetrics.heroChartHeight)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        .foregroundStyle(.white)
        .padding(ListeningMetrics.heroPadding)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let delta = ListeningText.change(Double(stats.plays), stats.previous.map { Double($0.plays) }) {
                    DeltaLabel(delta: delta, onPanel: true)
                    Text("vs \(ListeningText.priorSpan(stats.period))").font(.caption).foregroundStyle(.white.opacity(0.75))
                } else {
                    Text(stats.period == .all ? "All time" : "Last \(stats.period.rawValue.lowercased())")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(stats.plays.formatted()).font(.system(size: ListeningMetrics.heroPlays, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(stats.plays == 1 ? "play" : "plays").font(.system(size: ListeningMetrics.heroUnit, weight: .bold, design: .rounded))
            }
            Text(summary).font(ListeningMetrics.heroSummary).foregroundStyle(.white.opacity(0.85))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let top = stats.artists.byPlays.first {
                links.open(.item(top, .artist), AnyView(
                    HStack(spacing: 8) {
                        links.art(top, .artist, 26, nil).frame(width: 26, height: 26).clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                        Text("Top artist: ").foregroundStyle(.white.opacity(0.75)) + Text(top.name).fontWeight(.semibold)
                    }
                    .font(ListeningMetrics.heroSummary)
                    .lineLimit(1)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                ))
            }
        }
    }

    private var summary: String {
        var parts = ["\(ListeningText.longDuration(stats.listened)) of music"]
        parts.append(ListeningKind.song.count(stats.songs.total))
        parts.append(ListeningKind.artist.count(stats.artists.total))
        if stats.skipped > 0 { parts.append("\(stats.skipped.formatted()) skipped") }
        return parts.joined(separator: " · ")
    }

    private var background: some View {
        ZStack {
            Color(ListeningText.defaultPanel)
            if let top = stats.artists.byPlays.first {
                links.art(top, .artist, 300, nil)
                    .blur(radius: 36, opaque: true).saturation(1.25).opacity(0.9)
            }
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.45)], startPoint: .leading, endPoint: .trailing)
        }
        // The filled photo reaches past the banner, over the period picker; it must not take its clicks.
        .allowsHitTesting(false)
    }
}

/// Plays per day, week or month, white bars over the faded ones of the span before; hover (Mac) or drag (iPhone) for a
/// readout.
private struct HeroChart: View {
    let stats: ListeningStats
    @Binding var selected: Int?

    #if os(macOS)
    private var alignment: HorizontalAlignment { .trailing }
    private static let hint = "hover for details"
    #else
    private var alignment: HorizontalAlignment { .leading }
    private static let hint = "drag for details"
    #endif

    var body: some View {
        let current = stats.activity, previous = stats.previousActivity
        VStack(alignment: alignment, spacing: 6) {
            Group {
                if let s = selected, s < current.count {
                    Text(readout(s))
                } else if !previous.isEmpty {
                    HStack(spacing: 12) {
                        legend("Last \(stats.period.rawValue.lowercased())", .white)
                        legend(ListeningText.priorSpan(stats.period).capitalizedFirst, .white.opacity(0.35))
                    }
                } else {
                    Text("Plays by \(stats.granularity.rawValue) · \(Self.hint)")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1).minimumScaleFactor(0.8)
            chart(current: current, previous: previous)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Plays by \(stats.granularity.rawValue)")
        }
    }

    private func chart(current: [ListeningStats.ActivityPoint], previous: [ListeningStats.ActivityPoint]) -> some View {
        Chart {
            ForEach(Array(current.enumerated()), id: \.offset) { i, p in
                if i < previous.count {
                    BarMark(x: .value("When", String(i)), y: .value("Plays", previous[i].plays))
                        .foregroundStyle(.white.opacity(selected == nil || selected == i ? 0.35 : 0.18))
                        .position(by: .value("Span", "before"))
                        .cornerRadius(2)
                }
                BarMark(x: .value("When", String(i)), y: .value("Plays", p.plays))
                    .foregroundStyle(.white.opacity(selected == nil || selected == i ? 1 : 0.45))
                    .position(by: .value("Span", "now"))
                    .cornerRadius(2)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            // Every bucket is a category; only every `step`th one is labelled.
            let step = labelStep(current.count)
            AxisMarks { v in
                if let s = v.as(String.self), let i = Int(s), i < current.count, i % step == 0 {
                    AxisValueLabel(collisionResolution: .disabled) {
                        Text(label(current[i].date)).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    #if os(macOS)
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase, let frame = proxy.plotFrame else { selected = nil; return }
                        selected = proxy.value(atX: p.x - geo[frame].origin.x, as: String.self).flatMap(Int.init)
                    }
                    #else
                    .onTapGesture { p in
                        guard let frame = proxy.plotFrame else { return }
                        let i = proxy.value(atX: p.x - geo[frame].origin.x, as: String.self).flatMap(Int.init)
                        selected = i == selected ? nil : i
                    }
                    // Sideways drags pick a bar; vertical ones still scroll the page.
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height), let frame = proxy.plotFrame else { return }
                        selected = proxy.value(atX: v.location.x - geo[frame].origin.x, as: String.self).flatMap(Int.init)
                    })
                    #endif
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    private func labelStep(_ count: Int) -> Int {
        let wanted = stats.granularity == .day && count <= 7 ? count : ListeningMetrics.chartLabels
        return max(1, Int((Double(count) / Double(max(wanted, 1))).rounded(.up)))
    }

    private func label(_ d: Date) -> String {
        switch stats.granularity {
        case .day: stats.activity.count <= 7 ? d.formatted(.dateTime.weekday(.abbreviated)) : d.formatted(.dateTime.month(.abbreviated).day())
        case .week: d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func readout(_ i: Int) -> String {
        let p = stats.activity[i]
        let when: String
        switch stats.granularity {
        case .day: when = p.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: when = "Week of " + p.date.formatted(.dateTime.month(.abbreviated).day())
        case .month: when = p.date.formatted(.dateTime.month(.wide).year())
        }
        var s = "\(when) · \(ListeningText.plays(p.plays)) · \(ListeningText.listened(p.listened))"
        if i < stats.previousActivity.count { s += " (before: \(stats.previousActivity[i].plays.formatted()))" }
        return s
    }
}

// MARK: Top charts

/// Your top artist, album or song: a coloured panel with how many you played, the #1 with its picture, then the next.
public struct SpotlightCard: View {
    @Environment(\.listeningLinks) private var links
    let kind: ListeningKind
    let ranking: ListeningStats.Ranking
    let previous: Int?
    let measure: ListeningMeasure
    @State private var tint: RGB?
    @State private var expanded = false

    public init(kind: ListeningKind, ranking: ListeningStats.Ranking, previous: Int?, measure: ListeningMeasure) {
        self.kind = kind
        self.ranking = ranking
        self.previous = previous
        self.measure = measure
    }

    public var body: some View {
        let list = measure == .plays ? ranking.byPlays : ranking.byTime
        let panel = Color(tint ?? ListeningText.defaultPanel)
        VStack(alignment: .leading, spacing: 0) {
            header(list, panel: panel)
            if let first = list.first {
                hero(first, panel: panel)
                VStack(spacing: 1) {
                    ForEach(Array(list.dropFirst().prefix(expanded ? 24 : 4).enumerated()), id: \.element.id) { i, item in
                        ListeningRow(rank: i + 2, item: item, kind: kind, detail: detail(item))
                    }
                    if list.count > 5 {
                        ShowMoreButton(title: expanded ? "Show Less" : "Show Top \(min(list.count, 25))") { expanded.toggle() }
                    }
                }
                #if os(macOS)
                .padding(.vertical, 8).padding(.horizontal, 6)
                #else
                .padding(.horizontal, 14).padding(.vertical, 10)
                #endif
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
        .animation(.easeInOut(duration: 0.35), value: tint)
    }

    private func header(_ list: [ListeningStats.Item], panel: Color) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.plural).font(ListeningMetrics.spotlightLabel).foregroundStyle(.white.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ranking.total.formatted()).font(.system(size: ListeningMetrics.spotlightCount, weight: .bold, design: .rounded))
                    if let delta = ListeningText.change(Double(ranking.total), previous.map(Double.init)) { DeltaLabel(delta: delta, onPanel: true) }
                }
            }
            Spacer()
            MiniBars(values: list.prefix(8).map { measure == .plays ? Double($0.plays) : $0.listened })
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(panel)
        .help(kind.count(ranking.total) + " played" + (previous.map { ", vs \($0.formatted()) in the span before" } ?? ""))
        .accessibilityElement(children: .combine)
    }

    private func hero(_ item: ListeningStats.Item, panel: Color) -> some View {
        links.open(.item(item, kind), AnyView(
            Color.clear
                .aspectRatio(ListeningMetrics.spotlightAspect, contentMode: .fit)
                .overlay { links.art(item, kind, 400) { tint = ListeningText.panelTint($0) } }
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.top).font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(panel))
                        Text("#1 \(item.name)").font(.title3.weight(.bold)).lineLimit(2)
                        HStack(alignment: .firstTextBaseline) {
                            if kind != .artist, !item.subtitle.isEmpty { Text(item.subtitle).lineLimit(1) }
                            Spacer()
                            Text(detail(item)).monospacedDigit()
                        }
                        .font(ListeningMetrics.rowFont).foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }
                .clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
        ))
    }

    private func detail(_ item: ListeningStats.Item) -> String {
        measure == .plays ? ListeningText.plays(item.plays) : ListeningText.listened(item.listened)
    }
}

/// New to You: the share of artists, albums and songs first heard during the period, each with the top one; side by
/// side on the Mac, one under the other on the iPhone.
public struct DiscoveriesCard: View {
    let stats: ListeningStats

    public init(stats: ListeningStats) { self.stats = stats }

    public var body: some View {
        InsightCard(title: "New to You", subtitle: "First heard in the last \(stats.period.rawValue.lowercased())") {
            #if os(macOS)
            EvenRow(count: stats.albums.total > 0 ? 3 : 2) { entries }
            #else
            VStack(spacing: 14) { entries }
            #endif
        }
    }

    @ViewBuilder private var entries: some View {
        entry(.artist, stats.newArtists, stats.artists.total)
        if stats.albums.total > 0 { entry(.album, stats.newAlbums, stats.albums.total) }
        entry(.song, stats.newSongs, stats.songs.total)
    }

    private func entry(_ kind: ListeningKind, _ new: ListeningStats.Ranking, _ all: Int) -> some View {
        let share = all == 0 ? 0 : Double(new.total) / Double(all)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(VizColor.track, lineWidth: 6)
                    Circle().trim(from: 0, to: share).stroke(VizColor.series, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption2.weight(.bold)).monospacedDigit()
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New \(kind.plural.lowercased())").font(ListeningMetrics.rowFont.weight(.semibold))
                    Text("\(new.total.formatted()) of \(kind.count(all)) first heard").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if let top = new.byPlays.first {
                ListeningRow(rank: 1, item: top, kind: kind, detail: ListeningText.plays(top.plays), size: 32)
                    .rowInset()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Patterns

/// Listening by hour on a 24-hour dial, with the busiest hour and day.
public struct ListeningClockCard: View {
    let stats: ListeningStats
    @State private var selected: Int?

    public init(stats: ListeningStats) { self.stats = stats }

    #if os(macOS)
    private static let hint = "Hover an hour for details"
    #else
    private static let hint = "Tap an hour for details"
    #endif

    public var body: some View {
        let hours = stats.hourTotals
        InsightCard(title: "Listening Clock", subtitle: stats.peakHour.map { "Mostly \(ListeningText.daypart($0).name)" }) {
            VStack(alignment: .leading, spacing: 12) {
                Readout(text: selected.map { "\(ListeningText.hourLabel($0)) · \(ListeningText.listened(hours[$0])) · \(ListeningText.plays(stats.hourPlays[$0]))" },
                        hint: Self.hint)
                HStack(alignment: .center, spacing: 20) {
                    RadialClock(values: hours, selected: $selected)
                        .frame(width: ListeningMetrics.clockSide, height: ListeningMetrics.clockSide)
                    VStack(alignment: .leading, spacing: 12) {
                        if let h = stats.peakHour {
                            stat("Busiest hour", ListeningText.hourLabel(h), detail: "\(ListeningText.plays(stats.hourPlays[h])) in that hour")
                        }
                        if let d = stats.peakWeekday {
                            stat("Busiest day", ListeningText.weekdayName(d), detail: nil)
                            WeekdayBars(stats: stats)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: ListeningMetrics.clockStat, weight: .bold, design: .rounded)).lineLimit(1)
            if let detail { Text(detail).font(ListeningMetrics.clockDetail).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 24 wedges, midnight at the top, each as long as the listening in that hour; hover (Mac) or tap (iPhone) one.
private struct RadialClock: View {
    let values: [Double]
    @Binding var selected: Int?

    private static let inner = 0.32

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(0..<24, id: \.self) { h in
                    let reach = values[h] == 0 ? 0 : Self.inner + (1 - Self.inner) * max(0.08, (values[h] / peak).squareRoot())
                    Wedge(hour: h, inner: Self.inner, outer: 1).fill(VizColor.track)
                    if reach > 0 {
                        Wedge(hour: h, inner: Self.inner, outer: reach)
                            .fill(VizColor.series.opacity(selected == nil || selected == h ? 1 : 0.45))
                    }
                }
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    let r = side / 2 * Self.inner * 0.62
                    let angle = Double(h) / 24 * 2 * .pi - .pi / 2
                    Text(String(format: "%02d", h)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .position(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                guard case .active(let p) = phase else { selected = nil; return }
                selected = hour(at: p, center: center, radius: side / 2)
            }
            #else
            .onTapGesture { p in
                let h = hour(at: p, center: center, radius: side / 2)
                selected = h == selected ? nil : h
            }
            #endif
        }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening by hour of the day")
    }

    /// The wedge under a point, if it's on the dial.
    private func hour(at p: CGPoint, center: CGPoint, radius: CGFloat) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= radius * Self.inner * 0.8, distance <= radius else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return min(23, Int(angle / (2 * .pi) * 24))
    }
}

private struct Wedge: Shape {
    let hour: Int
    let inner: Double
    let outer: Double

    nonisolated func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = 1.2
        let start = Angle.degrees(Double(hour) * 15 - 90 + gap / 2), end = Angle.degrees(Double(hour + 1) * 15 - 90 - gap / 2)
        var p = Path()
        p.addArc(center: center, radius: radius * outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: center, radius: radius * inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// Listening per weekday, the busiest one in full colour.
private struct WeekdayBars: View {
    let stats: ListeningStats

    var body: some View {
        let totals = stats.weekdayTotals
        let top = max(totals.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d == stats.peakWeekday ? VizColor.series : VizColor.series.opacity(0.4))
                        .frame(width: ListeningMetrics.weekdayBar, height: max(2, ListeningMetrics.weekdayHeight * totals[d] / top))
                    Text(d < stats.weekdaySymbols.count ? String(stats.weekdaySymbols[d].prefix(1)) : "").font(.caption2).foregroundStyle(.secondary)
                }
                .help("\(ListeningText.weekdayName(d)): \(ListeningText.listened(totals[d]))")
            }
        }
        .frame(height: ListeningMetrics.weekdayHeight + 16, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Listening by release decade, with where the digital collection stands, and the top album of your top decade.
public struct DecadesCard: View {
    @Environment(\.listeningLinks) private var links
    let stats: ListeningStats
    @State private var hovered: Int?

    public init(stats: ListeningStats) { self.stats = stats }

    public var body: some View {
        let top = max(stats.eras.map { max($0.listening, $0.library) }.max() ?? 1, 0.0001)
        let favorite = stats.eras.max { $0.listening < $1.listening }
        InsightCard(title: "Music by Decade", subtitle: subtitle) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule().fill(VizColor.series).frame(width: 14, height: 7)
                    Text("Your listening")
                }
                HStack(spacing: 5) {
                    Capsule().fill(Color.primary).frame(width: 2, height: 11)
                    Text("Your digital collection")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(stats.eras) { e in
                    links.open(.query("decade:\(e.decade)s", title: "\(String(e.decade))s"), AnyView(row(e, top: top, favorite: favorite?.decade)))
                        #if os(macOS)
                        .onHover { hovered = $0 ? e.decade : (hovered == e.decade ? nil : hovered) }
                        .help("\(percent(e.listening)) of your listening, \(percent(e.library)) of your digital collection · click to search")
                        #endif
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(String(e.decade))s")
                        .accessibilityValue("\(percent(e.listening)) of your listening, \(percent(e.library)) of your digital collection")
                }
            }
            .rowInset()
            if let favorite, let album = favorite.topAlbum {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top album · \(String(favorite.decade))s").font(.caption).foregroundStyle(.secondary)
                    ListeningRow(item: album, kind: .album, detail: ListeningText.listened(album.listened), size: 44)
                        .rowInset()
                }
            }
        }
    }

    private func row(_ e: ListeningStats.EraShare, top: Double, favorite: Int?) -> some View {
        HStack(spacing: 10) {
            Text("\(String(e.decade))s").font(ListeningMetrics.rowFont).monospacedDigit().frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(VizColor.track)
                    Capsule().fill(VizColor.series.opacity(e.decade == favorite ? 1 : 0.7))
                        .frame(width: e.listening == 0 ? 0 : max(6, geo.size.width * e.listening / top))
                    if e.library > 0 {
                        Capsule().fill(Color.primary).frame(width: 2, height: 16)
                            .offset(x: geo.size.width * e.library / top - 1)
                    }
                }
                .frame(height: 12)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text(percent(e.listening)).font(ListeningMetrics.rowFont).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            #if !os(macOS)
            RowChevron()
            #endif
        }
        #if os(macOS)
        .padding(.vertical, 2).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered == e.decade ? AppColor.fill : .clear))
        #else
        .padding(.vertical, 4)
        #endif
        .contentShape(Rectangle())
    }

    private func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

    /// Calls out the decade played most out of proportion to the library.
    private var subtitle: String {
        let favored = stats.eras.filter { $0.listening >= 0.05 && $0.library > 0 }.max { $0.listening / $0.library < $1.listening / $1.library }
        if let f = favored, f.listening / f.library >= 1.5 {
            return "You play the \(String(f.decade))s \((f.listening / f.library).formatted(.number.precision(.fractionLength(1))))× more than your digital collection would suggest"
        }
        return "Listening time by release decade, next to your digital collection"
    }
}

/// A card of songs with their covers, the first few and then the rest.
public struct SongListCard: View {
    let title: String
    let subtitle: String
    let items: [(item: ListeningStats.Item, detail: String)]
    @State private var expanded = false

    public init(title: String, subtitle: String, items: [(item: ListeningStats.Item, detail: String)]) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }

    public var body: some View {
        InsightCard(title: title, subtitle: subtitle) {
            VStack(spacing: 1) {
                ForEach(Array(items.prefix(expanded ? 25 : 5).enumerated()), id: \.element.item.id) { _, entry in
                    ListeningRow(item: entry.item, kind: .song, detail: entry.detail)
                }
                if items.count > 5 {
                    ShowMoreButton(title: expanded ? "Show Less" : "Show All \(min(items.count, 25))") { expanded.toggle() }
                }
            }
            .rowInset()
        }
    }
}

/// The songs most often stopped before they counted.
public struct ListeningSkippedCard: View {
    let stats: ListeningStats

    public init(stats: ListeningStats) { self.stats = stats }

    public var body: some View {
        SongListCard(title: "Most Skipped",
                     subtitle: "Started but stopped before they counted · \(stats.skipRate.formatted(.percent.precision(.fractionLength(0)))) of listens",
                     items: stats.mostSkipped.map { ($0, "\($0.skips) skips") })
    }
}

/// Songs you used to play and haven't lately.
public struct ListeningRediscoverCard: View {
    let stats: ListeningStats

    public init(stats: ListeningStats) { self.stats = stats }

    public var body: some View {
        SongListCard(title: "Rediscover", subtitle: "Songs you used to play that you haven't in over 3 months",
                     items: stats.forgotten.map { i in
                         (i, ListeningText.plays(i.plays) + (i.lastPlayed.map { " · " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""))
                     })
    }
}

// MARK: Quick facts

/// The period's headline numbers against the span before, as many to a row as fit evenly.
public struct QuickFacts: View {
    let stats: ListeningStats

    public init(stats: ListeningStats) { self.stats = stats }

    private struct Fact: Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var icon: String
        var detail: String?
        var delta: Double?
        var vs: String?
    }

    public var body: some View {
        let facts = facts
        EvenRow(count: facts.count, minWidth: 150) {
            ForEach(facts) { tile($0) }
        }
    }

    private var facts: [Fact] {
        typealias T = ListeningText
        let previous = stats.previous
        let days = Double(max(stats.dayCount, 1))
        var out = [
            Fact(title: "Listening time", value: T.longDuration(stats.listened), icon: "headphones",
                 delta: T.change(stats.listened, previous?.listened), vs: previous.map { T.longDuration($0.listened) }),
            Fact(title: "Plays a day", value: (Double(stats.plays) / days).formatted(.number.precision(.fractionLength(0...1))), icon: "play.circle",
                 delta: T.change(Double(stats.plays), previous.map { Double($0.plays) }),
                 vs: previous.map { (Double($0.plays) / days).formatted(.number.precision(.fractionLength(0...1))) }),
        ]
        if let d = stats.biggestDay {
            out.append(Fact(title: "Most active day", value: T.longDuration(d.listened), icon: "chart.bar.fill",
                            detail: d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                            delta: T.change(d.listened, previous?.biggestDay?.listened),
                            vs: previous?.biggestDay.map { T.longDuration($0.listened) }))
        }
        out.append(Fact(title: "Days with music", value: "\(stats.activeDays.formatted()) of \(stats.dayCount.formatted())", icon: "calendar",
                        delta: T.change(Double(stats.activeDays), previous.map { Double($0.activeDays) }),
                        vs: previous.map { $0.activeDays.formatted() }))
        out.append(Fact(title: "Day streak", value: stats.currentStreak.formatted(), icon: "flame",
                        detail: "Longest: \(stats.longestStreak.formatted()) day\(stats.longestStreak == 1 ? "" : "s")"))
        out.append(Fact(title: "Songs played", value: stats.songs.total.formatted(), icon: "music.note",
                        detail: "\(stats.libraryPlayed.formatted(.percent.precision(.fractionLength(0...1)))) of your digital collection"))
        return out
    }

    private func tile(_ f: Fact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: f.icon).foregroundStyle(VizColor.series)
                Text(f.title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(ListeningMetrics.factTitle)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(f.value).font(.system(size: ListeningMetrics.factValue, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                if let delta = f.delta { DeltaLabel(delta: delta) }
            }
            Group {
                if let vs = f.vs, stats.period != .all {
                    Text("vs \(vs) in \(ListeningText.priorSpan(stats.period))")
                } else if let detail = f.detail {
                    Text(detail)
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ListeningMetrics.factPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
