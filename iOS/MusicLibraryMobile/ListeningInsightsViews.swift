import Charts
import MusicLibraryCore
import SwiftUI
import UIKit

// MARK: Pane

/// The Listening pane of Insights, laid out like the Mac's listening report: a banner with the period's plays against
/// the span before, your top artists, albums and songs with their pictures, what was new to you, when and what eras
/// you play, and quick facts. The period picker is above it, in `InsightsTab`.
struct ListeningInsightsPane: View {
    let stats: ListeningStats
    @AppStorage("listeningMeasure") private var measure = ListeningMeasure.plays

    var body: some View {
        if !stats.hasHistory {
            ContentUnavailableView("No Listening History Yet", systemImage: "headphones",
                                   description: Text("Play some music and this page fills in with what, when and how much you listen."))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(range).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
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
                    }
                    SpotlightCard(kind: .artist, ranking: stats.artists, previous: stats.previous?.artists, measure: measure)
                    if !stats.albums.byTime.isEmpty {
                        SpotlightCard(kind: .album, ranking: stats.albums, previous: stats.previous?.albums, measure: measure)
                    }
                    SpotlightCard(kind: .song, ranking: stats.songs, previous: stats.previous?.songs, measure: measure)
                    if stats.listeningShowsDiscoveries { DiscoveriesCard(stats: stats) }
                    ListeningSection(title: "Patterns")
                    ListeningClockCard(stats: stats)
                    if !stats.eras.isEmpty { DecadesCard(stats: stats) }
                    if !stats.genres.byPlays.isEmpty { ListenedGenresCard(stats: stats) }
                    if !stats.mostSkipped.isEmpty { ListeningSkippedCard(stats: stats) }
                    if !stats.forgotten.isEmpty { ListeningRediscoverCard(stats: stats) }
                    ListeningSection(title: "Quick Facts")
                    QuickFacts(stats: stats)
                    InsightFactsCard(facts: ListeningFacts.facts(stats))
                }
            }
        }
    }

    private var range: String {
        if stats.period == .all { return "Since \(stats.firstListen?.formatted(date: .long, time: .omitted) ?? "—")" }
        return "\(stats.start?.formatted(.dateTime.month(.abbreviated).day().year()) ?? "—") – \(stats.now.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

enum ListeningMeasure: String, CaseIterable, Identifiable {
    case plays = "Plays", time = "Time"
    var id: String { rawValue }
}

/// What a ranked item is, for its picture and where tapping it goes.
enum ListeningKind {
    case artist, album, song

    var plural: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        case .song: "Songs"
        }
    }

    var top: String {
        switch self {
        case .artist: "Top Artist"
        case .album: "Top Album"
        case .song: "Top Song"
        }
    }

    func count(_ n: Int) -> String {
        switch self {
        case .artist: n == 1 ? "1 artist" : "\(n.formatted()) artists"
        case .album: n == 1 ? "1 album" : "\(n.formatted()) albums"
        case .song: n == 1 ? "1 song" : "\(n.formatted()) songs"
        }
    }
}

/// Searches and names for listening items, and the clock's labels.
enum InsightListening {
    static func songQuery(_ item: ListeningStats.Item) -> String {
        SearchFilterKey.token("title", item.name) + (item.subtitle.isEmpty ? "" : " " + SearchFilterKey.token("artist", item.subtitle))
    }

    static func artistQuery(_ name: String) -> String? {
        name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", name)
    }

    static func albumQuery(_ item: ListeningStats.Item) -> String {
        SearchFilterKey.token("album", item.name) + " " + SearchFilterKey.token("albumartist", item.subtitle)
    }

