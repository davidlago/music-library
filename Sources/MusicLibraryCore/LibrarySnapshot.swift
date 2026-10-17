import Foundation

/// A library as the iPhone app shows it: a `library.sqlite` snapshot (written by a sync or an export, opened
/// read-only) with everything in it (every album, artist, cover, the cached artist and album info, listening
/// history and ownership), and which songs' files are on the phone. Only those can be played; the rest can be
/// browsed and asked for (`SyncRequest`).
public struct LibrarySnapshot: Sendable {
    public struct PlaylistItem: Identifiable, Hashable, Sendable {
        public var playlist: Playlist
        /// Every track, in playlist order.
        public var tracks: [Track]
        public var id: Int64 { playlist.id }
    }

    public let root: URL
    /// Every track, in the library's order.
    public let tracks: [Track]
    /// Tracks whose files are on the phone.
    public let presentIDs: Set<Int64>
    public let index: SearchIndex
    /// Every album and artist, in the Mac app's order.
    public let albums: [AlbumSummary]
    public let artists: [ArtistSummary]
    /// When each album's newest song was added, by `SearchIndex.albumKey`.
    public let albumAddedDates: [String: Date]
    /// Playlists with at least one track.
    public let playlists: [PlaylistItem]
    public let smartPlaylists: [SmartPlaylist]
    /// When each liked track was liked.
    public let likedDates: [Int64: Date]
    /// The library this is a copy of (`Database.libraryID`).
    public let libraryID: String?
    /// The listening history and its totals per track, as of the sync.
    public let plays: [Play]
    public let playTotals: [Int64: PlayTotal]
    /// Albums owned, by `SearchIndex.albumKey`, including those whose songs you bought (`AlbumPurchase.including`).
    public let purchases: [String: AlbumPurchase]
    /// Songs bought as downloads, by track ID.
    public let songPurchases: [Int64: TrackPurchase]
    /// Cached online info, by `LibrarySnapshot.artistKey` and `SearchIndex.albumKey`.
    public let artistInfos: [String: ArtistInfo]
    public let albumInfos: [String: AlbumInfo]
    /// Photo files in `Artist Images`: the user's choice, else the downloaded one. Untrusted names are dropped.
    public let artistImageFiles: [String: String]
    public let artistPhotos: [String: ArtistPhotoChoice]
    /// Who played, wrote and produced with whom (Music DNA).
    public let collaborations: CollaborationGraph
    private let albumTracks: [String: [Track]]
    private let trackByID: [Int64: Track]

