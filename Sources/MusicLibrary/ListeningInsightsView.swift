import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Listening pane of Insights: what, when and how much you play, from the listening history.
struct ListeningContent: View {
    let stats: ListeningStats
    @Binding var period: ListeningStats.Period

    var body: some View {
        if !stats.hasHistory {
            ContentUnavailableView("No Listening History Yet", systemImage: "headphones",
                                   description: Text("Play some music and this page fills in with what, when and how much you listen."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if stats.listens == 0 {
                        InsightCard(title: "Nothing played in the last \(stats.period.rawValue.lowercased())") {
                            Text("Your listening history goes back to \(stats.firstListen!.formatted(date: .long, time: .omitted)). Pick a longer period above, or press play.")
                                .font(.callout).foregroundStyle(.subtext)
                        }
                    } else {
                        ListeningTiles(stats: stats)
                        ActivityCard(stats: stats)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        if stats.listens > 0 {
                            TopListenedCard(title: "Top Songs", kind: .songs, ranking: stats.songs)
                            TopListenedCard(title: "Top Artists", kind: .artists, ranking: stats.artists)
                            if !stats.albums.byTime.isEmpty { TopListenedCard(title: "Top Albums", kind: .albums, ranking: stats.albums) }
                            ClockCard(stats: stats)
                            if !stats.genres.byPlays.isEmpty { ListenedGenresCard(stats: stats) }
                            if !stats.eras.isEmpty { ErasCard(stats: stats) }
                            if stats.hasNewAndFamiliarArtists { NewArtistsCard(stats: stats) }
                            if !stats.mostSkipped.isEmpty { SkippedCard(stats: stats) }
                        }
                        if !stats.forgotten.isEmpty { RediscoverCard(stats: stats) }
                    }
                    if stats.listens > 0 { ListeningFactsCard(stats: stats) }
                }
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(range).font(.callout).foregroundStyle(.subtext)
            Spacer()
            Picker("Period", selection: $period) { ForEach(ListeningStats.Period.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var range: String {
        var s: String
        if stats.period == .all {
            s = "Since \(stats.firstListen!.formatted(date: .long, time: .omitted))"
        } else {
            s = "\(stats.start!.formatted(.dateTime.month(.abbreviated).day().year())) – today"
        }
        if stats.listens > 0 { s += " · \(stats.listens.formatted()) listen\(stats.listens == 1 ? "" : "s")" }
        return s
    }
}

func playCount(_ n: Int) -> String { n == 1 ? "1 play" : "\(n.formatted()) plays" }

private func songQuery(_ item: ListeningStats.Item) -> String {
    SearchFilterKey.token("title", item.name) + (item.subtitle.isEmpty ? "" : " " + SearchFilterKey.token("artist", item.subtitle))
}

private func artistQuery(_ name: String) -> String? {
    name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", name)
}

private func albumQuery(_ item: ListeningStats.Item) -> String {
    SearchFilterKey.token("album", item.name) + " " + SearchFilterKey.token("albumartist", item.subtitle)
}

/// "Night owl", "Early bird"… for the hour most listening happens in.
private func daypart(_ hour: Int) -> (name: String, title: String, icon: String) {
    switch hour {
    case 5..<12: ("mornings", "Early bird", "sunrise")
    case 12..<17: ("afternoons", "Afternoon listener", "sun.max")
    case 17..<22: ("evenings", "Evening listener", "sunset")
    default: ("late at night", "Night owl", "moon.stars")
    }
}

private func hourLabel(_ hour: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    return date.formatted(.dateTime.hour())
}

/// Full weekday name for an index in `ListeningStats.clock` order.
private func weekdayName(_ index: Int) -> String {
    let c = Calendar.current
    return c.weekdaySymbols[(index + c.firstWeekday - 1) % 7]
}

// MARK: Tiles

struct ListeningTiles: View {
    let stats: ListeningStats

    var body: some View {
        TileGrid {
            InsightTile(value: formatLongDuration(stats.listened), label: "Listening time", icon: "headphones",
                        detail: change ?? "\(stats.listens.formatted()) listen\(stats.listens == 1 ? "" : "s")")
            InsightTile(value: stats.plays.formatted(), label: stats.plays == 1 ? "Play" : "Plays", icon: "play.circle",
                        detail: stats.skipped > 0 ? "plus \(stats.skipped.formatted()) skipped" : "none skipped")
            InsightTile(value: stats.songs.total.formatted(), label: stats.songs.total == 1 ? "Song" : "Different songs", icon: "music.note",
                        detail: "\(stats.libraryPlayed.formatted(.percent.precision(.fractionLength(0...1)))) of your digital collection")
            InsightTile(value: stats.artists.total.formatted(), label: stats.artists.total == 1 ? "Artist" : "Artists", icon: "music.mic",
                        detail: stats.hasNewAndFamiliarArtists ? "\(stats.newArtists.total.formatted()) new to you" : "album artists")
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

struct ActivityCard: View {
    @Environment(\.theme) private var theme
    let stats: ListeningStats
    @State private var hovered: ListeningStats.ActivityPoint?

    var body: some View {
        let inHours = (stats.activity.map(\.listened).max() ?? 0) >= 3 * 3600
        let scale = inHours ? 3600.0 : 60.0
        InsightCard(title: "Listening Over Time", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let h = hovered {
                        Text("\(period(h.date)) · \(formatLongDuration(h.listened)) · \(playCount(h.plays))").foregroundStyle(.primary)
                    } else {
                        Text("Time spent listening, by \(stats.granularity.rawValue)").foregroundStyle(.subtext)
                    }
                }
                .font(.caption).monospacedDigit()
                Chart(stats.activity) { p in
                    BarMark(x: .value("Date", p.date, unit: unit), y: .value(inHours ? "Hours" : "Minutes", p.listened / scale))
                        .foregroundStyle(theme.series.opacity(hovered == nil || hovered == p ? 1 : 0.35))
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(d.formatted() + (inHours ? " h" : " min")) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let p) = phase, let frame = proxy.plotFrame,
                                      let date = proxy.value(atX: p.x - geo[frame].origin.x, as: Date.self) else { hovered = nil; return }
                                hovered = stats.activity.last { $0.date <= date } ?? stats.activity.first
                            }
                    }
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
        return parts.joined(separator: " · ").capitalizedFirst
    }

    private func period(_ d: Date) -> String {
        switch stats.granularity {
        case .day: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.wide).year())
        }
    }
}

struct TopListenedCard: View {
    enum Kind { case songs, artists, albums }
    enum Measure: String, CaseIterable { case plays = "Plays", time = "Time" }
    let title: String
    let kind: Kind
    let ranking: ListeningStats.Ranking
    @State private var measure = Measure.plays

    var body: some View {
        InsightCard(title: title, subtitle: subtitle) {
            Picker("", selection: $measure) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            RankedBars(items: items, initialCount: kind == .artists ? 8 : 6).id(measure)
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

    private var items: [RankedItem] {
        let list = measure == .plays ? ranking.byPlays : ranking.byTime
        return list.map { i in
            let value = measure == .plays ? Double(i.plays) : i.listened
            let detail = measure == .plays ? playCount(i.plays) : formatLongDuration(i.listened)
            switch kind {
            case .songs:
                return RankedItem(name: i.name, value: value, detail: detail, query: songQuery(i), subtitle: i.subtitle, key: i.id)
            case .artists:
                return RankedItem(name: i.name, value: value, detail: detail, query: artistQuery(i.name), key: i.id)
            case .albums:
                return RankedItem(name: i.name, value: value, detail: detail, query: albumQuery(i), subtitle: i.subtitle, key: i.id)
            }
        }
    }
}

/// Listening by weekday and hour as a heat map.
struct ClockCard: View {
    @Environment(\.theme) private var theme
    let stats: ListeningStats
    @State private var hovered: Cell?

    struct Cell: Hashable { var day: Int; var hour: Int }

    private static let spacing: CGFloat = 3
    private static let labelWidth: CGFloat = 34

    var body: some View {
        let peak = max(stats.clock.joined().max() ?? 0, 1)
        InsightCard(title: "When You Listen", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let h = hovered {
                        Text("\(weekdayName(h.day)) \(hourLabel(h.hour)) · \(formatLongDuration(stats.clock[h.day][h.hour]))").foregroundStyle(.primary)
                    } else {
                        Text("Darker means more listening").foregroundStyle(.subtext)
                    }
                }
                .font(.caption).monospacedDigit()
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(0..<7, id: \.self) { d in
                        HStack(spacing: Self.spacing) {
                            Text(stats.weekdaySymbols[d]).font(.caption2).foregroundStyle(.subtext)
                                .frame(width: Self.labelWidth, alignment: .leading)
                            ForEach(0..<24, id: \.self) { h in
                                let v = stats.clock[d][h]
                                let cell = Cell(day: d, hour: h)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(v == 0 ? theme.track : theme.series.opacity(0.18 + 0.82 * (v / peak).squareRoot()))
                                    .overlay {
                                        if hovered == cell { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1) }
                                    }
                                    .frame(height: 15)
                                    .onHover { hovered = $0 ? cell : (hovered == cell ? nil : hovered) }
                            }
                        }
                    }
                    GeometryReader { geo in
                        let width = geo.size.width - Self.labelWidth - Self.spacing
                        ZStack(alignment: .topLeading) {
                            ForEach([0, 6, 12, 18], id: \.self) { h in
                                Text(hourLabel(h)).font(.caption2).foregroundStyle(.subtext).fixedSize()
                                    .offset(x: Self.labelWidth + Self.spacing + CGFloat(h) * (width + Self.spacing) / 24)
                            }
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
    }

    private var subtitle: String {
        guard let hour = stats.peakHour, let day = stats.peakWeekday else { return "" }
        var parts = ["Mostly \(daypart(hour).name)", "busiest on \(weekdayName(day))s"]
        parts.append("peak at \(hourLabel(hour))")
        return parts.joined(separator: " · ")
    }
}

struct ListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Genres You Play", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            RankedBars(items: stats.genres.byPlays.map {
                RankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 6)
        }
    }
}

/// Your listening by decade next to how the library is spread across decades.
struct ErasCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let stats: ListeningStats
    @State private var hovered: Int?

    var body: some View {
        let top = max(stats.eras.map { max($0.listening, $0.library) }.max() ?? 1, 0.0001)
        InsightCard(title: "Eras You Play", subtitle: subtitle) {
            HStack(spacing: 14) {
                legend("Your listening", theme.series)
                legend("Your digital collection", theme.neutral)
            }
            .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(stats.eras) { e in
                    Button { model.search("decade:\(e.decade)s") } label: {
                        HStack(spacing: 10) {
                            Text("\(String(e.decade))s").font(.callout).frame(width: 56, alignment: .leading)
                            GeometryReader { geo in
                                VStack(alignment: .leading, spacing: 2) {
                                    Capsule().fill(theme.series).frame(width: e.listening == 0 ? 0 : max(3, geo.size.width * e.listening / top), height: 7)
                                    Capsule().fill(theme.neutral).frame(width: e.library == 0 ? 0 : max(3, geo.size.width * e.library / top), height: 7)
                                }
                                .frame(maxHeight: .infinity)
                            }
                            .frame(height: 16)
                            Text(e.listening.formatted(.percent.precision(.fractionLength(0)))).font(.callout).monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hovered == e.decade ? theme.fill : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? e.decade : (hovered == e.decade ? nil : hovered) }
                    .help("\(e.listening.formatted(.percent.precision(.fractionLength(0)))) of your listening, \(e.library.formatted(.percent.precision(.fractionLength(0)))) of your digital collection · click to search")
                }
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 7)
            Text(label).foregroundStyle(.subtext)
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

struct NewArtistsCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "New to You", subtitle: "Artists you first played in the last \(stats.period.rawValue.lowercased())") {
            RankedBars(items: stats.newArtists.byPlays.map {
                RankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: artistQuery($0.name), key: $0.id)
            }, initialCount: 6)
        }
    }
}

struct SkippedCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Most Skipped", subtitle: "Started but stopped before they counted · \(stats.skipRate.formatted(.percent.precision(.fractionLength(0)))) of listens") {
            RankedBars(items: stats.mostSkipped.map {
                RankedItem(name: $0.name, value: Double($0.skips), detail: "\($0.skips) skips", query: songQuery($0), subtitle: $0.subtitle, key: $0.id)
            }, initialCount: 5)
        }
    }
}