    /// "Night owl", "Early bird"… for the hour most listening happens in.
    static func daypart(_ hour: Int) -> (name: String, title: String, icon: String) {
        switch hour {
        case 5..<12: ("mornings", "Early bird", "sunrise")
        case 12..<17: ("afternoons", "Afternoon listener", "sun.max")
        case 17..<22: ("evenings", "Evening listener", "sunset")
        default: ("late at night", "Night owl", "moon.stars")
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// Full weekday name for an index in `ListeningStats.clock` order.
    static func weekdayName(_ index: Int) -> String {
        let c = Calendar.current
        return c.weekdaySymbols[(index + c.firstWeekday - 1) % 7]
    }

    /// The span before the period, as the comparisons name it.
    static func priorSpan(_ period: ListeningStats.Period) -> String {
        switch period {
        case .week: "the 7 days before"
        case .month: "the 30 days before"
        case .year: "the 12 months before"
        case .all: ""
        }
    }

    /// The change from `previous` to `current` as a fraction; nil when there's nothing to compare with.
    static func change(_ current: Double, _ previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return current / previous - 1
    }

    /// The panel color when there's no picture to take one from.
    static let defaultPanel = ArtworkTint.panel(from: RGB(0x2a78d6))
}

extension ListeningStats {
    /// Only when there's history before the period: otherwise everything is new.
    var listeningShowsDiscoveries: Bool {
        guard period != .all, let first = firstListen, let start else { return false }
        return first < start && artists.total > 0
    }
}

private extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// A panel color taken from a picture, dark enough for white text.
private func panelTint(_ image: UIImage?) -> RGB? {
    guard let cg = image?.cgImage, let average = ArtworkTint.average(of: cg) else { return nil }
    return ArtworkTint.panel(from: average)
}

// MARK: Pictures

/// The artist's photo (or a cover of theirs), or the cover of the album or song.
private struct ListeningArt: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.displayScale) private var scale
    let item: ListeningStats.Item
    let kind: ListeningKind
    /// The largest side it's shown at, in points.
    var size: CGFloat
    /// Called with the picture once it's loaded (nil when there's none), e.g. to take a color from it.
    var onLoad: ((UIImage?) -> Void)?
    @State private var image: UIImage?

