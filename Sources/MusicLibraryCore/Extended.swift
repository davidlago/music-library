import Foundation

public struct Credit: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Sendable { case recording, release, work }
    public var role: String
    public var name: String
    public var artistId: String?
    public var attributes: [String]
    public var scope: Scope

    public init(role: String, name: String, artistId: String? = nil, attributes: [String] = [], scope: Scope) {
        self.role = role; self.name = name; self.artistId = artistId; self.attributes = attributes; self.scope = scope
    }
}

public struct ExtendedMetadata: Codable, Hashable, Sendable {
    public var lyricist = ""
    public var writer = ""
    public var arranger = ""
    public var conductor = ""
    public var producer = ""
    public var engineer = ""
    public var mixer = ""
    public var remixer = ""
    public var label = ""
    public var catalogNumber = ""
    public var barcode = ""
    public var asin = ""
    public var releaseCountry = ""
    public var releaseStatus = ""
    public var releaseType = ""
    public var packaging = ""
    public var language = ""
    public var script = ""
    public var releaseDate = ""
    public var originalDate = ""
    public var mediaFormat = ""
    public var discSubtitle = ""
    public var trackNumberLabel = ""
    public var artistSort = ""
    public var albumArtistSort = ""
    public var workTitle = ""
    public var mbReleaseGroupId = ""
    public var mbReleaseTrackId = ""
    public var releaseSecondaryTypes: [String] = []
    public var isrcs: [String] = []
    public var iswcs: [String] = []
    public var mbArtistIds: [String] = []
    public var mbAlbumArtistIds: [String] = []
    public var mbWorkIds: [String] = []
    public var mbGenres: [String] = []
    public var performers: [String] = []
    public var credits: [Credit] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lyricist, writer, arranger, conductor, producer, engineer, mixer, remixer, label, catalogNumber, barcode, asin, releaseCountry, releaseStatus, releaseType, packaging, language, script, releaseDate, originalDate, mediaFormat, discSubtitle, trackNumberLabel, artistSort, albumArtistSort, workTitle, mbReleaseGroupId, mbReleaseTrackId, releaseSecondaryTypes, isrcs, iswcs, mbArtistIds, mbAlbumArtistIds, mbWorkIds, mbGenres, performers, credits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyricist = try c.decodeIfPresent(String.self, forKey: .lyricist) ?? ""
        writer = try c.decodeIfPresent(String.self, forKey: .writer) ?? ""
        arranger = try c.decodeIfPresent(String.self, forKey: .arranger) ?? ""
        conductor = try c.decodeIfPresent(String.self, forKey: .conductor) ?? ""
        producer = try c.decodeIfPresent(String.self, forKey: .producer) ?? ""
        engineer = try c.decodeIfPresent(String.self, forKey: .engineer) ?? ""
        mixer = try c.decodeIfPresent(String.self, forKey: .mixer) ?? ""
        remixer = try c.decodeIfPresent(String.self, forKey: .remixer) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        catalogNumber = try c.decodeIfPresent(String.self, forKey: .catalogNumber) ?? ""
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode) ?? ""
        asin = try c.decodeIfPresent(String.self, forKey: .asin) ?? ""
        releaseCountry = try c.decodeIfPresent(String.self, forKey: .releaseCountry) ?? ""
        releaseStatus = try c.decodeIfPresent(String.self, forKey: .releaseStatus) ?? ""
        releaseType = try c.decodeIfPresent(String.self, forKey: .releaseType) ?? ""
        packaging = try c.decodeIfPresent(String.self, forKey: .packaging) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? ""
        originalDate = try c.decodeIfPresent(String.self, forKey: .originalDate) ?? ""
        mediaFormat = try c.decodeIfPresent(String.self, forKey: .mediaFormat) ?? ""
        discSubtitle = try c.decodeIfPresent(String.self, forKey: .discSubtitle) ?? ""
        trackNumberLabel = try c.decodeIfPresent(String.self, forKey: .trackNumberLabel) ?? ""
        artistSort = try c.decodeIfPresent(String.self, forKey: .artistSort) ?? ""
        albumArtistSort = try c.decodeIfPresent(String.self, forKey: .albumArtistSort) ?? ""
        workTitle = try c.decodeIfPresent(String.self, forKey: .workTitle) ?? ""
        mbReleaseGroupId = try c.decodeIfPresent(String.self, forKey: .mbReleaseGroupId) ?? ""
        mbReleaseTrackId = try c.decodeIfPresent(String.self, forKey: .mbReleaseTrackId) ?? ""
        releaseSecondaryTypes = try c.decodeIfPresent([String].self, forKey: .releaseSecondaryTypes) ?? []
        isrcs = try c.decodeIfPresent([String].self, forKey: .isrcs) ?? []
        iswcs = try c.decodeIfPresent([String].self, forKey: .iswcs) ?? []
        mbArtistIds = try c.decodeIfPresent([String].self, forKey: .mbArtistIds) ?? []
        mbAlbumArtistIds = try c.decodeIfPresent([String].self, forKey: .mbAlbumArtistIds) ?? []
        mbWorkIds = try c.decodeIfPresent([String].self, forKey: .mbWorkIds) ?? []
        mbGenres = try c.decodeIfPresent([String].self, forKey: .mbGenres) ?? []
        performers = try c.decodeIfPresent([String].self, forKey: .performers) ?? []
        credits = try c.decodeIfPresent([Credit].self, forKey: .credits) ?? []
    }

    nonisolated(unsafe) static let stringFields: [(label: String, path: WritableKeyPath<ExtendedMetadata, String>)] = [
        ("Lyricist", \.lyricist),
        ("Writer", \.writer),
        ("Arranger", \.arranger),
        ("Conductor", \.conductor),
        ("Producer", \.producer),
        ("Engineer", \.engineer),
        ("Mixer", \.mixer),
        ("Remixer", \.remixer),
        ("Label", \.label),
        ("Catalog #", \.catalogNumber),
        ("Barcode", \.barcode),
        ("ASIN", \.asin),
        ("Country", \.releaseCountry),
        ("Status", \.releaseStatus),
        ("Release Type", \.releaseType),
        ("Packaging", \.packaging),
        ("Language", \.language),
        ("Script", \.script),
        ("Release Date", \.releaseDate),
        ("Original Date", \.originalDate),
        ("Media", \.mediaFormat),
        ("Disc Subtitle", \.discSubtitle),
        ("Track Label", \.trackNumberLabel),
        ("Artist Sort", \.artistSort),
        ("Album Artist Sort", \.albumArtistSort),
        ("Work", \.workTitle),
        ("MusicBrainz Release Group ID", \.mbReleaseGroupId),
        ("MusicBrainz Release Track ID", \.mbReleaseTrackId),
    ]

    nonisolated(unsafe) static let listFields: [(label: String, path: WritableKeyPath<ExtendedMetadata, [String]>)] = [
        ("Secondary Types", \.releaseSecondaryTypes),
        ("ISRC", \.isrcs),
        ("ISWC", \.iswcs),
        ("MusicBrainz Artist IDs", \.mbArtistIds),
        ("MusicBrainz Album Artist IDs", \.mbAlbumArtistIds),
        ("MusicBrainz Work IDs", \.mbWorkIds),
        ("MusicBrainz Genres", \.mbGenres),
        ("Performers", \.performers),
    ]

    /// Non-empty values of `other` replace the ones here; empty values leave them untouched.
    public mutating func merge(_ other: ExtendedMetadata) {
        for f in Self.stringFields where !other[keyPath: f.path].isEmpty { self[keyPath: f.path] = other[keyPath: f.path] }
        for f in Self.listFields where !other[keyPath: f.path].isEmpty { self[keyPath: f.path] = other[keyPath: f.path] }
        if !other.credits.isEmpty { credits = other.credits }
    }

    /// Label/value pairs of all non-empty fields (credits excluded).
    public var displayFields: [(label: String, value: String)] {
        var out: [(String, String)] = []
        for f in Self.stringFields where !self[keyPath: f.path].isEmpty { out.append((f.label, self[keyPath: f.path])) }
        for f in Self.listFields where !self[keyPath: f.path].isEmpty { out.append((f.label, self[keyPath: f.path].joined(separator: "; "))) }
        return out
    }
}
