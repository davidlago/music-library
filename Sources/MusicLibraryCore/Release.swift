import Foundation

public struct Genre: Hashable, Sendable {
    public var name: String
    public var count: Int
    public init(name: String, count: Int) { self.name = name; self.count = count }
}

public struct ReleaseTrack: Hashable, Sendable {
    public var recordingId: String
    public var title: String
    public var artist: String
    public var discNo: Int
    public var trackNo: Int
    public var trackTotal: Int
    public var durationSeconds: Double?
    public var releaseTrackId = ""
    public var numberLabel = ""
    public var isrcs: [String] = []
    public var credits: [Credit] = []
    public var workTitle = ""
    public var iswcs: [String] = []
    public var workIds: [String] = []
    public var artistSort = ""
    public var artistIds: [String] = []
    public var genres: [Genre] = []
    public var mediaFormat = ""
    public var discSubtitle = ""

    public init(
        recordingId: String, title: String, artist: String, discNo: Int, trackNo: Int, trackTotal: Int,
        durationSeconds: Double?, releaseTrackId: String = "", numberLabel: String = "", isrcs: [String] = [],
        credits: [Credit] = [], workTitle: String = "", iswcs: [String] = [], workIds: [String] = [],
        artistSort: String = "", artistIds: [String] = [], genres: [Genre] = [], mediaFormat: String = "",
        discSubtitle: String = ""
    ) {
        self.recordingId = recordingId; self.title = title; self.artist = artist; self.discNo = discNo
        self.trackNo = trackNo; self.trackTotal = trackTotal; self.durationSeconds = durationSeconds
        self.releaseTrackId = releaseTrackId; self.numberLabel = numberLabel; self.isrcs = isrcs
        self.credits = credits; self.workTitle = workTitle; self.iswcs = iswcs; self.workIds = workIds
        self.artistSort = artistSort; self.artistIds = artistIds; self.genres = genres
        self.mediaFormat = mediaFormat; self.discSubtitle = discSubtitle
    }
}

public struct ReleaseInfo: Hashable, Sendable {
    public var id: String
    public var releaseGroupId: String?
    public var album: String
    public var albumArtist: String
    public var date: String?
    public var year: Int?
    public var originalYear: Int?
    public var discTotal: Int
    public var tracks: [ReleaseTrack]
    public var originalDate = ""
    public var albumArtistSort = ""
    public var albumArtistIds: [String] = []
    public var label = ""
    public var catalogNumber = ""
    public var barcode = ""
    public var asin = ""
    public var country = ""
    public var status = ""
    public var packaging = ""
    public var language = ""
    public var script = ""
    public var releaseType = ""
    public var secondaryTypes: [String] = []
    public var credits: [Credit] = []
    public var releaseGenres: [Genre] = []
    public var groupGenres: [Genre] = []

    public init(
        id: String, releaseGroupId: String?, album: String, albumArtist: String, date: String?, year: Int?,
        originalYear: Int?, discTotal: Int, tracks: [ReleaseTrack]
    ) {
        self.id = id; self.releaseGroupId = releaseGroupId; self.album = album; self.albumArtist = albumArtist
        self.date = date; self.year = year; self.originalYear = originalYear; self.discTotal = discTotal
        self.tracks = tracks
    }

    public func track(forRecording recordingId: String) -> ReleaseTrack? {
        tracks.first { $0.recordingId == recordingId }
    }

    /// Everything MusicBrainz knows about `track` on this release, in `ExtendedMetadata` form.
    public func extended(for track: ReleaseTrack) -> ExtendedMetadata {
        var e = ExtendedMetadata()
        let allCredits = track.credits + credits
        let d = CreditDerivation.derive(allCredits)
        e.lyricist = d.lyricist; e.writer = d.writer; e.arranger = d.arranger; e.conductor = d.conductor
        e.producer = d.producer; e.engineer = d.engineer; e.mixer = d.mixer; e.remixer = d.remixer
        e.performers = d.performers
        e.label = label; e.catalogNumber = catalogNumber; e.barcode = barcode; e.asin = asin
        e.releaseCountry = country; e.releaseStatus = status; e.releaseType = releaseType
        e.releaseSecondaryTypes = secondaryTypes; e.packaging = packaging; e.language = language; e.script = script
        e.releaseDate = date ?? ""; e.originalDate = originalDate
        e.mediaFormat = track.mediaFormat; e.discSubtitle = track.discSubtitle; e.trackNumberLabel = track.numberLabel
        e.artistSort = track.artistSort; e.albumArtistSort = albumArtistSort
        e.isrcs = track.isrcs; e.workTitle = track.workTitle; e.iswcs = track.iswcs
        e.mbReleaseGroupId = releaseGroupId ?? ""; e.mbArtistIds = track.artistIds; e.mbAlbumArtistIds = albumArtistIds
        e.mbReleaseTrackId = track.releaseTrackId; e.mbWorkIds = track.workIds
        e.mbGenres = GenreSelection.names(track: track.genres, group: groupGenres, release: releaseGenres)
        e.credits = allCredits
        return e
    }

