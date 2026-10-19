import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Listening pane of Insights: what, when and how much you play, from the listening history. The period picker
/// is above it, in `InsightsTab`.
struct ListeningInsightsPane: View {
    let stats: ListeningStats

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
                } else {
                    InsightsListeningTiles(stats: stats)
                    InsightsActivityCard(stats: stats)
                    InsightsTopListenedCard(title: "Top Songs", kind: .songs, ranking: stats.songs)
                    InsightsTopListenedCard(title: "Top Artists", kind: .artists, ranking: stats.artists)
                    if !stats.albums.byTime.isEmpty { InsightsTopListenedCard(title: "Top Albums", kind: .albums, ranking: stats.albums) }
                    InsightsClockCard(stats: stats)
                    if !stats.genres.byPlays.isEmpty { InsightsListenedGenresCard(stats: stats) }
                    if !stats.eras.isEmpty { InsightsErasCard(stats: stats) }
                    if stats.insightHasNewAndFamiliarArtists { InsightsNewArtistsCard(stats: stats) }
                    if !stats.mostSkipped.isEmpty { InsightsSkippedCard(stats: stats) }
                }
                if !stats.forgotten.isEmpty { InsightsRediscoverCard(stats: stats) }
                if stats.listens > 0 { InsightsListeningFactsCard(stats: stats) }
            }
        }
    }

    private var range: String {
        var s: String
        if stats.period == .all {
            s = "Since \(stats.firstListen?.formatted(date: .long, time: .omitted) ?? "—")"
        } else {
            s = "\(stats.start?.formatted(.dateTime.month(.abbreviated).day().year()) ?? "—") – today"
        }
        if stats.listens > 0 { s += " · \(stats.listens.formatted()) listen\(stats.listens == 1 ? "" : "s")" }
        return s
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
}

extension ListeningStats {
    /// Some artists are new this period and some aren't; when all of them are, a "new" list just repeats the top artists.
    var insightHasNewAndFamiliarArtists: Bool { newArtists.total > 0 && newArtists.total < artists.total }
}

// MARK: Tiles

struct InsightsListeningTiles: View {
    let stats: ListeningStats

    var body: some View {
        InsightTileGrid {
            InsightTile(value: formatLongDuration(stats.listened), label: "Listening time", icon: "headphones",
                        detail: change ?? "\(stats.listens.formatted()) listen\(stats.listens == 1 ? "" : "s")")
            InsightTile(value: stats.plays.formatted(), label: stats.plays == 1 ? "Play" : "Plays", icon: "play.circle",
                        detail: stats.skipped > 0 ? "plus \(stats.skipped.formatted()) skipped" : "none skipped")
            InsightTile(value: stats.songs.total.formatted(), label: stats.songs.total == 1 ? "Song" : "Different songs", icon: "music.note",
                        detail: "\(stats.libraryPlayed.formatted(.percent.precision(.fractionLength(0...1)))) of your digital collection")
            InsightTile(value: stats.artists.total.formatted(), label: stats.artists.total == 1 ? "Artist" : "Artists", icon: "music.mic",
                        detail: stats.insightHasNewAndFamiliarArtists ? "\(stats.newArtists.total.formatted()) new to you" : "album artists")
            InsightTile(value: formatLongDuration(stats.dailyAverage), label: "A day on average", icon: "calendar",
                        detail: "Played on \(stats.activeDays.formatted()) of \(stats.dayCount.formatted()) days")
            InsightTile(value: stats.currentStreak.formatted(), label: "Day streak", icon: "flame",
                        detail: "Longest: \(stats.longestStreak.formatted()) day\(stats.longestStreak == 1 ? "" : "s")")
        }
    }

    /// Listening time compared with the same span just before.
    private var change: String? {
        guard let previous = stats.previousListened, previous > 0 else { return nil }
        let delta = stats.listened / previous - 1
        let span = stats.period == .year ? "12 months" : "\(stats.period.days ?? 0) days"
        return (delta >= 0 ? "↑ " : "↓ ") + abs(delta).formatted(.percent.precision(.fractionLength(0))) + " vs prior \(span)"
    }
}

// MARK: Cards

struct InsightsActivityCard: View {
    let stats: ListeningStats
    @State private var selected: ListeningStats.ActivityPoint?

