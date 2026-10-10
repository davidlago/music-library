import Foundation

/// Aggregate figures about a library, computed in one pass. Everything is derived from the tracks, and list
/// sizes and bucket granularity adapt to the data, so it works the same for 10 songs or 100,000.
public struct LibraryStats: Sendable {
    public struct Count: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var count: Int
        public var duration: Double
        public init(name: String, count: Int, duration: Double = 0) { self.name = name; self.count = count; self.duration = duration }
    }

    public struct YearCount: Identifiable, Hashable, Sendable {
        public var id: Int { year }
        public var year: Int
        public var count: Int
    }

    public enum GrowthGranularity: String, Sendable { case day, week, month }

    public struct GrowthPoint: Identifiable, Hashable, Sendable {
        public var id: Date { date }
        public var date: Date
        public var added: Int
        public var total: Int
    }

    public struct LengthBucket: Identifiable, Hashable, Sendable {
        public var id: Int { lowerMinute }
        public var lowerMinute: Int
        /// nil for the open-ended last bucket.
        public var upperMinute: Int?
        public var count: Int
        public var label: String { upperMinute == nil ? "\(lowerMinute)+" : "\(lowerMinute)–\(upperMinute!)" }
        /// A search filter selecting the bucket's tracks.
        public var query: String { upperMinute.map { "time:>=\(lowerMinute)m time:<\($0)m" } ?? "time:>=\(lowerMinute)m" }
    }

    public enum QualityTier: String, CaseIterable, Identifiable, Sendable {
        case hiRes = "Hi-Res", cd = "CD Quality", lossyHigh = "Lossy ≥ 256k", lossy = "Lossy < 256k", unknown = "Unknown"
        public var id: String { rawValue }
        public var query: String? {
            switch self {
            case .hiRes: "is:hires"
            case .cd: "is:lossless -is:hires"
            case .lossyHigh: "is:lossy bitrate:>=256"
            case .lossy: "is:lossy -bitrate:>=256"
            case .unknown: nil
            }
        }
    }

    public struct TierCount: Identifiable, Hashable, Sendable {
        public var id: QualityTier { tier }
        public var tier: QualityTier
        public var count: Int
    }

    public struct TrackRef: Hashable, Sendable {
        public var id: Int64
        public var title: String
        public var artist: String
        public var duration: Double
    }

    public struct AlbumRef: Hashable, Sendable {
        public var album: String
        public var artist: String
        public var year: Int?
        public var trackCount: Int
        public var duration: Double
    }

    public struct Person: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var roles: [String]
        public var trackCount: Int
    }

    public struct Coverage: Identifiable, Hashable, Sendable {
        public var id: SearchQuery.PresenceField { field }
        public var field: SearchQuery.PresenceField
        public var label: String
        public var present: Int
    }

    public var trackCount = 0
    public var albumCount = 0
    public var artistCount = 0
    public var totalDuration: Double = 0
    public var totalBytes: Int64 = 0
    public var bytesAreEstimated = false

    public var years: [YearCount] = []
    public var decades: [YearCount] = []
    public var medianYear: Int?
    public var busiestYear: YearCount?

    /// Sorted by track count; a track with several genres counts toward each.
    public var genres: [Count] = []
    public var artistsByTracks: [Count] = []
    public var artistsByDuration: [Count] = []
    /// Album artists by number of albums.
    public var artistsByAlbums: [Count] = []
    public var labels: [Count] = []
    public var countries: [Count] = []
    public var people: [Person] = []
    public var titleWords: [Count] = []

    public var codecs: [Count] = []
    public var sampleRates: [Count] = []
    public var bitDepths: [Count] = []
    public var qualityTiers: [TierCount] = []
    public var losslessCount = 0

    public var lengthBuckets: [LengthBucket] = []
    public var growth: [GrowthPoint] = []
    public var growthGranularity = GrowthGranularity.day
    public var firstAdded: Date?
    public var lastAdded: Date?
    public var addedLast30Days = 0

    public var longestTrack: TrackRef?
    public var shortestTrack: TrackRef?
    public var longestAlbum: AlbumRef?
    public var oldestAlbum: AlbumRef?
    public var newestAlbum: AlbumRef?
    public var coverage: [Coverage] = []

    public var averageTrackLength: Double { trackCount == 0 ? 0 : totalDuration / Double(trackCount) }

    public init() {}

    public init(tracks: [Track], now: Date = Date(), calendar: Calendar = .current, listLimit: Int = 25,
                hasCover: (Track) -> Bool = { _ in false }, fileSize: (Track) -> Int64? = { _ in nil }) {
        trackCount = tracks.count
        guard !tracks.isEmpty else { return }

        var albums: [String: AlbumRef] = [:]
        var albumsMinYear: [String: Int] = [:]
        var artistTracks: [String: Count] = [:]
        var artistAlbums: [String: Set<String>] = [:]
        var genreCounts: [String: Count] = [:]
        var labelCounts: [String: Count] = [:]
        var countryCounts: [String: Count] = [:]
        var codecCounts: [String: Count] = [:]
        var rateCounts: [Int: Int] = [:]
        var depthCounts: [Int: Int] = [:]
        var tierCounts: [QualityTier: Int] = [:]
        var yearCounts: [Int: Int] = [:]
        var wordCounts: [String: Count] = [:]
        var peopleTracks: [String: (name: String, tracks: Set<Int64>, roles: [String: Int])] = [:]
        var present: [SearchQuery.PresenceField: Int] = [:]
        var anyEstimated = false

        func tally(_ dict: inout [String: Count], _ name: String, _ duration: Double) {
            let key = name.lowercased()
            if dict[key] == nil { dict[key] = Count(name: name, count: 0) }
            dict[key]!.count += 1
            dict[key]!.duration += duration
        }

        for t in tracks {
            let m = t.metadata, x = m.extended
            let d = t.duration.isFinite ? max(0, t.duration) : 0
            totalDuration += d

            if let size = fileSize(t) {
                totalBytes += size
            } else if let est = Self.estimatedBytes(t) {
                totalBytes += est
                anyEstimated = true
            }

            let aa = t.effectiveAlbumArtist.isEmpty ? "Unknown Artist" : t.effectiveAlbumArtist
            let albumKey = SearchIndex.albumKey(album: m.album, artist: t.effectiveAlbumArtist)
            var a = albums[albumKey] ?? AlbumRef(album: m.album.isEmpty ? "Unknown Album" : m.album, artist: aa, year: nil, trackCount: 0, duration: 0)
            a.trackCount += 1
            a.duration += d
            if let y = m.year, y > 0 {
                a.year = max(a.year ?? y, y)
                albumsMinYear[albumKey] = min(albumsMinYear[albumKey] ?? y, y)
                yearCounts[y, default: 0] += 1
            }
            albums[albumKey] = a
            tally(&artistTracks, aa, d)
            artistAlbums[aa.lowercased(), default: []].insert(m.album.lowercased())

            for g in SearchIndex.genres(of: m) { tally(&genreCounts, g, d) }
            if !x.label.isEmpty { tally(&labelCounts, x.label, d) }
            if !x.releaseCountry.isEmpty { tally(&countryCounts, x.releaseCountry, d) }

            tally(&codecCounts, t.audioFormat?.codecLabel ?? (t.format.isEmpty ? "Unknown" : t.format.uppercased()), d)
            if let r = t.audioFormat?.sampleRate { rateCounts[r, default: 0] += 1 }
            if let b = t.audioFormat?.bitDepth { depthCounts[b, default: 0] += 1 }
            tierCounts[Self.tier(t), default: 0] += 1
            if t.isLossless == true { losslessCount += 1 }

            for w in Set(TextNormalizer.normalize(m.title).split(separator: " ").map(String.init))
            where w.count >= 3 && !Self.stopWords.contains(w) && Int(w) == nil {
                tally(&wordCounts, w, d)
            }

            for c in x.credits {
                let key = c.name.lowercased()
                var p = peopleTracks[key] ?? (c.name, [], [:])
                p.tracks.insert(t.id)
                for role in CreditFormatter.label(c) { p.roles[role, default: 0] += 1 }
                peopleTracks[key] = p
            }

            if (m.year ?? 0) > 0 { present[.year, default: 0] += 1 }
            if !SearchIndex.genres(of: m).isEmpty { present[.genre, default: 0] += 1 }
            if !(m.mbRecordingId ?? "").isEmpty { present[.mbid, default: 0] += 1 }
            if !m.composer.isEmpty || !x.writer.isEmpty || !x.lyricist.isEmpty { present[.composer, default: 0] += 1 }
            if !x.label.isEmpty { present[.label, default: 0] += 1 }
            if !x.credits.isEmpty || !x.performers.isEmpty { present[.credits, default: 0] += 1 }
            if hasCover(t) { present[.cover, default: 0] += 1 }

            if longestTrack == nil || d > longestTrack!.duration { longestTrack = TrackRef(id: t.id, title: m.title, artist: m.artist, duration: d) }
            if d > 0, shortestTrack == nil || d < shortestTrack!.duration { shortestTrack = TrackRef(id: t.id, title: m.title, artist: m.artist, duration: d) }
        }

        bytesAreEstimated = anyEstimated
        albumCount = albums.count
        artistCount = artistTracks.count

        let byCount: (Count, Count) -> Bool = { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        genres = genreCounts.values.sorted(by: byCount)
        artistsByTracks = Array(artistTracks.values.sorted(by: byCount).prefix(listLimit))
        artistsByDuration = Array(artistTracks.values.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.name < $1.name }.prefix(listLimit))
        artistsByAlbums = Array(artistTracks.values.map { c in
            Count(name: c.name, count: artistAlbums[c.name.lowercased()]?.count ?? 0, duration: c.duration)
        }.sorted(by: byCount).prefix(listLimit))
        labels = Array(labelCounts.values.sorted(by: byCount).prefix(listLimit))
        countries = Array(countryCounts.values.sorted(by: byCount).prefix(listLimit))
        codecs = codecCounts.values.sorted(by: byCount)
        sampleRates = rateCounts.sorted { $0.key < $1.key }.map { Count(name: "\(AudioFormat.kHzString(Double($0.key))) kHz", count: $0.value) }
        bitDepths = depthCounts.sorted { $0.key < $1.key }.map { Count(name: "\($0.key)-bit", count: $0.value) }
        qualityTiers = QualityTier.allCases.compactMap { tier in tierCounts[tier].map { TierCount(tier: tier, count: $0) } }
        // A word only counts as a theme when it recurs.
        titleWords = Array(wordCounts.values.filter { $0.count >= 2 }.sorted(by: byCount).prefix(listLimit))
        people = peopleTracks.values.map { p in
            Person(name: p.name, roles: p.roles.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key),
                   trackCount: p.tracks.count)
        }
        .sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
        .prefix(listLimit).map { $0 }

        // Years and decades
        years = yearCounts.sorted { $0.key < $1.key }.map { YearCount(year: $0.key, count: $0.value) }
        var decadeCounts: [Int: Int] = [:]
        for y in years { decadeCounts[y.year / 10 * 10, default: 0] += y.count }
        decades = decadeCounts.sorted { $0.key < $1.key }.map { YearCount(year: $0.key, count: $0.value) }
        busiestYear = years.max { $0.count != $1.count ? $0.count < $1.count : $0.year > $1.year }
        let dated = years.reduce(0) { $0 + $1.count }
        if dated > 0 {
            var seen = 0
            for y in years {
                seen += y.count
                if seen * 2 >= dated { medianYear = y.year; break }
            }
        }

        // Albums
        let albumList = albums.map { (key: $0.key, ref: $0.value) }
        longestAlbum = albumList.max { $0.ref.duration < $1.ref.duration }?.ref
        if let oldest = albumList.filter({ albumsMinYear[$0.key] != nil }).min(by: { albumsMinYear[$0.key]! < albumsMinYear[$1.key]! }) {
            var ref = oldest.ref
            ref.year = albumsMinYear[oldest.key]
            oldestAlbum = ref
        }
        newestAlbum = albumList.filter { $0.ref.year != nil }.max { $0.ref.year! < $1.ref.year! }?.ref

        // Length histogram: one-minute buckets up to (roughly) the 95th percentile, which opens the last bucket.
        let minutes = tracks.map { Int(max(0, $0.duration) / 60) }.sorted()
        let p95 = minutes[min(minutes.count - 1, Int(Double(minutes.count) * 0.95))]
        let cap = min(max(p95, 5), 20)
        var lengthCounts = [Int](repeating: 0, count: cap + 1)
        for m in minutes { lengthCounts[min(m, cap)] += 1 }
        lengthBuckets = (0...cap).map { i in
            LengthBucket(lowerMinute: i, upperMinute: i == cap ? nil : i + 1, count: lengthCounts[i])
        }

        // Growth over time, bucketed by a granularity that suits the span.
        let addDates = tracks.map(\.addedAt).sorted()
        firstAdded = addDates.first
        lastAdded = addDates.last
        addedLast30Days = addDates.filter { now.timeIntervalSince($0) <= 30 * 86_400 }.count
        if let first = firstAdded, let last = lastAdded {
            let span = last.timeIntervalSince(first)
            growthGranularity = span <= 90 * 86_400 ? .day : (span <= 3 * 365 * 86_400 ? .week : .month)
            let component: Calendar.Component = growthGranularity == .day ? .day : (growthGranularity == .week ? .weekOfYear : .month)
            var buckets: [Date: Int] = [:]
            for d in addDates {
                let start = calendar.dateInterval(of: component, for: d)?.start ?? d
                buckets[start, default: 0] += 1
            }
            var total = 0
            growth = buckets.sorted { $0.key < $1.key }.map { date, n in
                total += n
                return GrowthPoint(date: date, added: n, total: total)
            }
        }

        coverage = [
            (SearchQuery.PresenceField.cover, "Cover art"), (.year, "Release year"), (.genre, "Genre"),
            (.mbid, "MusicBrainz match"), (.composer, "Composer"), (.label, "Label"), (.credits, "Credits"),
        ].map { Coverage(field: $0.0, label: $0.1, present: present[$0.0] ?? 0) }
    }

    public static func tier(_ t: Track) -> QualityTier {
        switch t.isLossless {
        case true?: return t.isHiRes ? .hiRes : .cd
        case false?:
            guard let br = t.audioFormat?.bitrate else { return .lossy }
            return br >= 256_000 ? .lossyHigh : .lossy
        case nil: return .unknown
        }
    }

    static func estimatedBytes(_ t: Track) -> Int64? {
        guard t.duration.isFinite, t.duration > 0 else { return nil }
        if let br = t.audioFormat?.bitrate, br > 0 { return Int64(Double(br) * t.duration / 8) }
        if let f = t.audioFormat, let rate = f.sampleRate, let bits = f.bitDepth {
            // Lossless compression typically lands near 60% of PCM.
            let pcm = Double(rate * bits * (f.channels ?? 2)) * t.duration / 8
            return Int64(t.isLossless == true && f.codec.lowercased().hasPrefix("pcm") == false ? pcm * 0.6 : pcm)
        }
        return nil
    }

    /// The first `top` items, with the remainder folded into one "Other" item.
    public static func folded(_ items: [Count], top: Int, otherName: String = "Other") -> [Count] {
        guard items.count > top + 1 else { return items }
        let rest = items.dropFirst(top)
        return Array(items.prefix(top)) + [Count(name: otherName, count: rest.reduce(0) { $0 + $1.count },
                                                  duration: rest.reduce(0) { $0 + $1.duration })]
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "from", "that", "this", "are", "was", "but", "not", "all", "out",
        "one", "into", "what", "when", "who", "how", "its", "it", "our", "his", "her", "him", "she", "they", "them",
        "del", "der", "die", "das", "des", "les", "los", "las", "une", "con", "por", "para",
        "feat", "featuring", "remaster", "remastered", "version", "mix", "edit", "live", "mono", "stereo", "take",
        "part", "pt", "bonus", "track", "demo", "instrumental", "remix", "original", "alternate", "single",
    ]
}
