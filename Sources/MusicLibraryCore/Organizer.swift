import Foundation

public struct Organizer: Sendable {
    public static let maxComponentBytes = 120
    public init() {}

    public static func sanitize(_ input: String, maxBytes: Int = maxComponentBytes) -> String {
        var s = ""
        for scalar in input.precomposedStringWithCanonicalMapping.unicodeScalars {
            if "/\\:*?\"<>|".unicodeScalars.contains(scalar) || scalar.properties.generalCategory == .control {
                s.unicodeScalars.append("_")
            } else {
                s.unicodeScalars.append(scalar)
            }
        }
        func clean(_ str: String) -> String {
            var t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasSuffix(".") || t.hasSuffix(" ") { t.removeLast() }
            while t.hasPrefix(".") { t.removeFirst() }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = ""
        var bytes = 0
        for ch in clean(s) {
            let n = String(ch).utf8.count
            if bytes + n > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        return clean(out)
    }

    /// Path relative to the library root, e.g. `Music/Artist/Album (1997)/01 - Title.flac`.
    public static func relativePath(for m: TrackMetadata, sourceStem: String, ext: String) -> String {
        let artistRaw = !m.albumArtist.isEmpty ? m.albumArtist : m.artist
        let artist = sanitize(artistRaw.isEmpty ? "Unknown Artist" : artistRaw)
        var albumName = sanitize(m.album.isEmpty ? "Unknown Album" : m.album)
        if let y = m.year, y > 0 { albumName += " (\(y))" }

        let titleRaw = m.title.isEmpty ? sourceStem : m.title
        let title = sanitize(titleRaw.isEmpty ? "Untitled" : titleRaw, maxBytes: maxComponentBytes - ext.utf8.count - 1 - 7)
        var file = title
        if let n = m.trackNo {
            let nn = String(format: "%02d", n)
            if let d = m.discNo, (m.discTotal ?? 1) > 1 {
                file = "\(d)-\(nn) - \(title)"
            } else {
                file = "\(nn) - \(title)"
            }
        }
        let dir1 = artist.isEmpty ? "Unknown Artist" : artist
        let dir2 = albumName.isEmpty ? "Unknown Album" : albumName
        return "Music/\(dir1)/\(dir2)/\(file).\(ext)"
    }

    /// Appends " (2)", " (3)"... before the extension until `exists` returns false.
    public static func uniquePath(_ relative: String, exists: (String) -> Bool) -> String {
        if !exists(relative) { return relative }
        let ns = relative as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

public struct ParsedFilename: Equatable, Sendable {
    public var trackNo: Int?
    public var artist: String?
    public var title: String
}

public enum FilenameParser {
    public static func parse(stem rawStem: String) -> ParsedFilename {
        var stem = rawStem.trimmingCharacters(in: .whitespaces)
        if !stem.contains(" ") { stem = stem.replacingOccurrences(of: "_", with: " ") }
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) else { return nil }
            return (1..<m.numberOfRanges).map { String(stem[Range(m.range(at: $0), in: stem)!]).trimmingCharacters(in: .whitespaces) }
        }
        if let g = match(#"^(\d{1,3})\s*[-._]\s*(.+?)\s+-\s+(.+)$"#) {
            return ParsedFilename(trackNo: Int(g[0]), artist: g[1], title: g[2])
        }
        if let g = match(#"^(\d{1,3})\s*[-.]\s*(.+)$"#) ?? match(#"^(\d{2})\s+(.+)$"#) {
            return ParsedFilename(trackNo: Int(g[0]), artist: nil, title: g[1])
        }
        if let g = match(#"^(.+?)\s+-\s+(.+)$"#) {
            return ParsedFilename(trackNo: nil, artist: g[0], title: g[1])
        }
        return ParsedFilename(trackNo: nil, artist: nil, title: stem)
    }
}

public enum TextNormalizer {
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

public enum ReleaseMatcher {
    public struct Input: Sendable {
        public var id: String
        public var title: String
        public var trackNo: Int?
        public var discNo: Int?
        public init(id: String, title: String, trackNo: Int?, discNo: Int? = nil) {
            self.id = id; self.title = title; self.trackNo = trackNo; self.discNo = discNo
        }
    }

    /// Matches by normalized title first, then by track number among the remaining items.
    public static func match(_ items: [Input], to release: ReleaseInfo) -> [String: ReleaseTrack] {
        var result: [String: ReleaseTrack] = [:]
        var used = Set<Int>()
        let normalizedTracks = release.tracks.map { TextNormalizer.normalize($0.title) }
        for item in items {
            let n = TextNormalizer.normalize(item.title)
            guard !n.isEmpty else { continue }
            if let idx = normalizedTracks.indices.first(where: { !used.contains($0) && normalizedTracks[$0] == n }) {
                used.insert(idx)
                result[item.id] = release.tracks[idx]
            }
        }
        for item in items where result[item.id] == nil {
            guard let no = item.trackNo else { continue }
            let candidates = release.tracks.indices.filter { !used.contains($0) && release.tracks[$0].trackNo == no
                && (item.discNo == nil || release.tracks[$0].discNo == item.discNo) }
            if candidates.count == 1, let idx = candidates.first {
                used.insert(idx)
                result[item.id] = release.tracks[idx]
            }
        }
        return result
    }
}

public enum AutoMatch {
    public static func isConfident(_ candidate: MatchCandidate, trackDuration: Double, albumHint: String = "") -> Bool {
        let hint = TextNormalizer.normalize(albumHint)
        if !hint.isEmpty, TextNormalizer.normalize(candidate.album) != hint { return false }
        guard candidate.score >= 95, let d = candidate.durationSeconds, trackDuration > 0 else { return false }
        return abs(d - trackDuration) <= 5
    }
}

public enum AlbumGrouping {
    public static func key(for m: TrackMetadata) -> String? {
        let album = TextNormalizer.normalize(m.album)
        guard !album.isEmpty else { return nil }
        let artist = TextNormalizer.normalize(m.albumArtist.isEmpty ? m.artist : m.albumArtist)
        return artist + "|" + album
    }
}

public enum SiblingMatcher {
    /// Finds the release of an already-matched queue entry from the same album that contains this track.
    public static func match(
        tags: TrackMetadata, entryId: String, siblings: [(tags: TrackMetadata, release: ReleaseInfo)]
    ) -> (ReleaseInfo, ReleaseTrack)? {
        guard let key = AlbumGrouping.key(for: tags) else { return nil }
        let input = ReleaseMatcher.Input(id: entryId, title: tags.title, trackNo: tags.trackNo, discNo: tags.discNo)
        for sibling in siblings where AlbumGrouping.key(for: sibling.tags) == key {
            if let track = ReleaseMatcher.match([input], to: sibling.release)[entryId] { return (sibling.release, track) }
        }
        return nil
    }
}