    var body: some View {
        let inHours = (stats.activity.map(\.listened).max() ?? 0) >= 3 * 3600
        let scale = inHours ? 3600.0 : 60.0
        InsightCard(title: "Listening Over Time", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 12) {
                InsightReadout(text: selected.map { "\(period($0.date)) · \(formatLongDuration($0.listened)) · \(playCount($0.plays))" },
                               hint: "Time spent listening, by \(stats.granularity.rawValue) · drag for details")
                Chart(stats.activity) { p in
                    BarMark(x: .value("Date", p.date, unit: unit), y: .value(inHours ? "Hours" : "Minutes", p.listened / scale))
                        .foregroundStyle(InsightColor.series.opacity(selected == nil || selected == p ? 1 : 0.35))
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(d.formatted() + (inHours ? " h" : " min")) } }
                    }
                }
                .insightScrub { proxy, x in
                    guard let date = proxy.value(atX: x, as: Date.self) else { return }
                    selected = stats.activity.last { $0.date <= date } ?? stats.activity.first
                }
                .frame(height: 170)
            }
        }
    }

    private var unit: Calendar.Component {
        switch stats.granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let best = stats.activity.max(by: { $0.listened < $1.listened }), best.listened > 0, stats.activity.count > 1 {
            parts.append("best \(stats.granularity.rawValue): \(period(best.date))")
        }
        // Days before a short history are only padding, so the daily average comes from the period itself.
        let average = stats.granularity == .day ? stats.dailyAverage : stats.listened / Double(max(stats.activity.count, 1))
        parts.append("\(formatLongDuration(average)) per \(stats.granularity.rawValue) on average")
        let s = parts.joined(separator: " · ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func period(_ d: Date) -> String {
        switch stats.granularity {
        case .day: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.wide).year())
        }
    }
}

struct InsightsTopListenedCard: View {
    enum Kind { case songs, artists, albums }
    enum Measure: String, CaseIterable { case plays = "Plays", time = "Time" }
    let title: String
    let kind: Kind
    let ranking: ListeningStats.Ranking
    @State private var measure = Measure.plays

    var body: some View {
        InsightCard(title: title, subtitle: subtitle) {
            InsightSegments(selection: $measure)
        } content: {
            InsightRankedBars(items: items, initialCount: kind == .artists ? 8 : 6).id(measure)
        }
    }

    private var subtitle: String {
        let n = ranking.total.formatted()
        switch kind {
        case .songs: return "\(n) song\(ranking.total == 1 ? "" : "s") played"
        case .artists: return "\(n) album artist\(ranking.total == 1 ? "" : "s") played"
        case .albums: return "\(n) album\(ranking.total == 1 ? "" : "s") played"
        }
    }

    private var items: [InsightRankedItem] {
        let list = measure == .plays ? ranking.byPlays : ranking.byTime
        return list.map { i in
            let value = measure == .plays ? Double(i.plays) : i.listened
            let detail = measure == .plays ? playCount(i.plays) : formatLongDuration(i.listened)
            switch kind {
            case .songs:
                return InsightRankedItem(name: i.name, value: value, detail: detail, query: InsightListening.songQuery(i), subtitle: i.subtitle, key: i.id)
            case .artists:
                return InsightRankedItem(name: i.name, value: value, detail: detail, query: InsightListening.artistQuery(i.name), key: i.id)
            case .albums:
                return InsightRankedItem(name: i.name, value: value, detail: detail, query: InsightListening.albumQuery(i), subtitle: i.subtitle, key: i.id)
            }
        }
    }
}

/// Listening by weekday and hour as a heat map; tap a cell (or drag across a row) for its readout.
struct InsightsClockCard: View {
    let stats: ListeningStats
    @State private var selected: Cell?
    @State private var gridWidth: CGFloat = 0

    struct Cell: Hashable { var day: Int; var hour: Int }

    private static let spacing: CGFloat = 2
    private static let labelWidth: CGFloat = 30
    private static let cellHeight: CGFloat = 16

    var body: some View {
        let peak = max(stats.clock.joined().max() ?? 0, 1)
        InsightCard(title: "When You Listen", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 12) {
                InsightReadout(text: selected.flatMap(readout), hint: "Darker means more listening · tap a cell for details")
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(0..<min(stats.clock.count, 7), id: \.self) { d in
                        HStack(spacing: Self.spacing) {
                            Text(d < stats.weekdaySymbols.count ? stats.weekdaySymbols[d] : "").font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: Self.labelWidth, alignment: .leading)
                            ForEach(0..<min(stats.clock[d].count, 24), id: \.self) { h in
                                let v = stats.clock[d][h]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(v == 0 ? InsightColor.track : InsightColor.series.opacity(0.18 + 0.82 * (v / peak).squareRoot()))
                                    .overlay {
                                        if selected == Cell(day: d, hour: h) {
                                            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
                                        }
                                    }
                                    .frame(height: Self.cellHeight)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                .onTapGesture { p in
                    let c = cell(at: p)
                    selected = c == selected ? nil : c
                }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height), let c = cell(at: v.location) else { return }
                    selected = c
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Listening by weekday and hour")
                .accessibilityValue(subtitle)
                GeometryReader { geo in
                    let width = geo.size.width - Self.labelWidth - Self.spacing
                    ZStack(alignment: .topLeading) {
                        ForEach([0, 6, 12, 18], id: \.self) { h in
                            Text(InsightListening.hourLabel(h)).font(.caption2).foregroundStyle(.secondary).fixedSize()
                                .offset(x: Self.labelWidth + Self.spacing + CGFloat(h) * (width + Self.spacing) / 24)
                        }
                    }
                }
                .frame(height: 14)
                .accessibilityHidden(true)
            }
        }
    }