    /// Opens `<root>/library.sqlite`. `isPresent` defaults to checking the track's file, which must resolve
    /// inside `root` (`Track.resolvedFileURL`). `datesRelativeToNow` moves the history (plays, likes, purchases, when
    /// songs were added) forward by whole days so the last play was within the last day: for the sample library, which is
    /// made once and opened any time later.
    public init(root: URL, isPresent: ((Track) -> Bool)? = nil, datesRelativeToNow: Bool = false, now: Date = Date()) throws {
        let db = try Database(snapshotAt: LibraryLocation.databaseURL(root: root).path)
        let fm = FileManager.default
        let present = isPresent ?? { t in t.resolvedFileURL(root: root).map { fm.fileExists(atPath: $0.path) } ?? false }
        var all = try db.fetchAllTracks()
        // Snapshots from older versions may lack the newer tables: those are just empty.
        var plays = (try? db.plays()) ?? []
        var playTotals = (try? db.playTotals()) ?? [:]
        var likedDates = (try? db.likedTrackDates()) ?? [:]
        var purchases = (try? db.albumPurchases()) ?? [:]
        var songPurchases = (try? db.trackPurchases()) ?? [:]
        if datesRelativeToNow {
            let shift = Self.dayShift(latest: plays.last?.startedAt ?? all.map(\.addedAt).max(), now: now)
            for i in all.indices { all[i].addedAt += shift }
            for i in plays.indices { plays[i].startedAt += shift }
            playTotals = playTotals.mapValues { var t = $0; t.lastPlayed = t.lastPlayed.map { $0 + shift }; return t }
            likedDates = likedDates.mapValues { $0 + shift }
            purchases = purchases.mapValues { p in
                var p = p
                p.purchasedOn = p.purchasedOn.map { PurchaseDay($0.date().addingTimeInterval(shift)) }
                return p
            }
            songPurchases = songPurchases.mapValues { p in
                var p = p
                p.purchasedOn = p.purchasedOn.map { PurchaseDay($0.date().addingTimeInterval(shift)) }
                return p
            }
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        likedDates = likedDates.filter { byID[$0.key] != nil }
        let playlists = ((try? db.playlists()) ?? []).compactMap { p -> PlaylistItem? in
            let ids = (try? db.playlistTrackIds(p.id)) ?? []
            let items = ids.compactMap { byID[$0] }
            return items.isEmpty ? nil : PlaylistItem(playlist: p, tracks: items)
        }

        var covers: [String: Bool] = [:]
        let index = SearchIndex(tracks: all) { t in
            let dir = (t.path as NSString).deletingLastPathComponent
            if let known = covers[dir] { return known }
            let has = t.coverURL(root: root).map { fm.fileExists(atPath: $0.path) } ?? false
            covers[dir] = has
            return has
        }

        var albumTracks: [String: [Track]] = [:]
        for t in all { albumTracks[SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist), default: []].append(t) }
        for (k, list) in albumTracks { albumTracks[k] = list.sorted(by: Self.albumOrder) }

        let infos = (try? db.artistInfos()) ?? [:]
        let photos = (try? db.artistPhotos()) ?? [:]
        var imageFiles = infos.compactMapValues { $0.imageFile }.filter { ArtistPhotoChoice.isSafeFileName($0.value) }
        for (key, choice) in photos { imageFiles[key] = choice.file }

        self.root = root
        self.tracks = all
        self.presentIDs = Set(all.filter(present).map(\.id))
        self.index = index
        self.albums = Self.albums(from: albumTracks)
        self.artists = Self.artists(from: albumTracks)
        self.albumAddedDates = AlbumSort.addedDates(all)
        self.playlists = playlists
        self.smartPlaylists = (try? db.smartPlaylists()) ?? []
        self.likedDates = likedDates
        self.libraryID = db.libraryID()
        self.plays = plays
        self.playTotals = playTotals
        self.purchases = AlbumPurchase.including(songs: songPurchases, tracks: all, in: purchases)
        self.songPurchases = songPurchases
        self.artistInfos = infos.mapValues(\.info)
        self.albumInfos = (try? db.albumInfos()) ?? [:]
        self.artistImageFiles = imageFiles
        self.artistPhotos = photos
        self.collaborations = CollaborationGraph(tracks: all)
        self.albumTracks = albumTracks
        self.trackByID = byID
    }

    public func track(id: Int64) -> Track? { trackByID[id] }

    /// Whole days from `latest` to `now` (none when `latest` is later or missing).
    static func dayShift(latest: Date?, now: Date) -> TimeInterval {
        guard let latest, latest < now else { return 0 }
        return (now.timeIntervalSince(latest) / 86_400).rounded(.down) * 86_400
    }

    public func isPresent(_ track: Track) -> Bool { presentIDs.contains(track.id) }

    /// The ones whose files are on the phone, in the same order.
    public func playable(_ tracks: [Track]) -> [Track] { tracks.filter { presentIDs.contains($0.id) } }

    /// The tracks on the phone, in the library's order.
    public var presentTracks: [Track] { playable(tracks) }

    /// The album's tracks by disc and track number.
    public func tracks(album: AlbumSummary) -> [Track] {
        albumTracks[SearchIndex.albumKey(album: album.album, artist: album.artist)] ?? []
    }

    public func album(forKey key: String) -> AlbumSummary? {
        albums.first { SearchIndex.albumKey(album: $0.album, artist: $0.artist) == key }
    }

