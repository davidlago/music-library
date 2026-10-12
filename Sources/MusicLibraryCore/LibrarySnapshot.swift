import Foundation

/// A library as the iPhone app shows it: a `library.sqlite` snapshot (written by an export or a sync, opened
/// read-only) narrowed to the tracks whose files are present, since only part of the library is copied over.
public struct LibrarySnapshot: Sendable {
    public struct PlaylistItem: Identifiable, Hashable, Sendable {
        public var playlist: Playlist
        /// Present tracks only, in playlist order.
        public var tracks: [Track]
        public var id: Int64 { playlist.id }
    }

    public let root: URL
    /// Present tracks, in the library's order.
    public let tracks: [Track]
    /// Every track in the snapshot, present or not.
    public let snapshotTrackCount: Int
    public let index: SearchIndex
    /// Albums and artists with at least one present track, in the Mac app's order.
    public let albums: [AlbumSummary]
    public let artists: [ArtistSummary]
    /// Playlists with at least one present track.
    public let playlists: [PlaylistItem]
    public let smartPlaylists: [SmartPlaylist]
    /// Present liked tracks, most recently liked first.
    public let liked: [Track]
    public let likedIDs: Set<Int64>
    /// When each present liked track was liked.
    public let likedDates: [Int64: Date]
    /// The library this is a copy of (`Database.libraryID`).
    public let libraryID: String?
    private let albumTracks: [String: [Track]]
    private let trackByID: [Int64: Track]

    /// Opens `<root>/library.sqlite`. `isPresent` defaults to checking the track's file, which must resolve
    /// inside `root` (`Track.resolvedFileURL`).
    public init(root: URL, isPresent: ((Track) -> Bool)? = nil) throws {
        let db = try Database(snapshotAt: LibraryLocation.databaseURL(root: root).path)
        let fm = FileManager.default
        let present = isPresent ?? { t in t.resolvedFileURL(root: root).map { fm.fileExists(atPath: $0.path) } ?? false }
        let all = try db.fetchAllTracks()
        let tracks = all.filter(present)
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Snapshots from older versions may lack the newer tables: those lists are just empty.
        let likedDates = (try? db.likedTrackDates()) ?? [:]
        let liked = likedDates.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { byID[$0.key] }
        let playlists = ((try? db.playlists()) ?? []).compactMap { p -> PlaylistItem? in
            let ids = (try? db.playlistTrackIds(p.id)) ?? []
            let items = ids.compactMap { byID[$0] }
            return items.isEmpty ? nil : PlaylistItem(playlist: p, tracks: items)
        }

        var covers: [String: Bool] = [:]
        let index = SearchIndex(tracks: tracks) { t in
            let dir = (t.path as NSString).deletingLastPathComponent
            if let known = covers[dir] { return known }
            let has = t.coverURL(root: root).map { fm.fileExists(atPath: $0.path) } ?? false
            covers[dir] = has
            return has
        }

        var albumTracks: [String: [Track]] = [:]
        for t in tracks { albumTracks[SearchIndex.albumKey(album: t.album, artist: t.effectiveAlbumArtist), default: []].append(t) }
        for (k, list) in albumTracks { albumTracks[k] = list.sorted(by: Self.albumOrder) }

        self.root = root
        self.tracks = tracks
        self.snapshotTrackCount = all.count
        self.index = index
        self.albums = Self.albums(from: albumTracks)
        self.artists = Self.artists(from: albumTracks)
        self.playlists = playlists
        self.smartPlaylists = (try? db.smartPlaylists()) ?? []
        self.liked = liked
        self.likedIDs = Set(liked.map(\.id))
        self.likedDates = likedDates.filter { byID[$0.key] != nil }
        self.libraryID = db.libraryID()
        self.albumTracks = albumTracks
        self.trackByID = byID
    }

    public func track(id: Int64) -> Track? { trackByID[id] }

    /// The album's present tracks by disc and track number.
    public func tracks(album: AlbumSummary) -> [Track] {
        albumTracks[SearchIndex.albumKey(album: album.album, artist: album.artist)] ?? []
    }

    public func albums(artist: String) -> [AlbumSummary] {
        albums.filter { $0.artist.caseInsensitiveCompare(artist) == .orderedSame }
    }

    public func tracks(artist: String) -> [Track] {
        albums(artist: artist).flatMap { tracks(album: $0) }
    }

    public func tracks(smartPlaylist p: SmartPlaylist) -> [Track] {
        index.tracks(matching: SearchQuery.parse(p.query))
    }

    public func coverURL(album: AlbumSummary) -> URL? {
        LibraryPath.coverURL(forTrackAt: album.firstTrackPath, root: root)
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