    private func readout(_ c: Cell) -> String? {
        guard c.day < stats.clock.count, c.hour < stats.clock[c.day].count else { return nil }
        return "\(InsightListening.weekdayName(c.day)) \(InsightListening.hourLabel(c.hour)) · \(formatLongDuration(stats.clock[c.day][c.hour]))"
    }

    /// The cell under a point in the grid.
    private func cell(at p: CGPoint) -> Cell? {
        let x = p.x - Self.labelWidth - Self.spacing
        let column = (gridWidth - Self.labelWidth) / 24
        guard x >= 0, column > 0, p.y >= 0 else { return nil }
        return Cell(day: min(6, Int(p.y / (Self.cellHeight + Self.spacing))), hour: min(23, Int(x / column)))
    }

    private var subtitle: String {
        guard let hour = stats.peakHour, let day = stats.peakWeekday else { return "" }
        return ["Mostly \(InsightListening.daypart(hour).name)", "busiest on \(InsightListening.weekdayName(day))s",
                "peak at \(InsightListening.hourLabel(hour))"].joined(separator: " · ")
    }
}

struct InsightsListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Genres You Play", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            InsightRankedBars(items: stats.genres.byPlays.map {
                InsightRankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 6)
        }
    }
}

/// Your listening by decade next to how the library is spread across decades.
struct InsightsErasCard: View {
    let stats: ListeningStats

    var body: some View {
        let top = max(stats.eras.map { max($0.listening, $0.library) }.max() ?? 1, 0.0001)
        InsightCard(title: "Eras You Play", subtitle: subtitle) {
            HStack(spacing: 14) {
                legend("Your listening", InsightColor.series)
                legend("Your digital collection", InsightColor.neutral)
            }
            .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(stats.eras) { e in
                    NavigationLink(value: QueryRoute(query: "decade:\(e.decade)s", title: "\(String(e.decade))s")) {
                        HStack(spacing: 10) {
                            Text("\(String(e.decade))s").font(.subheadline).frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                InsightBar(fraction: e.listening / top, height: 7, minWidth: 3, hidesZero: true)
                                InsightBar(fraction: e.library / top, color: InsightColor.neutral, height: 7, minWidth: 3, hidesZero: true)
                            }
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(e.listening.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline)
                                Text(e.library.formatted(.percent.precision(.fractionLength(0)))).font(.caption2).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
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
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 7)
            Text(label).foregroundStyle(.secondary)
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

struct InsightsNewArtistsCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "New to You", subtitle: "Artists you first played in the last \(stats.period.rawValue.lowercased())") {
            InsightRankedBars(items: stats.newArtists.byPlays.map {
                InsightRankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: InsightListening.artistQuery($0.name), key: $0.id)
            }, initialCount: 6)
        }
    }
}

struct InsightsSkippedCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Most Skipped", subtitle: "Started but stopped before they counted · \(stats.skipRate.formatted(.percent.precision(.fractionLength(0)))) of listens") {
            InsightRankedBars(items: stats.mostSkipped.map {
                InsightRankedItem(name: $0.name, value: Double($0.skips), detail: "\($0.skips) skips", query: InsightListening.songQuery($0),
                                  subtitle: $0.subtitle, key: $0.id)
            }, initialCount: 5)
        }
    }
}

struct InsightsRediscoverCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Rediscover", subtitle: "Songs you used to play that you haven't in over 3 months") {
            InsightRankedBars(items: stats.forgotten.map { i in
                InsightRankedItem(name: i.name, value: Double(i.plays),
                                  detail: playCount(i.plays) + (i.lastPlayed.map { " · " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""),
                                  query: InsightListening.songQuery(i), subtitle: i.subtitle, key: i.id)
            }, initialCount: 5)
        }
    }
}

struct InsightsListeningFactsCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightFactsCard(facts: facts)
    }

    private var facts: [InsightFact] {
        var out: [InsightFact] = []
        if let d = stats.biggestDay, stats.activeDays > 1 {
            out.append(InsightFact(icon: "chart.bar.fill", title: "Biggest day", value: formatLongDuration(d.listened),
                                   detail: "\(d.date.formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(playCount(d.plays))"))
        }
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
        if let d = stats.peakWeekday, stats.weekdayTotals.filter({ $0 > 0 }).count > 1 {
            let share = stats.weekdayTotals[d] / max(stats.listened, 1)
            out.append(InsightFact(icon: "calendar.badge.clock", title: "Favorite day", value: InsightListening.weekdayName(d),
                                   detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your listening"))
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
