// Makes the iPhone app's sample library (`scripts/make-sample-library.sh`): original songs synthesized here, covers
// and artist pictures drawn here, imported with the app's own `ImportService`, plus a listening history, likes, a
// collection (labeled CDs and records, some never ripped, and a download), playlists and artist and album info. Every
// artist, album and song is fictional.
//
//     swift run -c release SampleLibraryMaker <output folder>
#if os(macOS)
import Foundation
import MusicLibraryCore

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: SampleLibraryMaker <output folder>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fm = FileManager.default
if fm.fileExists(atPath: root.path) {
    FileHandle.standardError.write(Data("\(root.path) already exists\n".utf8))
    exit(1)
}
let scratch = fm.temporaryDirectory.appendingPathComponent("sample-library-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

// Whole hours, so the history's times of day stay round.
let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600)
let day: TimeInterval = 86_400
let calendar = Calendar(identifier: .gregorian)
let tools = ToolLocator()
let ffmpeg = try tools.require("ffmpeg")

func log(_ s: String) { print(s) }

// MARK: Songs

var tracksByAlbum: [String: [Track]] = [:]
var collection: [CollectionItem] = []

/// A collection item for an owned copy, added to the collection when it was bought (or when the album joined the
/// library, for one bought on a day not recorded).
func collectionItem(_ copy: SampleCatalog.Copy, title: String, artist: String, year: Int, label: String,
                    trackCount: Int, addedDaysAgo: Int?) -> CollectionItem {
    let bought = copy.daysAgo.map { now.addingTimeInterval(-Double($0) * day) }
    let added = bought ?? addedDaysAgo.map { now.addingTimeInterval(-Double($0) * day) } ?? now
    var item = CollectionItem(medium: copy.medium, album: title, artist: artist, now: added)
    item.stickerNumber = copy.sticker
    item.year = year
    item.recordLabel = label
    item.catalogNumber = copy.catalogNumber
    item.country = SampleCatalog.artists.first { $0.name == artist }?.country
    item.formatDetail = copy.formatDetail
    item.discCount = copy.medium == .download ? nil : 1
    item.trackCount = trackCount
    item.purchasedOn = bought.map { PurchaseDay($0, calendar: calendar) }
    item.price = copy.price.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    return item
}