    public func apply(_ track: ReleaseTrack, to metadata: inout TrackMetadata) {
        metadata.album = album
        metadata.albumArtist = albumArtist
        metadata.year = originalYear ?? year ?? metadata.year
        metadata.title = track.title
        metadata.artist = track.artist
        metadata.trackNo = track.trackNo
        metadata.trackTotal = track.trackTotal
        metadata.discNo = track.discNo
        metadata.discTotal = discTotal
        // A Discogs release (`DiscogsRelease.releaseInfo`) has no MusicBrainz IDs.
        metadata.mbRecordingId = track.recordingId.isEmpty ? nil : track.recordingId
        metadata.mbReleaseId = id.isEmpty ? nil : id
        let ext = extended(for: track)
        let composer = CreditDerivation.derive(track.credits + credits).composer
        if !composer.isEmpty { metadata.composer = composer }
        if metadata.genre.isEmpty { metadata.genre = ext.mbGenres.prefix(3).joined(separator: "; ") }
        metadata.extended.merge(ext)
    }
}

public enum GenreSelection {
    public static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).map { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map { part in
                part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// Recording genres if any, else release-group, else release; sorted by count then name; title-cased.
    public static func names(track: [Genre], group: [Genre], release: [Genre]) -> [String] {
        let source = !track.isEmpty ? track : (!group.isEmpty ? group : release)
        let sorted = source.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        return CreditDerivation.dedupe(sorted.map { titleCase($0.name) })
    }
}

public enum CreditDerivation {
    public struct Result: Sendable {
        public var composer = "", writer = "", lyricist = "", arranger = "", conductor = ""
        public var producer = "", engineer = "", mixer = "", remixer = ""
        public var performers: [String] = []
    }

    static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func derive(_ credits: [Credit]) -> Result {
        func names(_ types: Set<String>, scope: Credit.Scope? = nil) -> [String] {
            dedupe(credits.filter { types.contains($0.role.lowercased()) && (scope == nil || $0.scope == scope) }.map(\.name))
        }
        func joined(_ xs: [String]) -> String { xs.joined(separator: "; ") }
        var r = Result()
        let composers = names(["composer"], scope: .work)
        r.composer = joined(composers.isEmpty ? names(["writer"], scope: .work) : composers)
        r.writer = joined(names(["writer"], scope: .work))
        r.lyricist = joined(names(["lyricist", "librettist"], scope: .work))
        r.arranger = joined(names(["arranger", "orchestrator", "instrument arranger", "vocal arranger"]))
        r.conductor = joined(names(["conductor"]))
        r.producer = joined(names(["producer"]))
        r.engineer = joined(names(["engineer"]))
        r.mixer = joined(names(["mix"]))
        r.remixer = joined(names(["remixer"]))
        var performers: [String] = []
        for c in credits where c.scope == .recording {
            switch c.role.lowercased() {
            case "instrument":
                if c.attributes.isEmpty { performers.append("\(c.name) (instrument)") }
                for a in c.attributes { performers.append("\(c.name) (\(a))") }
            case "vocal":
                if c.attributes.isEmpty { performers.append("\(c.name) (vocals)") }
                for a in c.attributes { performers.append("\(c.name) (\(a))") }
            case "performer":
                performers.append(c.name)
            default: break
            }
        }
        r.performers = dedupe(performers)
        return r
    }
}

public enum CreditFormatter {
    public static func label(_ c: Credit) -> [String] {
        let role = c.role.lowercased()
        switch role {
        case "instrument": return c.attributes.isEmpty ? ["instrument"] : c.attributes
        case "vocal": return c.attributes.isEmpty ? ["vocals"] : c.attributes
        case "mix": return ["mixer"]
        case "recording": return ["recording engineer"]
        default: return [(c.attributes + [role]).joined(separator: " ")]
        }
    }

    /// People in first-appearance order, each with their de-duplicated role labels.
    public static func grouped(_ credits: [Credit]) -> [(name: String, roles: [String])] {
        var order: [String] = []
        var roles: [String: [String]] = [:]
        for c in credits {
            if roles[c.name] == nil { order.append(c.name); roles[c.name] = [] }
            for l in label(c) where !(roles[c.name] ?? []).contains(l) { roles[c.name, default: []].append(l) }
        }
        return order.map { (name: $0, roles: roles[$0] ?? []) }
    }
}
