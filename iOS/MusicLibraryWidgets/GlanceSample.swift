import Foundation
import MusicLibraryGlance

/// What the widget gallery and placeholders show before there's a real summary.
extension Glance {
    static let sample: Glance = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func album(_ title: String, _ artist: String, _ year: Int) -> Album {
            Album(key: "\(artist.lowercased())\u{1}\(title.lowercased())", title: title, artist: artist, year: year, playable: true)
        }
        func song(_ id: Int64, _ title: String, _ a: Album) -> Song {
            Song(id: id, title: title, artist: a.artist, album: a.title, albumKey: a.key, playable: true)
        }
        let kindOfBlue = album("Kind of Blue", "Miles Davis", 1959)
        let okComputer = album("OK Computer", "Radiohead", 1997)
        let blue = album("Blue", "Joni Mitchell", 1971)
        let rumours = album("Rumours", "Fleetwood Mac", 1977)
        let moanin = album("Moanin'", "Art Blakey & The Jazz Messengers", 1958)
        let inRainbows = album("In Rainbows", "Radiohead", 2007)

        func listening(days: Int, scale: Double) -> Listening {
            var l = Listening(days: days)
            let pattern: [Double] = [0.6, 1.4, 0.3, 2.1, 1.2, 0, 1.8, 0.9, 1.1, 0.4]
            l.daily = (0..<days).map { i in
                let date = calendar.date(byAdding: .day, value: i - days + 1, to: today) ?? today
                let hours = pattern[i % pattern.count] * scale
                return Listening.Day(date: date, listened: hours * 3600, plays: Int(hours * 15))
            }
            l.listened = l.daily.reduce(0) { $0 + $1.listened }
            l.plays = l.daily.reduce(0) { $0 + $1.plays }
            l.previousListened = l.listened / 1.18
            l.activeDays = l.daily.filter { $0.listened > 0 }.count
            l.currentStreak = 4
            l.longestStreak = 23
            l.peakHour = 21
            l.topArtists = [Ranked("Radiohead", plays: 34, listened: 9200), Ranked("Miles Davis", plays: 21, listened: 8100),
                            Ranked("Joni Mitchell", plays: 15, listened: 3900)]
            l.topSongs = [Ranked(song(1, "Reckoner", inRainbows), plays: 9, listened: 2600),
                          Ranked(song(2, "So What", kindOfBlue), plays: 7, listened: 3900),
                          Ranked(song(3, "A Case of You", blue), plays: 6, listened: 1600)]
            l.topAlbums = [Ranked(inRainbows, plays: 22, listened: 5600), Ranked(kindOfBlue, plays: 21, listened: 8100),
                           Ranked(blue, plays: 15, listened: 3900), Ranked(okComputer, plays: 12, listened: 3300)]
            return l
        }

        let purchases: [Owned.Purchase] = [
            Owned.Purchase(album: inRainbows, purchasedOn: Self.day(calendar.date(byAdding: .day, value: -3, to: today)), price: 24.99, plays: 22),
            Owned.Purchase(album: moanin, purchasedOn: Self.day(calendar.date(byAdding: .day, value: -19, to: today)), price: 18, plays: 6),
            Owned.Purchase(album: blue, purchasedOn: Self.day(calendar.date(byAdding: .day, value: -52, to: today)), price: 12.5, plays: 31),
            Owned.Purchase(album: rumours, purchasedOn: Self.day(calendar.date(byAdding: .day, value: -97, to: today)), price: 9.99, plays: 14),
            Owned.Purchase(album: kindOfBlue, purchasedOn: "2019-05-04", price: 15, plays: 88),
        ]

        return Glance(
            generatedAt: Date(), currencyCode: Locale.current.currency?.identifier ?? "USD",
            library: LibraryCounts(songs: 8_412, albums: 694, artists: 312, duration: 2_041_000, songsOnPhone: 1_380,
                                   albumsOnPhone: 112, likedSongs: 268, recentlyAdded: [inRainbows, moanin, blue, rumours]),
            week: listening(days: 7, scale: 1), month: listening(days: 30, scale: 0.9),
            owned: Owned(ownedCount: 214, libraryAlbumCount: 694, boughtThisYear: 17, spentThisYear: 286.45, totalSpent: 3_120,
                         recent: purchases),
            nowPlaying: NowPlaying(song: song(1, "Reckoner", inRainbows), isPlaying: true, position: 95, duration: 290,
                                   updatedAt: Date(), liked: true, next: song(4, "House of Cards", inRainbows)),
            rediscover: [Ranked(song(5, "Blues March", moanin), plays: 41, listened: 0,
                                lastPlayed: calendar.date(byAdding: .month, value: -7, to: today)),
                         Ranked(song(6, "Dreams", rumours), plays: 23, listened: 0,
                                lastPlayed: calendar.date(byAdding: .month, value: -5, to: today))])
    }()

    private static func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }
}