struct RediscoverCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Rediscover", subtitle: "Songs you used to play that you haven't in over 3 months") {
            RankedBars(items: stats.forgotten.map { i in
                RankedItem(name: i.name, value: Double(i.plays),
                           detail: playCount(i.plays) + (i.lastPlayed.map { " · " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""),
                           query: songQuery(i), subtitle: i.subtitle, key: i.id)
            }, initialCount: 5)
        }
    }
}

struct ListeningFactsCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Fun Facts") { FactsGrid(facts: facts) }
    }

    private var facts: [FunFact] {
        var out: [FunFact] = []
        if let d = stats.biggestDay, stats.activeDays > 1 {
            out.append(FunFact(icon: "chart.bar.fill", title: "Biggest day", value: formatLongDuration(d.listened),
                               detail: "\(d.date.formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(playCount(d.plays))"))
        }
        if let s = stats.longestSession, s.songs > 1 {
            out.append(FunFact(icon: "hourglass", title: "Longest session", value: formatLongDuration(s.listened),
                               detail: "\(s.songs) songs in a row, \(s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
        }
        if let r = stats.onRepeat {
            out.append(FunFact(icon: "repeat", title: "On repeat", value: r.song.name,
                               detail: "\(r.plays) plays on \(r.date.formatted(.dateTime.month(.abbreviated).day()))\(r.song.subtitle.isEmpty ? "" : " · " + r.song.subtitle)",
                               query: songQuery(r.song)))
        }
        if let h = stats.peakHour {
            let part = daypart(h)
            out.append(FunFact(icon: part.icon, title: part.title, value: hourLabel(h), detail: "Your busiest hour of the day"))
        }
        if let d = stats.peakWeekday, stats.weekdayTotals.filter({ $0 > 0 }).count > 1 {
            let share = stats.weekdayTotals[d] / max(stats.listened, 1)
            out.append(FunFact(icon: "calendar.badge.clock", title: "Favorite day", value: weekdayName(d),
                               detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your listening"))
        }
        if let a = stats.artists.byPlays.first, stats.plays > 0, stats.artists.total > 1 {
            let share = Double(a.plays) / Double(stats.plays)
            out.append(FunFact(icon: "heart", title: "Most played artist", value: a.name,
                               detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your plays", query: artistQuery(a.name)))
        }
        if stats.skipped > 0 {
            out.append(FunFact(icon: "forward.end", title: "Skip rate", value: stats.skipRate.formatted(.percent.precision(.fractionLength(0))),
                               detail: "\(stats.skipped.formatted()) of \(stats.listens.formatted()) listens stopped early"))
        }
        if stats.neverPlayed > 0 {
            out.append(FunFact(icon: "sparkles", title: "Still unplayed", value: stats.neverPlayed.formatted(),
                               detail: "songs in your digital collection waiting for their first play"))
        }
        if stats.period == .all, let first = stats.firstListen, let song = stats.firstSong {
            out.append(FunFact(icon: "flag", title: "First listen", value: first.formatted(date: .abbreviated, time: .omitted),
                               detail: song.name + (song.subtitle.isEmpty ? "" : " — " + song.subtitle), query: songQuery(song)))
        }
        return out
    }
}

private extension ListeningStats {
    /// Some artists are new this period and some aren't; when all of them are, a "new" list just repeats the top artists.
    var hasNewAndFamiliarArtists: Bool { newArtists.total > 0 && newArtists.total < artists.total }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
