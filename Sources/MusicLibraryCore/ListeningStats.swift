import Foundation

/// What, when and how much you listen, computed from the play history for one period. Like `LibraryStats`,
/// it is computed in one pass and bucket granularity adapts to the span. A play "counts" by the scrobble
/// rule; listens that didn't count are treated as skips, and listening time includes them.
public struct ListeningStats: Sendable {
    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case week = "7 Days", month = "30 Days", year = "12 Months", all = "All Time"
        public var id: String { rawValue }
        /// Days covered, ending today; nil for all time.
        public var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .year: 365
            case .all: nil
            }
        }
    }

    public enum Granularity: String, Sendable { case day, week, month }

    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String
        /// Song title, artist, album or genre.
        public var name: String
        /// The artist, for songs and albums.
        public var subtitle: String
        public var plays: Int
        public var skips: Int
        public var listened: Double
        public var trackId: Int64?
        public var lastPlayed: Date?
    }

    /// Items ranked two ways, plus how many there are in all.
    public struct Ranking: Sendable {
        public var byPlays: [Item] = []
        public var byTime: [Item] = []
        public var total = 0
    }

    public struct ActivityPoint: Identifiable, Hashable, Sendable {
        public var id: Date { date }
        public var date: Date
        public var listened: Double
        public var plays: Int
    }

    public struct EraShare: Identifiable, Hashable, Sendable {
        public var id: Int { decade }
        public var decade: Int
        /// Fraction of listening time spent on music from the decade.
        public var listening: Double
        /// Fraction of the library's (dated) running time from the decade.
        public var library: Double
    }

    public struct Day: Hashable, Sendable {
        public var date: Date
        public var listened: Double
        public var plays: Int
    }

    public struct Session: Hashable, Sendable {
        public var start: Date
        public var listened: Double
        public var songs: Int
    }

    public struct Repeat: Hashable, Sendable {
        public var song: Item
        public var date: Date
        public var plays: Int
    }

    public var period = Period.all
    /// Start of the period; for all time, the start of the day of the first listen.
    public var start: Date?
    public var now = Date()

    // Whole history
    public var firstListen: Date?
    public var firstSong: Item?
    public var currentStreak = 0
    public var longestStreak = 0
    /// Songs with several plays and none in the last 90 days.
    public var forgotten: [Item] = []
    /// Library songs never played to the end of the scrobble rule.
    public var neverPlayed = 0
    public var libraryCount = 0

    // The period
    public var listens = 0
    public var plays = 0
    public var listened: Double = 0
    /// Listening time in the same-length window just before the period; nil when there's no history that far back.
    public var previousListened: Double?
    /// Calendar days in the period, and the ones with at least one counted play.
    public var dayCount = 0
    public var activeDays = 0

    public var songs = Ranking()
    public var artists = Ranking()
    public var albums = Ranking()
    public var genres = Ranking()
    /// Album artists first heard during the period (empty for all time).
    public var newArtists = Ranking()
    /// Songs skipped at least twice, most skipped first.
    public var mostSkipped: [Item] = []

    public var activity: [ActivityPoint] = []
    public var granularity = Granularity.day
    /// Seconds listened by weekday (0 is the calendar's first weekday) and hour of the day.
    public var clock: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    /// Short weekday names in the same order as `clock`.
    public var weekdaySymbols: [String] = []
    public var eras: [EraShare] = []

    public var biggestDay: Day?
    public var longestSession: Session?
    public var onRepeat: Repeat?

    public var hasHistory: Bool { firstListen != nil }
    public var skipped: Int { listens - plays }
    public var skipRate: Double { listens == 0 ? 0 : Double(skipped) / Double(listens) }
    public var dailyAverage: Double { dayCount == 0 ? 0 : listened / Double(dayCount) }
    /// Share of the library played (counted) during the period.
    public var libraryPlayed: Double { libraryCount == 0 ? 0 : Double(songs.total) / Double(libraryCount) }
    public var hourTotals: [Double] { (0..<24).map { h in clock.reduce(0) { $0 + $1[h] } } }
    public var weekdayTotals: [Double] { clock.map { $0.reduce(0, +) } }
    public var peakHour: Int? { listened > 0 ? hourTotals.indices.max { hourTotals[$0] < hourTotals[$1] } : nil }
    public var peakWeekday: Int? { listened > 0 ? weekdayTotals.indices.max { weekdayTotals[$0] < weekdayTotals[$1] } : nil }

    public init() {}

    /// A listen starting within this long of the previous one ending continues the session.
    static let sessionGap: Double = 15 * 60
    static let forgottenAfter: Double = 90 * 86_400

    public init(plays history: [Play], tracks: [Track], period: Period, now: Date = Date(), calendar: Calendar = .current,
                listLimit: Int = 25) {
        self.period = period
        self.now = now
        libraryCount = tracks.count
        let first = calendar.firstWeekday
        weekdaySymbols = (0..<7).map { calendar.shortWeekdaySymbols[($0 + first - 1) % 7] }

        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let history = history.filter { byID[$0.trackId] != nil && $0.startedAt <= now }.sorted { $0.startedAt < $1.startedAt }
        guard let firstPlay = history.first else {
            neverPlayed = tracks.count
            return
        }
        firstListen = firstPlay.startedAt

        let today = calendar.startOfDay(for: now)
        let periodStart: Date
        if let days = period.days {
            periodStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            dayCount = days
            if let prevStart = calendar.date(byAdding: .day, value: -days, to: periodStart), firstPlay.startedAt < periodStart {
                previousListened = history.lazy.filter { $0.startedAt >= prevStart && $0.startedAt < periodStart }.reduce(0) { $0 + $1.listened }
            }
        } else {
            periodStart = calendar.startOfDay(for: firstPlay.startedAt)
            dayCount = (calendar.dateComponents([.day], from: periodStart, to: today).day ?? 0) + 1
        }
        start = periodStart

        // Whole history: streaks, first plays, forgotten favorites.
        var countedDays = Set<Date>()
        var firstHeard: [String: Date] = [:]
        var perTrack: [Int64: (plays: Int, last: Date)] = [:]
        for p in history {
            perTrack[p.trackId] = ((perTrack[p.trackId]?.plays ?? 0) + (p.counted ? 1 : 0), p.startedAt)
            guard p.counted else { continue }
            countedDays.insert(calendar.startOfDay(for: p.startedAt))
            let key = Self.artistName(byID[p.trackId]!).lowercased()
            if firstHeard[key] == nil { firstHeard[key] = p.startedAt }
        }
        firstSong = Self.songItem(byID[firstPlay.trackId]!)
        neverPlayed = tracks.count - perTrack.values.filter { $0.plays > 0 }.count
        (currentStreak, longestStreak) = Self.streaks(countedDays, today: today, calendar: calendar)
        forgotten = perTrack.filter { $0.value.plays >= 3 && now.timeIntervalSince($0.value.last) > Self.forgottenAfter }
            .map { id, v in
                var item = Self.songItem(byID[id]!)
                item.plays = v.plays; item.lastPlayed = v.last
                return item
            }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : ($0.lastPlayed ?? now) > ($1.lastPlayed ?? now) }
            .prefix(listLimit).map { $0 }

        // The period
        let inPeriod = history.filter { $0.startedAt >= periodStart }
        var songTally: [String: Item] = [:], artistTally: [String: Item] = [:], albumTally: [String: Item] = [:], genreTally: [String: Item] = [:]
        var decadeListened: [Int: Double] = [:]
        var days: [Date: Day] = [:]
        struct SongDay: Hashable { var id: Int64; var day: Date }
        var songDays: [SongDay: Int] = [:]
        var session: Session?, sessionEnd = Date.distantPast

        func tally(_ dict: inout [String: Item], _ key: String, _ make: @autoclosure () -> Item, _ p: Play) {
            var item = dict[key] ?? make()
            if p.counted { item.plays += 1 } else { item.skips += 1 }
            item.listened += p.listened
            item.lastPlayed = p.startedAt
            dict[key] = item
        }

        for p in inPeriod {
            let t = byID[p.trackId]!
            let m = t.metadata
            listens += 1
            listened += p.listened
            if p.counted { plays += 1 }

            tally(&songTally, "t\(t.id)", Self.songItem(t), p)
            let artist = Self.artistName(t)
            tally(&artistTally, "a:" + artist.lowercased(), Item(id: "a:" + artist.lowercased(), name: artist, subtitle: "", plays: 0, skips: 0, listened: 0), p)
            if !m.album.isEmpty {
                let key = "al:" + SearchIndex.albumKey(album: m.album, artist: t.effectiveAlbumArtist)
                tally(&albumTally, key, Item(id: key, name: m.album, subtitle: artist, plays: 0, skips: 0, listened: 0), p)
            }
            for g in SearchIndex.genres(of: m) {
                tally(&genreTally, "g:" + g.lowercased(), Item(id: "g:" + g.lowercased(), name: g, subtitle: "", plays: 0, skips: 0, listened: 0), p)
            }
            if let y = m.year, y > 0 { decadeListened[y / 10 * 10, default: 0] += p.listened }

            let day = calendar.startOfDay(for: p.startedAt)
            var d = days[day] ?? Day(date: day, listened: 0, plays: 0)
            d.listened += p.listened
            if p.counted { d.plays += 1; songDays[SongDay(id: t.id, day: day), default: 0] += 1 }
            days[day] = d

            let weekday = (calendar.component(.weekday, from: p.startedAt) - first + 7) % 7
            clock[weekday][calendar.component(.hour, from: p.startedAt)] += p.listened

            if var s = session, p.startedAt.timeIntervalSince(sessionEnd) <= Self.sessionGap {
                s.listened += p.listened; s.songs += 1
                session = s
            } else {
                if let s = session, s.listened > longestSession?.listened ?? 0 { longestSession = s }
                session = Session(start: p.startedAt, listened: p.listened, songs: 1)
            }
            sessionEnd = max(sessionEnd, p.startedAt.addingTimeInterval(p.listened))
        }
        if let s = session, s.listened > longestSession?.listened ?? 0 { longestSession = s }

        activeDays = days.values.filter { $0.plays > 0 }.count
        biggestDay = days.values.max { $0.listened != $1.listened ? $0.listened < $1.listened : $0.date > $1.date }
        // Ties go to the earliest day.
        if let best = songDays.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.day > $1.key.day }), best.value >= 2 {
            onRepeat = Repeat(song: songTally["t\(best.key.id)"]!, date: best.key.day, plays: best.value)
        }

        songs = Self.rank(songTally, limit: listLimit)
        artists = Self.rank(artistTally, limit: listLimit)
        albums = Self.rank(albumTally, limit: listLimit)
        genres = Self.rank(genreTally, limit: listLimit)
        mostSkipped = songTally.values.filter { $0.skips >= 2 }
            .sorted { $0.skips != $1.skips ? $0.skips > $1.skips : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(listLimit).map { $0 }
        if period != .all {
            newArtists = Self.rank(artistTally.filter { firstHeard[String($0.key.dropFirst(2))].map { $0 >= periodStart } ?? false }, limit: listLimit)
        }

        eras = Self.eras(listening: decadeListened, tracks: tracks)
        (activity, granularity) = Self.activity(inPeriod, from: periodStart, to: now, period: period, calendar: calendar)
    }

    // MARK: Helpers

    static func artistName(_ t: Track) -> String { t.effectiveAlbumArtist.isEmpty ? "Unknown Artist" : t.effectiveAlbumArtist }

    static func songItem(_ t: Track) -> Item {
        Item(id: "t\(t.id)", name: t.metadata.title.isEmpty ? "Untitled" : t.metadata.title, subtitle: t.metadata.artist,
             plays: 0, skips: 0, listened: 0, trackId: t.id)
    }

    static func rank(_ tally: [String: Item], limit: Int) -> Ranking {
        let name: (Item, Item) -> Bool = { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let counted = tally.values.filter { $0.plays > 0 }
        return Ranking(
            byPlays: Array(counted.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : ($0.listened != $1.listened ? $0.listened > $1.listened : name($0, $1)) }.prefix(limit)),
            byTime: Array(tally.values.sorted { $0.listened != $1.listened ? $0.listened > $1.listened : name($0, $1) }.prefix(limit)),
            total: counted.count)
    }

    /// The current run of days with plays (alive if it includes today or yesterday), and the longest run ever.
    static func streaks(_ days: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let sorted = days.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for d in sorted {
            if let p = previous, let next = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(next, inSameDayAs: d) { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = d
        }
        guard let last = sorted.last, let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              last >= yesterday else { return (0, longest) }
        return (run, longest)
    }

    static func eras(listening: [Int: Double], tracks: [Track]) -> [EraShare] {
        var library: [Int: Double] = [:]
        for t in tracks {
            guard let y = t.metadata.year, y > 0, t.duration.isFinite, t.duration > 0 else { continue }
            library[y / 10 * 10, default: 0] += t.duration
        }
        let totalListening = listening.values.reduce(0, +), totalLibrary = library.values.reduce(0, +)
        guard totalListening > 0, totalLibrary > 0 else { return [] }
        return Set(listening.keys).union(library.keys).sorted().map { d in
            EraShare(decade: d, listening: (listening[d] ?? 0) / totalListening, library: (library[d] ?? 0) / totalLibrary)
        }
    }

    /// Listening per day, week or month across the whole period, empty buckets included.
    static func activity(_ plays: [Play], from start: Date, to now: Date, period: Period,
                         calendar: Calendar) -> ([ActivityPoint], Granularity) {
        let granularity: Granularity
        switch period {
        case .week, .month: granularity = .day
        case .year: granularity = .week
        case .all:
            let span = now.timeIntervalSince(start)
            granularity = span <= 90 * 86_400 ? .day : (span <= 3 * 365 * 86_400 ? .week : .month)
        }
        let component: Calendar.Component = granularity == .day ? .day : (granularity == .week ? .weekOfYear : .month)
        func bucket(_ d: Date) -> Date { calendar.dateInterval(of: component, for: d)?.start ?? calendar.startOfDay(for: d) }
        var sums: [Date: ActivityPoint] = [:]
        for p in plays {
            let b = bucket(p.startedAt)
            var point = sums[b] ?? ActivityPoint(date: b, listened: 0, plays: 0)
            point.listened += p.listened
            if p.counted { point.plays += 1 }
            sums[b] = point
        }
        // A short history still gets a week's worth of days, so one day doesn't fill the whole chart.
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? start
        var points: [ActivityPoint] = []
        var d = bucket(granularity == .day ? min(start, weekAgo) : start)
        while d <= now, points.count < 10_000 {
            points.append(sums[d] ?? ActivityPoint(date: d, listened: 0, plays: 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: d) else { break }
            d = next
        }
        return (points, granularity)
    }
}
