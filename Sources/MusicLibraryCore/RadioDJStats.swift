import Foundation

/// The DJ's look at the listener's numbers: the `collection_stats` tool, the same figures as the Insights panes
/// (Digital Collection: `LibraryStats`; Listening: `ListeningStats`; Owned: `CollectionStats`), computed on the device
/// when asked and sent as short lines of text.
extension RadioDJLibrary {
    public static let statsToolName = "collection_stats"

    public enum StatsSection: String, CaseIterable, Sendable { case library, listening, owned }

    static let periods: [String: ListeningStats.Period] = ["7d": .week, "30d": .month, "12m": .year, "all": .all]

    public static var statsTool: JSONValue {
        let description = """
        The listener's collection statistics, as the app's Insights pages show them. section "library": their digital \
        collection (how many songs, albums and artists, total running time, formats and audio quality, decades, \
        genres, top artists by songs and by time, record labels, people credited, longest and shortest). section \
        "listening": what they've played in a period (period 7d, 30d, 12m or all; totals and time listened, top songs, \
        artists, albums and genres, what's new to them, streaks, when they listen, skips, the period before for \
        comparison). section "owned": the CDs, records and downloads they own (counts, how much is digitized, label \
        series, spending, cost per play, top artists, genres, decades and record labels, recent purchases). For one \
        artist, album or song, use search_collection instead (it gives running times too).
        """
        let properties: [String: JSONValue] = [
            "section": .object(["type": .string("string"), "enum": .array(StatsSection.allCases.map { .string($0.rawValue) })]),
            "period": .object(["type": .string("string"), "enum": .array(["7d", "30d", "12m", "all"].map(JSONValue.string)),
                               "description": .string("For listening; default 30d.")]),
        ]
        return .object([
            "name": .string(statsToolName),
            "description": .string(description),
            "input_schema": .object(["type": .string("object"), "properties": .object(properties),
                                     "required": .array([.string("section")]), "additionalProperties": .bool(false)]),
            "eager_input_streaming": .bool(true),
        ])
    }

    /// Runs one `collection_stats` call.
    public func runStats(_ input: JSONValue, now: Date = Date()) -> (text: String, isError: Bool) {
        guard let section = input["section"]?.string.flatMap(StatsSection.init(rawValue:)) else {
            return ("Invalid input: section must be library, listening or owned.", true)
        }
        let periodKey = input["period"]?.string ?? "30d"
        guard let period = Self.periods[periodKey] else { return ("Invalid input: period must be 7d, 30d, 12m or all.", true) }
        switch section {
        case .library: return (librarySummary(now: now), false)
        case .listening: return (listeningSummary(period, now: now), false)
        case .owned: return (ownedSummary(now: now), false)
        }
    }

    // MARK: Sections

    func librarySummary(now: Date) -> String {
        let s = LibraryStats(tracks: index.tracks, now: now, listLimit: 10)
        guard s.trackCount > 0 else { return "The digital collection is empty." }
        var out = ["Digital collection: \(s.trackCount) songs, \(s.albumCount) albums, \(s.artistCount) artists, \(Self.time(s.totalDuration)) of music (songs average \(Self.time(s.averageTrackLength)))."]
        out.append("Lossless: \(s.losslessCount) of \(s.trackCount) songs. Quality: " + s.qualityTiers.map { "\($0.tier.rawValue) \($0.count)" }.joined(separator: ", ") + ".")
        out.append("Formats: " + Self.counts(s.codecs) + ". Sample rates: " + Self.counts(s.sampleRates) + ".")
        if let median = s.medianYear { out.append("Median release year \(median)" + (s.busiestYear.map { "; busiest year \($0.year) (\($0.count) songs)" } ?? "") + ".") }
        out.append("Decades: " + s.decades.map { "\($0.year)s \($0.count)" }.joined(separator: ", ") + ".")
        out.append("Top genres (songs, time): " + Self.counts(s.genres, time: true) + ".")
        out.append("Top artists by songs: " + Self.counts(s.artistsByTracks, time: true) + ".")
        out.append("Top artists by time: " + s.artistsByDuration.map { "\($0.name) \(Self.time($0.duration))" }.joined(separator: ", ") + ".")
        out.append("Artists with the most albums: " + Self.counts(s.artistsByAlbums) + ".")
        if !s.labels.isEmpty { out.append("Record labels: " + Self.counts(s.labels) + ".") }
        if !s.people.isEmpty { out.append("Most credited people: " + s.people.prefix(10).map { "\($0.name) (\($0.roles.prefix(2).joined(separator: ", ")); \($0.trackCount) songs)" }.joined(separator: ", ") + ".") }
        if let t = s.longestTrack { out.append("Longest song: “\(t.title)” by \(t.artist), \(Self.time(t.duration)).") }
        if let t = s.shortestTrack { out.append("Shortest song: “\(t.title)” by \(t.artist), \(Self.time(t.duration)).") }
        if let a = s.longestAlbum { out.append("Longest album: *\(a.album)* by \(a.artist), \(Self.time(a.duration)).") }
        if let a = s.oldestAlbum { out.append("Oldest album: *\(a.album)* by \(a.artist)\(a.year.map { " (\($0))" } ?? "").") }
        if let a = s.newestAlbum { out.append("Newest album: *\(a.album)* by \(a.artist)\(a.year.map { " (\($0))" } ?? "").") }
        if let first = s.firstAdded { out.append("Collecting since \(PurchaseDay(first).string); \(s.addedLast30Days) songs added in the last 30 days.") }
        return out.joined(separator: "\n")
    }