    public func album(of track: Track) -> AlbumSummary? {
        album(forKey: SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist))
    }

    public func albums(artist: String) -> [AlbumSummary] {
        albums.filter { $0.artist.caseInsensitiveCompare(artist) == .orderedSame }
    }

    public func artist(named name: String) -> ArtistSummary? {
        artists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func tracks(artist: String) -> [Track] {
        albums(artist: artist).flatMap { tracks(album: $0) }
    }

    public func tracks(smartPlaylist p: SmartPlaylist) -> [Track] {
        index.tracks(matching: SearchQuery.parse(p.query))
    }

    /// An item's tracks, as the Mac resolves it for sync.
    public func tracks(for item: ExportItem) -> [Track] {
        switch item {
        case .library: return tracks
        case .album(let album, let artist): return albumTracks[SearchIndex.albumKey(album: album, artist: artist)] ?? []
        case .artist(let name): return tracks(artist: name)
        case .track(let id): return trackByID[id].map { [$0] } ?? []
        case .playlist(let id): return playlists.first { $0.id == id }?.tracks ?? []
        case .smartPlaylist(let id): return smartPlaylists.first { $0.id == id }.map(tracks(smartPlaylist:)) ?? []
        case .likedSongs:
            return likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { trackByID[$0.key] }
        }
    }

    public func coverURL(album: AlbumSummary) -> URL? {
        LibraryPath.coverURL(forTrackAt: album.firstTrackPath, root: root)
    }

    // MARK: Artists

    /// How artist info, photos and play totals are keyed (as the Mac's `ArtistInfoStore.key`).
    public static func artistKey(_ name: String) -> String { name.lowercased() }

    public func artistInfo(_ name: String) -> ArtistInfo? { artistInfos[Self.artistKey(name)] }

    public func albumInfo(_ album: AlbumSummary) -> AlbumInfo? {
        albumInfos[SearchIndex.albumKey(album: album.album, artist: album.artist)]
    }

    /// The artist's photo: the one chosen on the Mac, else the downloaded one.
    public func artistImageURL(_ name: String) -> URL? {
        guard let file = artistImageFiles[Self.artistKey(name)] else { return nil }
        return root.appendingPathComponent(LibraryExporter.artistImageFolder, isDirectory: true).appendingPathComponent(file)
    }

    /// Who to credit for the photo shown ("Photo: …"); nil for the user's own images.
    public func photoCredit(_ name: String) -> (label: String, url: URL?)? {
        if let chosen = artistPhotos[Self.artistKey(name)] { return chosen.credit.map { ($0, chosen.creditURL) } }
        return artistInfo(name)?.imageCreditURL.map { ("Wikimedia Commons", $0) }
    }

    /// Where the library is in the app's Documents folder: `Music Library` (where sync puts it), Documents
    /// itself, or an export dragged in under another name (Finder's Files tab copies a folder in as it is).
    public static func findRoot(in documents: URL) -> URL? {
        let fm = FileManager.default
        func isLibrary(_ url: URL) -> Bool { fm.fileExists(atPath: LibraryLocation.databaseURL(root: url).path) }
        let preferred = documents.appendingPathComponent(LibraryLocation.phoneFolderName, isDirectory: true)
        if isLibrary(preferred) { return preferred }
        if isLibrary(documents) { return documents }
        let children = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.first(where: isLibrary)
    }

    // MARK: Ordering (as `Database.albums`/`artists`/`tracks(album:artist:)` sort)

    static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        if (a.metadata.discNo ?? 0) != (b.metadata.discNo ?? 0) { return (a.metadata.discNo ?? 0) < (b.metadata.discNo ?? 0) }
        if (a.trackNo ?? 0) != (b.trackNo ?? 0) { return (a.trackNo ?? 0) < (b.trackNo ?? 0) }
        return a.title.caseInsensitiveCompare(b.title) == .orderedAscending
    }

    static func albums(from albumTracks: [String: [Track]]) -> [AlbumSummary] {
        albumTracks.values.compactMap { list -> AlbumSummary? in
            guard let first = list.first else { return nil }
            return AlbumSummary(album: first.album, artist: first.effectiveAlbumArtist, year: list.compactMap(\.year).max(),
                                trackCount: list.count, firstTrackPath: list.map(\.path).min() ?? first.path)
        }.sorted { a, b in
            let artist = a.artist.caseInsensitiveCompare(b.artist)
            if artist != .orderedSame { return artist == .orderedAscending }
            if a.year != b.year { return (a.year ?? Int.min) < (b.year ?? Int.min) }
            return a.album.caseInsensitiveCompare(b.album) == .orderedAscending
        }
    }

    static func artists(from albumTracks: [String: [Track]]) -> [ArtistSummary] {
        var byKey: [String: ArtistSummary] = [:]
        for list in albumTracks.values {
            guard let first = list.first else { continue }
            let key = first.effectiveAlbumArtist.lowercased()
            byKey[key, default: ArtistSummary(name: first.effectiveAlbumArtist, albumCount: 0, trackCount: 0)].albumCount += 1
            byKey[key]?.trackCount += list.count
        }
        return byKey.values.sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
