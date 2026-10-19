import Foundation

/// The app's identity for network requests (MusicBrainz asks for a name, version and contact URL).
public enum AppInfo {
    public static let homepage = "https://github.com/davidlago/music-library"
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    public static var userAgent: String { "MusicLibrary/\(version) ( \(homepage) )" }
}

public let supportedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "aif", "aiff", "wav"]
public let tagWritableExtensions: Set<String> = ["mp3", "flac", "m4a"]

public struct TrackMetadata: Hashable, Sendable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var year: Int?
    public var trackNo: Int?
    public var trackTotal: Int?
    public var discNo: Int?
    public var discTotal: Int?
    public var genre = ""
    public var mbRecordingId: String?
    public var mbReleaseId: String?
    public var composer = ""
    public var extended = ExtendedMetadata()

    public init(
        title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
        year: Int? = nil, trackNo: Int? = nil, trackTotal: Int? = nil, discNo: Int? = nil,
        discTotal: Int? = nil, genre: String = "", mbRecordingId: String? = nil, mbReleaseId: String? = nil,
        composer: String = "", extended: ExtendedMetadata = ExtendedMetadata()
    ) {
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.year = year; self.trackNo = trackNo; self.trackTotal = trackTotal; self.discNo = discNo
        self.discTotal = discTotal; self.genre = genre
        self.mbRecordingId = mbRecordingId; self.mbReleaseId = mbReleaseId
        self.composer = composer; self.extended = extended
    }
}

public struct Track: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var path: String
    public var metadata: TrackMetadata
    public var duration: Double
    public var format: String
    public var sha256: String
    public var addedAt: Date
    public var audioFormat: AudioFormat?

    public var title: String { metadata.title }
    public var artist: String { metadata.artist }
    public var album: String { metadata.album }
    public var albumArtist: String { metadata.albumArtist }
    public var year: Int? { metadata.year }
    public var trackNo: Int? { metadata.trackNo }
    public var composer: String { metadata.composer }
    public var effectiveAlbumArtist: String {
        metadata.albumArtist.isEmpty ? metadata.artist : metadata.albumArtist
    }

    public init(id: Int64 = 0, path: String, metadata: TrackMetadata, duration: Double, format: String, sha256: String, addedAt: Date = Date(), audioFormat: AudioFormat? = nil) {
        self.id = id; self.path = path; self.metadata = metadata; self.duration = duration
        self.format = format; self.sha256 = sha256; self.addedAt = addedAt; self.audioFormat = audioFormat
    }

    /// Where the file would be, for display. Use `resolvedFileURL(root:)` to read, copy or move it.
    public func fileURL(root: URL) -> URL { root.appendingPathComponent(path) }
    /// The file, or nil when the stored path leads outside `root` (via "..", an absolute path or a symlink).
    public func resolvedFileURL(root: URL) -> URL? { LibraryPath.resolve(path, in: root) }
    /// The album's cover.jpg, or nil when the stored path leads outside `root`.
    public func coverURL(root: URL) -> URL? { LibraryPath.coverURL(forTrackAt: path, root: root) }
}

public struct Playlist: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var createdAt: Date
    public var trackCount: Int
    public init(id: Int64, name: String, createdAt: Date, trackCount: Int = 0) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.trackCount = trackCount
    }
}

public struct PlayTotal: Hashable, Sendable {
    /// Plays that counted (half the track or 4 minutes).
    public var plays: Int
    /// Seconds actually listened, including plays too short to count.
    public var listened: Double
    public var lastPlayed: Date?

    public init(plays: Int = 0, listened: Double = 0, lastPlayed: Date? = nil) {
        self.plays = plays; self.listened = listened; self.lastPlayed = lastPlayed
    }

    public static func + (a: PlayTotal, b: PlayTotal) -> PlayTotal {
        PlayTotal(plays: a.plays + b.plays, listened: a.listened + b.listened,
                  lastPlayed: [a.lastPlayed, b.lastPlayed].compactMap { $0 }.max())
    }
}

/// One listen from the `plays` table.
public struct Play: Hashable, Sendable {
    public var trackId: Int64
    public var startedAt: Date
    /// Seconds actually listened.
    public var listened: Double
    /// Long enough to count (the scrobble rule).
    public var counted: Bool

    public init(trackId: Int64, startedAt: Date, listened: Double, counted: Bool) {
        self.trackId = trackId; self.startedAt = startedAt; self.listened = listened; self.counted = counted
    }
}

/// A saved search whose tracks are recomputed from the library whenever it is shown.
public struct SmartPlaylist: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var query: String
    public var createdAt: Date
    public init(id: Int64, name: String, query: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.query = query; self.createdAt = createdAt
    }
}

public struct AlbumSummary: Identifiable, Hashable, Sendable {
    public var id: String { "\(artist)\u{1}\(album)" }
    public var album: String
    public var artist: String
    public var year: Int?
    public var trackCount: Int
    public var firstTrackPath: String
}

public struct ArtistSummary: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var albumCount: Int
    public var trackCount: Int

    public init(name: String, albumCount: Int, trackCount: Int) {
        self.name = name; self.albumCount = albumCount; self.trackCount = trackCount
    }
}

public enum MatchSource: String, Sendable { case musicBrainz, acoustID }

public struct MatchCandidate: Identifiable, Hashable, Sendable {
    public var id: String { "\(recordingId)|\(releaseId)" }
    public var recordingId: String
    public var releaseId: String
    public var releaseGroupId: String?
    public var title: String
    public var artist: String
    public var album: String
    public var date: String?
    public var year: Int?
    public var durationSeconds: Double?
    public var score: Int
    public var releaseType: String?
    public var releaseStatus: String?
    public var secondaryTypes: [String]
    public var source: MatchSource

    public init(
        recordingId: String, releaseId: String, releaseGroupId: String? = nil, title: String, artist: String,
        album: String, date: String? = nil, year: Int? = nil, durationSeconds: Double? = nil, score: Int,
        releaseType: String? = nil, releaseStatus: String? = nil, secondaryTypes: [String] = [], source: MatchSource = .musicBrainz
    ) {
        self.recordingId = recordingId; self.releaseId = releaseId; self.releaseGroupId = releaseGroupId
        self.title = title; self.artist = artist; self.album = album; self.date = date; self.year = year
        self.durationSeconds = durationSeconds; self.score = score; self.releaseType = releaseType
        self.releaseStatus = releaseStatus; self.secondaryTypes = secondaryTypes; self.source = source
    }
}