    func listeningSummary(_ period: ListeningStats.Period, now: Date) -> String {
        let s = ListeningStats(plays: plays, tracks: index.tracks, period: period, now: now, listLimit: 10)
        let name = period.rawValue.lowercased()
        guard s.hasHistory, s.listens > 0 else { return "No listening recorded in the last \(name)." + (s.hasHistory ? "" : " (No listening history at all yet.)") }
        var out = ["Listening, \(period == .all ? "all time" : "last \(name)"): \(s.plays) plays (\(s.listens) listens, \(s.skipped) skipped), \(Self.time(s.listened)) listened, on \(s.activeDays) days; \(s.songs.total) songs, \(s.artists.total) artists, \(s.albums.total) albums."]
        if let previous = s.previous { out.append("The \(name) before: \(previous.plays) plays, \(Self.time(previous.listened)).") }
        out.append("Daily average \(Self.time(s.dailyAverage)); current streak \(s.currentStreak) days, longest \(s.longestStreak).")
        if let hour = s.peakHour { out.append("Listens most around \(hour):00" + (s.peakWeekday.map { " and on \(s.weekdaySymbols[$0])s" } ?? "") + ".") }
        out.append("Top songs: " + Self.items(s.songs.byPlays) + ".")
        out.append("Top artists: " + Self.items(s.artists.byPlays) + ".")
        out.append("Top albums: " + Self.items(s.albums.byPlays) + ".")
        if !s.genres.byPlays.isEmpty { out.append("Top genres: " + Self.items(s.genres.byPlays) + ".") }
        if !s.newArtists.byPlays.isEmpty { out.append("New to them this period, artists: " + Self.items(Array(s.newArtists.byPlays.prefix(5))) + ".") }
        if !s.newAlbums.byPlays.isEmpty { out.append("New albums: " + Self.items(Array(s.newAlbums.byPlays.prefix(5))) + ".") }
        if !s.mostSkipped.isEmpty { out.append("Most skipped: " + s.mostSkipped.prefix(5).map { "\($0.name) (\($0.skips))" }.joined(separator: ", ") + ".") }
        if let day = s.biggestDay { out.append("Biggest day: \(PurchaseDay(day.date).string), \(Self.time(day.listened)).") }
        if let r = s.onRepeat { out.append("On repeat: \(r.song.name), \(r.plays) plays on \(PurchaseDay(r.date).string).") }
        if !s.eras.isEmpty { out.append("Listening by decade vs the library: " + s.eras.map { "\($0.decade)s \(Int(($0.listening * 100).rounded()))% vs \(Int(($0.library * 100).rounded()))%" }.joined(separator: ", ") + ".") }
        out.append("Never played: \(s.neverPlayed) of \(s.libraryCount) songs.")
        if !s.forgotten.isEmpty { out.append("Forgotten favorites: " + s.forgotten.prefix(5).map(\.name).joined(separator: ", ") + ".") }
        if let first = s.firstListen { out.append("First listen recorded \(PurchaseDay(first).string).") }
        return out.joined(separator: "\n")
    }