    var body: some View {
        let url = url
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                // Filled, the picture reaches past the frame: clipping hides that but it would still take taps.
                Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
            } else {
                Image(systemName: kind == .artist ? "music.mic" : "music.note")
                    .font(.system(size: max(10, size / 3))).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            let loaded = await url.asyncMap { await CoverLoader.image(at: $0, maxPixel: size * scale) } ?? nil
            image = loaded
            onLoad?(loaded)
        }
    }

    private var url: URL? {
        guard let library = model.library else { return nil }
        if kind == .artist, let photo = library.artistImageURL(item.name) { return photo }
        guard let id = item.trackId, let track = library.track(id: id) else { return nil }
        return LibraryPath.coverURL(forTrackAt: track.path, root: library.root)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

/// Opens what a ranked item is: an artist's page, an album, or a search for a song.
private struct ListeningLink<Label: View>: View {
    @Environment(PhoneModel.self) private var model
    let item: ListeningStats.Item
    let kind: ListeningKind
    @ViewBuilder var label: () -> Label

    var body: some View {
        Group {
            switch kind {
            case .artist:
                if item.name == "Unknown Artist" {
                    label()
                } else {
                    NavigationLink(value: ArtistNameRoute(name: item.name), label: label)
                }
            case .album:
                if let album = model.library?.album(forKey: String(item.id.dropFirst(3))) {
                    NavigationLink(value: album, label: label)
                } else {
                    NavigationLink(value: QueryRoute(query: InsightListening.albumQuery(item), title: item.name), label: label)
                }
            case .song:
                NavigationLink(value: QueryRoute(query: InsightListening.songQuery(item), title: item.name), label: label)
            }
        }
        .buttonStyle(.plain)
    }
}

/// One ranked item: rank, picture, name and the measure; tapping opens it.
private struct ListeningRow: View {
    var rank: Int?
    let item: ListeningStats.Item
    let kind: ListeningKind
    let detail: String
    var size: CGFloat = 36

    var body: some View {
        ListeningLink(item: item, kind: kind) {
            HStack(spacing: 10) {
                if let rank {
                    Text("#\(rank)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .leading)
                }
                ListeningArt(item: item, kind: kind, size: size)
                    .frame(width: size, height: size)
                    .clipShape(kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    if kind != .artist, !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(detail).font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                InsightChevron()
            }
            .font(.subheadline)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Building blocks

/// A bold section title with a short rule under it.
private struct ListeningSection<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.bold())
                Capsule().fill(InsightColor.series).frame(width: 30, height: 3)
            }
            Spacer()
            accessory()
        }
        .padding(.top, 8)
    }
}

extension ListeningSection where Accessory == EmptyView {
    init(title: String) { self.init(title: title, accessory: { EmptyView() }) }
}

/// "↑ 13%" or "↓ 4%"; on a dark panel it's white, elsewhere the arrow is green or red.
private struct DeltaLabel: View {
    let delta: Double
    var onPanel = false

    var body: some View {
        let up = delta >= 0
        HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up" : "arrow.down").fontWeight(.bold)
                .foregroundStyle(onPanel ? AnyShapeStyle(.white) : AnyShapeStyle(up ? Color.green : Color.red))
            Text(abs(delta).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(onPanel ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
        }
        .font(.caption.weight(.semibold)).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(up ? "Up" : "Down") \(abs(delta).formatted(.percent.precision(.fractionLength(0))))")
    }
}

// MARK: Banner

/// The period's plays, big, over a blurred photo of your top artist, with each day (week, month) against the
/// same span before.
private struct ListeningHero: View {
    @Environment(PhoneModel.self) private var model
    let stats: ListeningStats
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let delta = InsightListening.change(Double(stats.plays), stats.previous.map { Double($0.plays) }) {
                    DeltaLabel(delta: delta, onPanel: true)
                    Text("vs \(InsightListening.priorSpan(stats.period))").font(.caption).foregroundStyle(.white.opacity(0.75))
                } else {
                    Text(stats.period == .all ? "All time" : "Last \(stats.period.rawValue.lowercased())")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.plays.formatted()).font(.system(size: 50, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(stats.plays == 1 ? "play" : "plays").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Text(summary).font(.footnote).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            HeroChart(stats: stats, selected: $selected)
                .frame(height: 130)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var summary: String {
        var parts = ["\(formatLongDuration(stats.listened)) of music"]
        parts.append(ListeningKind.song.count(stats.songs.total))
        parts.append(ListeningKind.artist.count(stats.artists.total))
        if stats.skipped > 0 { parts.append("\(stats.skipped.formatted()) skipped") }
        return parts.joined(separator: " · ")
    }

    private var background: some View {
        ZStack {
            Color(InsightListening.defaultPanel)
            if let top = stats.artists.byPlays.first {
                ListeningArt(item: top, kind: .artist, size: 200)
                    .blur(radius: 30, opaque: true).saturation(1.25).opacity(0.9)
            }
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        // The filled photo reaches past the banner, over the period picker; it must not take its taps.
        .allowsHitTesting(false)
    }
}

/// Plays per day, week or month, white bars over the faded ones of the span before; drag for a readout.
private struct HeroChart: View {
    let stats: ListeningStats
    @Binding var selected: Int?

    var body: some View {
        let current = stats.activity, previous = stats.previousActivity
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let s = selected, s < current.count {
                    Text(readout(s))
                } else if !previous.isEmpty {
                    HStack(spacing: 12) {
                        legend("Last \(stats.period.rawValue.lowercased())", .white)
                        legend(InsightListening.priorSpan(stats.period).prefix(1).uppercased() + InsightListening.priorSpan(stats.period).dropFirst(),
                               .white.opacity(0.35))
                    }
                } else {
                    Text("Plays by \(stats.granularity.rawValue) · drag for details")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.8)
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
                // Every bucket is a category; only every `step`th one is labeled.
                let step = labelStep(current.count)
                AxisMarks { v in
                    if let s = v.as(String.self), let i = Int(s), i < current.count, i % step == 0 {
                        AxisValueLabel(collisionResolution: .disabled) {
                            Text(label(current[i].date)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
            .insightScrub(tap: { proxy, x in
                let i = proxy.value(atX: x, as: String.self).flatMap(Int.init)
                selected = i == selected ? nil : i
            }) { proxy, x in
                selected = proxy.value(atX: x, as: String.self).flatMap(Int.init)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plays by \(stats.granularity.rawValue)")
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    private func labelStep(_ count: Int) -> Int {
        let wanted = stats.granularity == .day && count <= 7 ? count : 4
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
        case .month: when = p.date.formatted(.dateTime.month(.abbreviated).year())
        }
        var s = "\(when) · \(playCount(p.plays)) · \(formatListened(p.listened))"
        if i < stats.previousActivity.count { s += " (before: \(stats.previousActivity[i].plays.formatted()))" }
        return s
    }
}

// MARK: Top charts

/// Your top artist, album or song: a colored panel with how many you played, the #1 with its picture, then the next.
private struct SpotlightCard: View {
    let kind: ListeningKind
    let ranking: ListeningStats.Ranking
    let previous: Int?
    let measure: ListeningMeasure
    @State private var tint: RGB?
    @State private var expanded = false

    var body: some View {
        let list = measure == .plays ? ranking.byPlays : ranking.byTime
        let panel = Color(tint ?? InsightListening.defaultPanel)
        VStack(alignment: .leading, spacing: 0) {
            header(list, panel: panel)
            if let first = list.first {
                hero(first, panel: panel)
                VStack(spacing: 0) {
                    ForEach(Array(list.dropFirst().prefix(expanded ? 24 : 4).enumerated()), id: \.element.id) { i, item in
                        ListeningRow(rank: i + 2, item: item, kind: kind, detail: detail(item))
                    }
                    if list.count > 5 {
                        Button(expanded ? "Show Less" : "Show Top \(min(list.count, 25))") { withAnimation(.snappy) { expanded.toggle() } }
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.35), value: tint)
    }

    private func header(_ list: [ListeningStats.Item], panel: Color) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.plural).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ranking.total.formatted()).font(.system(size: 28, weight: .bold, design: .rounded))
                    if let delta = InsightListening.change(Double(ranking.total), previous.map(Double.init)) { DeltaLabel(delta: delta, onPanel: true) }
                }
            }
            Spacer()
            MiniBars(values: list.prefix(8).map { measure == .plays ? Double($0.plays) : $0.listened })
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(panel)
        .accessibilityElement(children: .combine)
    }

    private func hero(_ item: ListeningStats.Item, panel: Color) -> some View {
        ListeningLink(item: item, kind: kind) {
            Color.clear
                .aspectRatio(1.4, contentMode: .fit)
                .overlay { ListeningArt(item: item, kind: kind, size: 400) { tint = panelTint($0) } }
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
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }
                .clipped()
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
        }
    }

    private func detail(_ item: ListeningStats.Item) -> String {
        measure == .plays ? playCount(item.plays) : formatListened(item.listened)
    }
}

/// A row of small bars, the shape of a ranking at a glance.
private struct MiniBars: View {
    let values: [Double]

    var body: some View {
        let top = max(values.max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.9))
                    .frame(width: 4, height: max(2, 24 * v / top))
            }
        }
        .frame(height: 24, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The share of artists, albums and songs played for the first time during the period, and the top of each.
private struct DiscoveriesCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "New to You", subtitle: "First heard in the last \(stats.period.rawValue.lowercased())") {
            VStack(spacing: 14) {
                row(.artist, stats.newArtists, stats.artists.total)
                if stats.albums.total > 0 { row(.album, stats.newAlbums, stats.albums.total) }
                row(.song, stats.newSongs, stats.songs.total)
            }
        }
    }

    private func row(_ kind: ListeningKind, _ new: ListeningStats.Ranking, _ all: Int) -> some View {
        let share = all == 0 ? 0 : Double(new.total) / Double(all)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(InsightColor.track, lineWidth: 6)
                    Circle().trim(from: 0, to: share).stroke(InsightColor.series, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption2.weight(.bold)).monospacedDigit()
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New \(kind.plural.lowercased())").font(.subheadline.weight(.semibold))
                    Text("\(new.total.formatted()) of \(kind.count(all))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            if let top = new.byPlays.first {
                ListeningRow(rank: 1, item: top, kind: kind, detail: playCount(top.plays), size: 32)
            }
        }
    }
}

// MARK: Patterns

/// Listening by hour on a 24-hour dial, with the busiest hour and day.
private struct ListeningClockCard: View {
    let stats: ListeningStats
    @State private var selected: Int?

    var body: some View {
        let hours = stats.hourTotals
        InsightCard(title: "Listening Clock", subtitle: stats.peakHour.map { "Mostly \(InsightListening.daypart($0).name)" }) {
            VStack(alignment: .leading, spacing: 12) {
                InsightReadout(text: selected.map { "\(InsightListening.hourLabel($0)) · \(formatListened(hours[$0])) · \(playCount(stats.hourPlays[$0]))" },
                               hint: "Tap an hour for details")
                HStack(alignment: .center, spacing: 18) {
                    RadialClock(values: hours, selected: $selected).frame(width: 160, height: 160)
                    VStack(alignment: .leading, spacing: 12) {
                        if let h = stats.peakHour {
                            stat("Busiest hour", InsightListening.hourLabel(h), detail: "\(playCount(stats.hourPlays[h])) in that hour")
                        }
                        if let d = stats.peakWeekday {
                            stat("Busiest day", InsightListening.weekdayName(d), detail: nil)
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
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 24 wedges, midnight at the top, each as long as the listening in that hour.
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
                    Wedge(hour: h, inner: Self.inner, outer: 1).fill(InsightColor.track)
                    if reach > 0 {
                        Wedge(hour: h, inner: Self.inner, outer: reach)
                            .fill(InsightColor.series.opacity(selected == nil || selected == h ? 1 : 0.45))
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
            .onTapGesture { p in
                let h = hour(at: p, center: center, radius: side / 2)
                selected = h == selected ? nil : h
            }
        }
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

private nonisolated struct Wedge: Shape {
    let hour: Int
    let inner: Double
    let outer: Double

    func path(in rect: CGRect) -> Path {
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

private struct WeekdayBars: View {
    let stats: ListeningStats

    var body: some View {
        let totals = stats.weekdayTotals
        let top = max(totals.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<7, id: \.self) { d in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d == stats.peakWeekday ? InsightColor.series : InsightColor.series.opacity(0.4))
                        .frame(width: 12, height: max(2, 36 * totals[d] / top))
                    Text(d < stats.weekdaySymbols.count ? String(stats.weekdaySymbols[d].prefix(1)) : "").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 52, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Listening by release decade, with where the digital collection stands, and the top album of your top decade.
private struct DecadesCard: View {
    let stats: ListeningStats

    var body: some View {
        let top = max(stats.eras.map { max($0.listening, $0.library) }.max() ?? 1, 0.0001)
        let favorite = stats.eras.max { $0.listening < $1.listening }
        InsightCard(title: "Music by Decade", subtitle: subtitle) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule().fill(InsightColor.series).frame(width: 14, height: 7)
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
                    NavigationLink(value: QueryRoute(query: "decade:\(e.decade)s", title: "\(String(e.decade))s")) {
                        HStack(spacing: 10) {
                            Text("\(String(e.decade))s").font(.subheadline).monospacedDigit().frame(width: 52, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(InsightColor.track)
                                    Capsule().fill(InsightColor.series.opacity(e.decade == favorite?.decade ? 1 : 0.7))
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
                            Text(e.listening.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                            InsightChevron()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(String(e.decade))s")
                    .accessibilityValue("\(e.listening.formatted(.percent.precision(.fractionLength(0)))) of your listening, \(e.library.formatted(.percent.precision(.fractionLength(0)))) of your digital collection")
                }
            }
            if let favorite, let album = favorite.topAlbum {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top album · \(String(favorite.decade))s").font(.caption).foregroundStyle(.secondary)
                    ListeningRow(item: album, kind: .album, detail: formatListened(album.listened), size: 44)
                }
            }
        }
    }

    /// Calls out the decade played most out of proportion to the library.
    private var subtitle: String {
        let favored = stats.eras.filter { $0.listening >= 0.05 && $0.library > 0 }.max { $0.listening / $0.library < $1.listening / $1.library }
        if let f = favored, f.listening / f.library >= 1.5 {
            return "You play the \(String(f.decade))s \((f.listening / f.library).formatted(.number.precision(.fractionLength(1))))× more than your digital collection would suggest"
        }
        return "Listening time by release decade, next to your digital collection"
    }
}

private struct ListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Top Genres", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            InsightRankedBars(items: stats.genres.byPlays.map {
                InsightRankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 6)
        }
    }
}

/// A card of songs with their covers, the first few and then the rest.
private struct SongListCard: View {
    let title: String
    let subtitle: String
    let items: [(item: ListeningStats.Item, detail: String)]
    @State private var expanded = false

    var body: some View {
        InsightCard(title: title, subtitle: subtitle) {
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(expanded ? 25 : 5).enumerated()), id: \.element.item.id) { _, entry in
                    ListeningRow(item: entry.item, kind: .song, detail: entry.detail)
                }
                if items.count > 5 {
                    Button(expanded ? "Show Less" : "Show All \(min(items.count, 25))") { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
        }
    }
}

private struct ListeningSkippedCard: View {
    let stats: ListeningStats

    var body: some View {
        SongListCard(title: "Most Skipped",
                     subtitle: "Started but stopped before they counted · \(stats.skipRate.formatted(.percent.precision(.fractionLength(0)))) of listens",
                     items: stats.mostSkipped.map { ($0, "\($0.skips) skips") })
    }
}

private struct ListeningRediscoverCard: View {
    let stats: ListeningStats

    var body: some View {
        SongListCard(title: "Rediscover", subtitle: "Songs you used to play that you haven't in over 3 months",
                     items: stats.forgotten.map { i in
                         (i, playCount(i.plays) + (i.lastPlayed.map { " · " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""))
                     })
    }
}

// MARK: Quick facts

/// The period's headline numbers against the span before, two to a row.
private struct QuickFacts: View {
    let stats: ListeningStats

    private struct Fact: Identifiable {
        var id: String { title }
        var title: String
        var value: String
        var icon: String
        var detail: String?
        var delta: Double?
        var vs: String?
    }

    var body: some View {
        let rows = stride(from: 0, to: facts.count, by: 2).map { Array(facts[$0..<min($0 + 2, facts.count)]) }
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { tile($0).gridCellColumns(rows[r].count == 1 ? 2 : 1) }
                }
            }
        }
    }

    private var facts: [Fact] {
        let previous = stats.previous
        let days = Double(max(stats.dayCount, 1))
        var out = [
            Fact(title: "Listening time", value: formatLongDuration(stats.listened), icon: "headphones",
                 delta: InsightListening.change(stats.listened, previous?.listened), vs: previous.map { formatLongDuration($0.listened) }),
            Fact(title: "Plays a day", value: (Double(stats.plays) / days).formatted(.number.precision(.fractionLength(0...1))), icon: "play.circle",
                 delta: InsightListening.change(Double(stats.plays), previous.map { Double($0.plays) }),
                 vs: previous.map { (Double($0.plays) / days).formatted(.number.precision(.fractionLength(0...1))) }),
        ]
        if let d = stats.biggestDay {
            out.append(Fact(title: "Most active day", value: formatLongDuration(d.listened), icon: "chart.bar.fill",
                            detail: d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                            delta: InsightListening.change(d.listened, previous?.biggestDay?.listened),
                            vs: previous?.biggestDay.map { formatLongDuration($0.listened) }))
        }
        out.append(Fact(title: "Days with music", value: "\(stats.activeDays.formatted()) of \(stats.dayCount.formatted())", icon: "calendar",
                        delta: InsightListening.change(Double(stats.activeDays), previous.map { Double($0.activeDays) }),
                        vs: previous.map { $0.activeDays.formatted() }))
        out.append(Fact(title: "Day streak", value: stats.currentStreak.formatted(), icon: "flame",
                        detail: "Longest: \(stats.longestStreak.formatted()) day\(stats.longestStreak == 1 ? "" : "s")"))
        out.append(Fact(title: "Songs played", value: stats.songs.total.formatted(), icon: "music.note",
                        detail: "\(stats.libraryPlayed.formatted(.percent.precision(.fractionLength(0...1)))) of your digital collection"))
        return out
    }

    private func tile(_ f: Fact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: f.icon).foregroundStyle(InsightColor.series)
                Text(f.title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(f.value).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                if let delta = f.delta { DeltaLabel(delta: delta) }
            }
            if let vs = f.vs, stats.period != .all {
                Text("vs \(vs) before").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let detail = f.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

private enum ListeningFacts {
    static func facts(_ stats: ListeningStats) -> [InsightFact] {
        var out: [InsightFact] = []
        if let s = stats.longestSession, s.songs > 1 {
            out.append(InsightFact(icon: "hourglass", title: "Longest session", value: formatLongDuration(s.listened),
                                   detail: "\(s.songs) songs in a row, \(s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
        }
        if let r = stats.onRepeat {
            out.append(InsightFact(icon: "repeat", title: "On repeat", value: r.song.name,
                                   detail: "\(r.plays) plays on \(r.date.formatted(.dateTime.month(.abbreviated).day()))\(r.song.subtitle.isEmpty ? "" : " · " + r.song.subtitle)",
                                   query: InsightListening.songQuery(r.song)))
        }
        if let h = stats.peakHour {
            let part = InsightListening.daypart(h)
            out.append(InsightFact(icon: part.icon, title: part.title, value: InsightListening.hourLabel(h), detail: "Your busiest hour of the day"))
        }
        if let a = stats.artists.byPlays.first, stats.plays > 0, stats.artists.total > 1 {
            let share = Double(a.plays) / Double(stats.plays)
            out.append(InsightFact(icon: "heart", title: "Most played artist", value: a.name,
                                   detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your plays", query: InsightListening.artistQuery(a.name)))
        }
        if stats.skipped > 0 {
            out.append(InsightFact(icon: "forward.end", title: "Skip rate", value: stats.skipRate.formatted(.percent.precision(.fractionLength(0))),
                                   detail: "\(stats.skipped.formatted()) of \(stats.listens.formatted()) listens stopped early"))
        }
        if stats.neverPlayed > 0 {
            out.append(InsightFact(icon: "sparkles", title: "Still unplayed", value: stats.neverPlayed.formatted(),
                                   detail: "songs in your digital collection waiting for their first play"))
        }
        if stats.period == .all, let first = stats.firstListen, let song = stats.firstSong {
            out.append(InsightFact(icon: "flag", title: "First listen", value: first.formatted(date: .abbreviated, time: .omitted),
                                   detail: song.name + (song.subtitle.isEmpty ? "" : " — " + song.subtitle),
                                   query: InsightListening.songQuery(song), queryTitle: song.name))
        }
        return out
    }
}