do {
    let db = try LibraryLocation.openDatabase(root: root)
    let importer = ImportService(root: root, database: db, tools: tools)

    for album in SampleCatalog.albums {
        log("\(album.artist) – \(album.title)")
        var imported: [Track] = []
        let added = now.addingTimeInterval(-Double(album.addedDaysAgo) * day + 3600 * 20)
        for (i, song) in album.tracks.enumerated() {
            var synth = SongSynth(style: album.style, seed: "\(album.title)/\(song.title)")
            let wav = scratch.appendingPathComponent("\(i).wav")
            try SongSynth.wav(synth.render()).write(to: wav)
            let ext = album.lossless ? "flac" : "m4a"
            let encoded = scratch.appendingPathComponent("\(i).\(ext)")
            let codec = album.lossless ? ["-c:a", "flac", "-compression_level", "8"] : ["-c:a", "aac", "-b:a", "80k"]
            _ = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", wav.path] + codec + [encoded.path])

            var extended = ExtendedMetadata()
            extended.label = album.label
            extended.releaseType = album.type
            extended.releaseStatus = "Official"
            extended.releaseCountry = SampleCatalog.artists.first { $0.name == album.artist }?.country ?? ""
            extended.releaseDate = String(format: "%04d-%02d-%02d", album.year, album.month, 1 + (album.title.count * 7) % 27)
            // The release the files came from: the CD or record they were ripped from, when you own one.
            extended.mediaFormat = album.owned == nil || album.medium == .download ? "Digital Media"
                : album.medium == .vinyl ? "12\" Vinyl" : "CD"
            extended.producer = album.producer
            extended.mixer = album.mixer
            extended.credits = (album.personnel + song.extra).map { Credit(role: $0.0, name: $0.1, scope: .recording) }
            let metadata = TrackMetadata(
                title: song.title,
                artist: song.featuring.map { "\(album.artist) feat. \($0)" } ?? album.artist,
                album: album.title, albumArtist: album.artist, year: album.year,
                trackNo: i + 1, trackTotal: album.tracks.count, discNo: 1, discTotal: 1, genre: album.genre,
                composer: album.composers.joined(separator: "; "), extended: extended)
            let item = try await importer.prepare(encoded)
            var track = try await importer.commit(item, metadata: metadata, cover: nil)
            track.addedAt = added.addingTimeInterval(Double(i) * 2)
            try db.updateTrack(track)
            imported.append(track)
            try? fm.removeItem(at: wav)
            try? fm.removeItem(at: encoded)
        }
        tracksByAlbum[album.title] = imported

        // The cover, in the album's folder as the Mac app keeps it.
        if let first = imported.first, let coverURL = first.coverURL(root: root) {
            let lettering = Artwork.Lettering(title: album.title, artist: album.artist, font: album.fonts.title,
                                              artistFont: album.fonts.artist, color: album.letteringColor, top: album.letteringTop)
            try Artwork.cover(style: album.cover, palette: album.palette, lettering: lettering, seed: album.title).write(to: coverURL)
        }

        let key = SearchIndex.albumKey(album: album.title, artist: album.artist)
        var info = AlbumInfo(title: album.title)
        info.primaryType = album.type
        info.firstReleaseDate = imported.first?.metadata.extended.releaseDate
        // Only the songs' genre, so its chip finds them.
        info.genres = [album.genre.lowercased()]
        info.description = album.description
        info.descriptionSource = "the sample library"
        info.fetchedAt = now
        try db.saveAlbumInfo(key: key, info)

        if let owned = album.owned {
            let format = album.medium == .vinyl ? "12\" Vinyl" : album.medium == .download ? "Digital Media" : "CD"
            let own = SampleCatalog.Copy(medium: album.medium, sticker: album.sticker, daysAgo: owned.daysAgo, price: owned.price,
                                         formatDetail: format, catalogNumber: album.catalogNumber)
            var item = collectionItem(own, title: album.title, artist: album.artist, year: album.year, label: album.label,
                                      trackCount: imported.count, addedDaysAgo: album.addedDaysAgo)
            item.digitalSource = album.medium == .download ? .download : .rip
            collection.append(item)
            for copy in album.otherCopies {
                var other = collectionItem(copy, title: album.title, artist: album.artist, year: album.year, label: album.label,
                                           trackCount: imported.count, addedDaysAgo: album.addedDaysAgo)
                other.digitalSource = .same
                collection.append(other)
            }
        }
    }

    // MARK: Collection

    // Records and CDs with no songs: their own covers and, in their album info, their track lists.
    for shelfItem in SampleCatalog.shelf {
        log("\(shelfItem.artist) – \(shelfItem.title) (\(shelfItem.copy.medium.name))")
        var item = collectionItem(shelfItem.copy, title: shelfItem.title, artist: shelfItem.artist, year: shelfItem.year,
                                  label: shelfItem.label, trackCount: shelfItem.tracks.count, addedDaysAgo: nil)
        let lettering = Artwork.Lettering(title: shelfItem.title, artist: shelfItem.artist, font: shelfItem.fonts.title,
                                          artistFont: shelfItem.fonts.artist, color: shelfItem.letteringColor, top: shelfItem.letteringTop)
        let cover = Artwork.cover(style: shelfItem.cover, palette: shelfItem.palette, lettering: lettering, seed: shelfItem.title)
        item.coverFile = try CollectionCovers.write(cover, itemID: item.id, root: root)
        collection.append(item)

        var info = AlbumInfo(title: shelfItem.title)
        info.primaryType = shelfItem.type == "Live" ? "Album" : shelfItem.type
        if shelfItem.type == "Live" { info.secondaryTypes = ["Live"] }
        info.firstReleaseDate = String(shelfItem.year)
        info.genres = [shelfItem.genre.lowercased()]
        info.description = shelfItem.description
        info.descriptionSource = "the sample library"
        info.tracklist = shelfItem.tracks.enumerated().map { i, t in
            TracklistEntry(disc: 1, number: i + 1, title: t.1, artist: shelfItem.artist, position: t.0)
        }
        info.fetchedAt = now
        try db.saveAlbumInfo(key: item.albumKey, info)
    }
    // Through the collection API, so `album_ownership` gets its projection (CDs and the download) for older phones.
    try db.saveCollectionItems(collection, at: now)
    log("\(collection.count) items in the collection")

    // MARK: Artists

    let imageFolder = root.appendingPathComponent(LibraryExporter.artistImageFolder, isDirectory: true)
    try fm.createDirectory(at: imageFolder, withIntermediateDirectories: true)
    for artist in SampleCatalog.artists {
        var info = ArtistInfo(name: artist.name)
        info.type = artist.type
        info.country = artist.country
        info.begin = artist.begin
        info.genres = artist.genres
        info.bio = artist.bio
        info.bioSource = "the sample library"
        info.fetchedAt = now
        let file = artist.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + ".jpg"
        try Artwork.artistPicture(palette: artist.palette, seed: artist.name).write(to: imageFolder.appendingPathComponent(file))
        try db.saveArtistInfo(key: LibrarySnapshot.artistKey(artist.name), info, imageFile: file)
    }

    // MARK: Playlists

    func track(_ album: String, _ number: Int) -> Track? { tracksByAlbum[album]?.first { $0.trackNo == number } }
    for (name, entries) in SampleCatalog.playlists {
        let playlist = try db.createPlaylist(name: name)
        try db.addTracks(entries.compactMap { track($0.0, $0.1)?.id }, toPlaylist: playlist.id)
    }
    for (name, query) in SampleCatalog.smartPlaylists { _ = try db.createSmartPlaylist(name: name, query: query) }

    // MARK: Listening history

    var rng = SeededRandom("listening history")
    struct Candidate { var track: Track; var album: SampleCatalog.Album; var weight: Double }
    let songWeights: [Int64: Double] = Dictionary(uniqueKeysWithValues: tracksByAlbum.values.flatMap { $0 }.map { t in
        var r = SeededRandom("weight \(t.title)")
        return (t.id, r.chance(0.2) ? r.range(2.2...3.2) : r.range(0.4...1.2))
    })
    func candidates(daysAgo: Int) -> [Candidate] {
        SampleCatalog.albums.flatMap { album -> [Candidate] in
            guard daysAgo < album.addedDaysAgo else { return [] }
            let weight = album.affinity.last { daysAgo <= $0.from }?.weight ?? 0
            return (tracksByAlbum[album.title] ?? []).map { Candidate(track: $0, album: album, weight: weight * (songWeights[$0.id] ?? 1)) }
        }
    }
    func pick(_ list: [Candidate]) -> Candidate {
        var x = rng.unit() * list.reduce(0) { $0 + $1.weight }
        for c in list {
            x -= c.weight
            if x <= 0 { return c }
        }
        return list[list.count - 1]
    }

    var plays = 0
    for daysAgo in stride(from: 420, through: 0, by: -1) {
        let list = candidates(daysAgo: daysAgo)
        guard !list.isEmpty else { continue }
        let date = now.addingTimeInterval(-Double(daysAgo) * day)
        let weekend = [1, 7].contains(calendar.component(.weekday, from: date))
        guard daysAgo < 6 || rng.chance(weekend ? 0.85 : 0.72) else { continue }
        let startOfDay = calendar.startOfDay(for: date)
        let sessions = 1 + Int(rng.next() % (weekend ? 3 : 2))
        for _ in 0..<sessions {
            let hour: Double = weekend ? rng.pick([9, 10, 11, 14, 16, 19, 21, 22]) : rng.pick([7, 8, 8, 12, 18, 19, 20, 21, 22, 23])
            var at = startOfDay.addingTimeInterval(hour * 3600 + rng.range(0...2400))
            // A whole album, or a shuffle of favorites.
            let queue: [Track]
            if rng.chance(0.45) {
                let album = pick(list).album
                queue = tracksByAlbum[album.title] ?? []
            } else {
                queue = (0..<(4 + Int(rng.next() % 9))).map { _ in pick(list).track }
            }
            for t in queue where at < now {
                let skipped = rng.chance(0.12)
                let listened = skipped ? rng.range(3...(t.duration * 0.4)) : t.duration
                try db.recordPlay(trackId: t.id, startedAt: at, listened: listened, counted: !skipped)
                plays += 1
                at = at.addingTimeInterval(listened + rng.range(0...4))
            }
        }
    }
    log("\(plays) plays")

    // MARK: Likes

    let favorites = songWeights.filter { $0.value > 2 }.keys.sorted()
    let extra = tracksByAlbum.values.flatMap { $0 }.map(\.id).filter { !favorites.contains($0) }.sorted()
    for id in favorites.prefix(10) + extra.filter({ $0 % 5 == 0 }).prefix(5) {
        guard let t = tracksByAlbum.values.flatMap({ $0 }).first(where: { $0.id == id }) else { continue }
        let since = now.timeIntervalSince(t.addedAt)
        try db.setLiked([id], true, at: t.addedAt.addingTimeInterval(since * rng.range(0.1...0.8)))
    }

    // A compact copy without the catalog tables, as a sync writes it.
    try db.writeSyncSnapshot(to: scratch.appendingPathComponent("library.sqlite"), scratch: scratch.appendingPathComponent("snapshot"))
}
for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: LibraryLocation.databaseURL(root: root).path + suffix) }
try fm.moveItem(at: scratch.appendingPathComponent("library.sqlite"), to: LibraryLocation.databaseURL(root: root))
log("Done: \(root.path)")
#endif