    func ownedSummary(now: Date) -> String {
        let s = CollectionStats(collection: collection, tracks: index.tracks, playTotals: playTotals, albumInfos: albumInfos, now: now, listLimit: 10)
        guard s.itemCount > 0 else { return "They haven't added anything to their physical collection yet." }
        var out = ["Owned: \(s.itemCount) copies (\(s.cdCount) CDs, \(s.vinylCount) records, \(s.downloadCount) downloads), \(s.albumsOwned) albums; \(s.notInCollection) albums in the digital collection aren't owned. \(Int((s.digitizedShare * 100).rounded()))% digitized; \(s.toRipCount) CDs to rip, \(s.vinylToDigitizeCount) records to digitize."]
        if s.runtime > 0 { out.append("Running time of what they own (with tracks): \(Self.time(s.runtime)) over \(s.runtimeAlbums) albums.") }
        for medium in s.media where medium.items > 0 {
            out.append("\(medium.medium.rawValue): \(medium.items) (\(medium.digitized) digitized, \(medium.toDigitize) to digitize), spent \(money(medium.spent)) on \(medium.priced) with a price.")
        }
        for series in s.series where series.labeled > 0 {
            out.append("\(series.series.name) labels: \(series.labeled) labeled, highest #\(series.highest ?? 0), next free #\(series.next), \(series.gapCount) gaps, \(series.duplicates.count) duplicate numbers.")
        }
        if s.pricedCount > 0 {
            out.append("Spent \(money(s.totalSpent)) on \(s.pricedCount) priced copies; \(money(s.spentThisYear)) on \(s.boughtThisYear) this year; average \(s.averagePrice.map(money) ?? "—"), median \(s.medianPrice.map(money) ?? "—").")
            if let p = s.priciest { out.append("Priciest: *\(p.item.album)* by \(p.item.artist), \(p.item.price.map(money) ?? "")." ) }
            if let c = s.cheapest { out.append("Cheapest: *\(c.item.album)* by \(c.item.artist), \(c.item.price.map(money) ?? "").") }
            if let perPlay = s.costPerPlay { out.append("Cost per play \(money(perPlay))" + (s.costPerHour.map { ", per hour listened \(money($0))" } ?? "") + ".") }
        }
        if !s.artists.isEmpty { out.append("Most-owned artists: " + s.artists.prefix(10).map { "\($0.name) \($0.items)" }.joined(separator: ", ") + ".") }
        if !s.genres.isEmpty { out.append("Genres owned: " + s.genres.prefix(8).map { "\($0.name) \($0.items)" }.joined(separator: ", ") + ".") }
        if !s.decades.isEmpty { out.append("Decades owned: " + s.decades.map { "\($0.name) \($0.items)" }.joined(separator: ", ") + ".") }
        if !s.recordLabels.isEmpty { out.append("Record labels owned: " + s.recordLabels.prefix(8).map { "\($0.name) \($0.items)" }.joined(separator: ", ") + ".") }
        if !s.recentlyAdded.isEmpty { out.append("Recently added: " + s.recentlyAdded.prefix(5).map { "*\($0.item.album)* by \($0.item.artist)" }.joined(separator: ", ") + ".") }
        if !s.bestValue.isEmpty { out.append("Best value (cost per play): " + s.bestValue.prefix(5).map { "*\($0.item.album)* \($0.pricePerPlay.map(money) ?? "")" }.joined(separator: ", ") + ".") }
        if !s.stillInWrapper.isEmpty { out.append("Bought but never played: " + s.stillInWrapper.prefix(5).map { "*\($0.item.album)* by \($0.item.artist)" }.joined(separator: ", ") + ".") }
        if let oldest = s.oldestRelease { out.append("Oldest release owned: *\(oldest.album)* by \(oldest.artist)\(oldest.year.map { " (\($0))" } ?? "").") }
        if let most = s.mostCopies { out.append("Most copies of one album: *\(most.item.album)* by \(most.item.artist), \(most.copies).") }
        return out.joined(separator: "\n")
    }

    // MARK: Formatting

    private func money(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: currencyCode).precision(.fractionLength(2)))
    }

    private static func counts(_ items: [LibraryStats.Count], time: Bool = false) -> String {
        items.prefix(10).map { "\($0.name) \($0.count)" + (time && $0.duration > 0 ? " (\(Self.time($0.duration)))" : "") }.joined(separator: ", ")
    }

    private static func items(_ items: [ListeningStats.Item]) -> String {
        items.prefix(10).map { "\($0.name)\($0.subtitle.isEmpty ? "" : " — \($0.subtitle)") (\($0.plays) plays, \(Self.time($0.listened)))" }.joined(separator: "; ")
    }

    /// "38 min", "2 hr 5 min", "3 days 4 hr".
    static func time(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 48 { return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min" }
        return "\(hours / 24) days \(hours % 24) hr"
    }
}
