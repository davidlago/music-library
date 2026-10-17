import Foundation

/// AccurateRip (accuraterip.com): checksums of other people's rips of the same CD, so a rip can be checked bit for bit
/// without listening to it. A CD is identified by its table of contents; the database lists, per pressing, each
/// track's checksum and how many rips agreed on it. Drives start reading a few samples early or late (their read
/// offset), and macOS doesn't correct for it, so the checksums are searched for over a range of offsets.
///
/// Samples are stereo 16-bit frames packed as one little-endian word: left in the low half, right in the high half.
public enum AccurateRip {
    public static let samplesPerSector = 588
    /// Drive read offsets searched with every checksum, in samples either way. The first track's first five sectors
    /// and the last track's last five aren't checksummed, so offsets this large never need audio from outside the disc.
    public static let maxOffset = 5 * samplesPerSector - 1
    /// How far apart pressings of a CD can hold the same audio, searched with the sector 450 checksums (entries from
    /// before them can only be matched within `maxOffset`). Audio from beyond the disc's ends is taken as silence.
    public static let maxPressingOffset = 20 * samplesPerSector
    /// The sector whose checksum (stored with every newer entry) finds a track's offset.
    static let offsetFindingSector = 450
}

// MARK: Disc identity

/// The disc's AccurateRip identity: two sums over its audio tracks' starts and the freedb ID.
public struct AccurateRipDisc: Sendable, Equatable {
    public let trackCount: Int
    public let id1: UInt32
    public let id2: UInt32
    public let freedbID: UInt32

    /// Discs with a data track after the audio (CD Extra) may be listed under other IDs; they then aren't found.
    public init(toc: CDTOC) {
        // Track starts in the TOC include the 150 sectors of lead-in; AccurateRip counts from the first audio sector.
        let audio = toc.audioTracks.map { $0.startBlock - 150 }
        let leadout = toc.leadout - 150
        var id1: UInt32 = 0, id2: UInt32 = 0
        for (i, start) in audio.enumerated() {
            id1 &+= UInt32(truncatingIfNeeded: start)
            id2 &+= UInt32(truncatingIfNeeded: max(start, 1)) &* UInt32(i + 1)
        }
        id1 &+= UInt32(truncatingIfNeeded: leadout)
        id2 &+= UInt32(truncatingIfNeeded: max(leadout, 1)) &* UInt32(audio.count + 1)
        trackCount = audio.count
        self.id1 = id1
        self.id2 = id2
        freedbID = Self.freedbID(toc)
    }

    static func freedbID(_ toc: CDTOC) -> UInt32 {
        func digitSum(_ n: Int) -> Int { String(n).compactMap(\.wholeNumberValue).reduce(0, +) }
        let n = toc.tracks.reduce(0) { $0 + digitSum($1.startBlock / 75) }
        let length = toc.leadout / 75 - (toc.tracks.first?.startBlock ?? 0) / 75
        return UInt32(truncatingIfNeeded: (n % 0xFF) << 24 | length << 8 | toc.tracks.count)
    }

    public var url: URL {
        let name = String(format: "dBAR-%03d-%08x-%08x-%08x.bin", trackCount, id1, id2, freedbID)
        let path = String(format: "%x/%x/%x/", id1 & 0xF, (id1 >> 4) & 0xF, (id1 >> 8) & 0xF)
        return URL(string: "https://www.accuraterip.com/accuraterip/" + path + name)!
    }
}

// MARK: Database

/// One pressing's entry in the database: per track, how many rips agree and their checksums.
public struct AccurateRipPressing: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        public var confidence: Int
        public var checksum: UInt32
        /// The checksum of sector 450 alone, for finding the offset; 0 in entries from before it was added.
        public var sector450: UInt32

        public init(confidence: Int, checksum: UInt32, sector450: UInt32) {
            self.confidence = confidence; self.checksum = checksum; self.sector450 = sector450
        }

        /// Entries for tracks nobody submitted are all zeros.
        var isEmpty: Bool { confidence == 0 || checksum == 0 }
    }

    public var tracks: [Track]

    public init(tracks: [Track]) { self.tracks = tracks }

    /// Parses a `dBAR-….bin` response: per pressing, a 13-byte header (track count, the disc's IDs) and 9 bytes per
    /// track (confidence, checksum, sector 450 checksum), little-endian. Pressings for another disc are skipped.
    public static func parse(_ data: Data, disc: AccurateRipDisc) throws -> [AccurateRipPressing] {
        let bytes = [UInt8](data)
        func word(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        var pressings: [AccurateRipPressing] = []
        var i = 0
        while i < bytes.count {
            guard i + 13 <= bytes.count else { throw AccurateRipError.malformedResponse }
            let count = Int(bytes[i])
            let matches = count == disc.trackCount && word(i + 1) == disc.id1 && word(i + 5) == disc.id2
            i += 13
            guard i + 9 * count <= bytes.count else { throw AccurateRipError.malformedResponse }
            let tracks = (0..<count).map { k in
                let at = i + 9 * k
                return Track(confidence: Int(bytes[at]), checksum: word(at + 1), sector450: word(at + 5))
            }
            i += 9 * count
            if matches { pressings.append(AccurateRipPressing(tracks: tracks)) }
        }
        return pressings
    }
}

public enum AccurateRipError: Error, LocalizedError {
    case malformedResponse

    public var errorDescription: String? { "AccurateRip sent a response that couldn't be read." }
}

/// Downloads a disc's entry. Nil when AccurateRip doesn't know the disc.
public struct AccurateRipClient: Sendable {
    let get: InfoFetcher.Get

    public init(get: InfoFetcher.Get? = nil) { self.get = get ?? InfoFetcher.download }

    public func pressings(for disc: AccurateRipDisc) async throws -> [AccurateRipPressing]? {
        guard let data = try await get(disc.url) else { return nil }
        let pressings = try AccurateRipPressing.parse(data, disc: disc)
        return pressings.isEmpty ? nil : pressings
    }
}

// MARK: Checksums

/// The checksums of one track's samples, read at a given offset. `samples` holds the track with up to
/// `AccurateRip.maxOffset` samples of the tracks around it: `samples[lead + i]` is the track's sample `i`.
struct AccurateRipTrackAudio {
    let samples: [UInt32]
    /// How many samples of the previous track come first.
    let lead: Int
    let count: Int
    /// Checksummed samples of the track: the first track skips its first five sectors (minus one sample), the last
    /// its last five.
    let from: Int
    let to: Int

    init(samples: [UInt32], lead: Int, count: Int, isFirst: Bool, isLast: Bool) {
        self.samples = samples
        self.lead = lead
        self.count = count
        from = isFirst ? 5 * AccurateRip.samplesPerSector - 1 : 0
        to = isLast ? count - 5 * AccurateRip.samplesPerSector : count
    }

    /// The offsets the audio around the track allows.
    var offsets: ClosedRange<Int>? {
        let low = max(-AccurateRip.maxPressingOffset, -(lead + from))
        let high = min(AccurateRip.maxPressingOffset, samples.count - lead - to)
        return from < to && low <= high ? low...high : nil
    }

    /// The original (v1) checksum at every offset, in one pass: Σ (i + 1) · sample[i + offset] over the checksummed
    /// samples, modulo 2³², updated from one offset to the next with the running sum of the samples.
    func v1Checksums(_ range: ClosedRange<Int>) -> [UInt32] {
        samples.withUnsafeBufferPointer { s in
            let base = lead + range.lowerBound
            var crc: UInt32 = 0, sum: UInt32 = 0
            for i in from..<to {
                let x = s[base + i]
                crc &+= x &* UInt32(truncatingIfNeeded: i + 1)
                sum &+= x
            }
            var result = [UInt32](repeating: 0, count: range.count)
            let f = UInt32(truncatingIfNeeded: from), t = UInt32(truncatingIfNeeded: to)
            for k in 0..<range.count {
                result[k] = crc
                guard k + 1 < range.count else { break }
                let first = s[base + k + from], next = s[base + k + to]
                crc = crc &- sum &- f &* first &+ t &* next
                sum = sum &- first &+ next
            }
            return result
        }
    }

    /// Both checksums at one offset: v1 sums the low halves of each 64-bit product, v2 adds the high halves.
    func checksums(at offset: Int) -> (v1: UInt32, v2: UInt32) {
        samples.withUnsafeBufferPointer { s in
            var low: UInt32 = 0, high: UInt32 = 0
            let base = lead + offset
            for i in from..<to {
                let product = UInt64(s[base + i]) &* UInt64(i + 1)
                low &+= UInt32(truncatingIfNeeded: product)
                high &+= UInt32(truncatingIfNeeded: product >> 32)
            }
            return (low, low &+ high)
        }
    }

    /// The checksum of sector 450 alone (Σ (k + 1) · sample[450 · 588 + k + offset]) at every offset, from running
    /// sums; nil when the track is too short.
    func sector450Checksums(_ range: ClosedRange<Int>) -> [UInt32]? {
        let size = AccurateRip.samplesPerSector
        let start = lead + AccurateRip.offsetFindingSector * size + range.lowerBound
        let n = range.count + size
        guard count >= (AccurateRip.offsetFindingSector + 1) * size, start >= 0, start + n <= samples.count else { return nil }
        var sums = [UInt32](repeating: 0, count: n + 1), weighted = [UInt32](repeating: 0, count: n + 1)
        for i in 0..<n {
            let x = samples[start + i]
            sums[i + 1] = sums[i] &+ x
            weighted[i + 1] = weighted[i] &+ x &* UInt32(truncatingIfNeeded: i)
        }
        // Σ over the sector at k of (i − k + 1) · x[i] = Σ i · x[i] − (k − 1) · Σ x[i].
        var result = [UInt32](repeating: 0, count: range.count)
        for k in 0..<range.count {
            let weightedSum: UInt32 = weighted[k + size] &- weighted[k]
            let sum: UInt32 = sums[k + size] &- sums[k]
            let factor = UInt32(truncatingIfNeeded: k - 1)
            result[k] = weightedSum &- factor &* sum
        }
        return result
    }
}

// MARK: Verifying

/// Where the verifier reads a track's samples, as the drive read them: from the ripped files, or the disc.
public protocol AccurateRipAudioSource: Sendable {
    /// Samples `range` of audio track `index` (0-based among the audio tracks); nil when that track can't be read.
    func samples(track index: Int, range: Range<Int>) async throws -> [UInt32]?
}

public struct AccurateRipReport: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Bit for bit the same as `confidence` other rips.
        case accurate(confidence: Int)
        /// Other tracks matched, so the disc is known, but this one doesn't: it was misread.
        case inaccurate
        /// Couldn't tell: nothing submitted for the track, or no track of the rip matched any pressing.
        case unknown
    }

    /// By CD track number.
    public var tracks: [Int: Result]
    /// Where the rip's samples line up with the matching rips, in samples: the drive's read offset, plus the pressing's
    /// when the disc is a pressing with the audio a little earlier or later than the one that matched.
    public var offset: Int?

    public init(tracks: [Int: Result], offset: Int?) { self.tracks = tracks; self.offset = offset }
}

public struct AccurateRipVerifier: Sendable {
    let toc: CDTOC
    let pressings: [AccurateRipPressing]

    public init(toc: CDTOC, pressings: [AccurateRipPressing]) { self.toc = toc; self.pressings = pressings }

    private struct Match { var track: Int; var offset: Int; var confidence: Int }

    /// Checks `trackNumbers` (CD track numbers). `offsetHint` is the drive's offset found earlier for this disc, used
    /// when the rip alone can't establish it (checking one track again).
    public func verify(_ trackNumbers: [Int], audio: AccurateRipAudioSource, offsetHint: Int? = nil) async throws -> AccurateRipReport {
        let tracks = toc.audioTracks
        var matches: [Match] = []
        var loaded: [Int: AccurateRipTrackAudio] = [:]
        for index in tracks.indices where trackNumbers.contains(tracks[index].number) {
            try Task.checkCancellation()
            guard let track = try await load(index, audio: audio), let range = track.offsets else { continue }
            loaded[index] = track
            let entries = pressings.compactMap { $0.tracks.indices.contains(index) ? $0.tracks[index] : nil }.filter { !$0.isEmpty }
            guard !entries.isEmpty else { continue }
            // Drive offsets: v1 checksums at every one.
            let drive = max(range.lowerBound, -AccurateRip.maxOffset)...min(range.upperBound, AccurateRip.maxOffset)
            for (k, crc) in track.v1Checksums(drive).enumerated() {
                for e in entries where e.checksum == crc { matches.append(Match(track: index, offset: drive.lowerBound + k, confidence: e.confidence)) }
            }
            // Newer entries, also from other pressings: candidate offsets from their sector 450 checksum, then the whole
            // track checked there (v2, or v1).
            let withSector450 = entries.filter { $0.sector450 != 0 }
            if !withSector450.isEmpty, let s450 = track.sector450Checksums(range) {
                for (k, crc) in s450.enumerated() {
                    for e in withSector450 where e.sector450 == crc {
                        let offset = range.lowerBound + k, sums = track.checksums(at: offset)
                        if sums.v1 == e.checksum || sums.v2 == e.checksum {
                            matches.append(Match(track: index, offset: offset, confidence: e.confidence))
                        }
                    }
                }
            }
        }
        // The rip's offset: the one most tracks agree on, weighted by confidence.
        var weight: [Int: Int] = [:]
        for (offset, group) in Dictionary(grouping: matches, by: \.offset) {
            weight[offset] = Dictionary(grouping: group, by: \.track).values.map { $0.map(\.confidence).max() ?? 0 }.reduce(0, +)
        }
        let offset = weight.max { $0.value != $1.value ? $0.value < $1.value : abs($0.key) > abs($1.key) }?.key ?? offsetHint
        // Entries without a sector 450 checksum can only be checked at a known offset.
        if let offset {
            for (index, track) in loaded where !matches.contains(where: { $0.track == index }) {
                guard track.offsets?.contains(offset) == true else { continue }
                let sums = track.checksums(at: offset)
                for p in pressings where p.tracks.indices.contains(index) && !p.tracks[index].isEmpty
                    && (p.tracks[index].checksum == sums.v2 || p.tracks[index].checksum == sums.v1) {
                    matches.append(Match(track: index, offset: offset, confidence: p.tracks[index].confidence))
                }
            }
        }
        var results: [Int: AccurateRipReport.Result] = [:]
        for index in tracks.indices where trackNumbers.contains(tracks[index].number) {
            let mine = matches.filter { $0.track == index }
            let best = mine.filter { $0.offset == offset }.map(\.confidence).max() ?? mine.map(\.confidence).max()
            let listed = pressings.contains { $0.tracks.indices.contains(index) && !$0.tracks[index].isEmpty }
            if let best {
                results[tracks[index].number] = .accurate(confidence: best)
            } else if let offset, loaded[index]?.offsets?.contains(offset) == true, listed {
                results[tracks[index].number] = .inaccurate
            } else {
                results[tracks[index].number] = .unknown
            }
        }
        return AccurateRipReport(tracks: results, offset: offset)
    }

    /// Reads a track with the samples around it that offsets reach: the previous track's end and the next one's
    /// start, when they can be read, and silence before the disc's first track and after its last.
    private func load(_ index: Int, audio: AccurateRipAudioSource) async throws -> AccurateRipTrackAudio? {
        let tracks = toc.audioTracks
        let count = toc.sectors(of: tracks[index]) * AccurateRip.samplesPerSector
        guard count > 0, let own = try await audio.samples(track: index, range: 0..<count), own.count == count else { return nil }
        let isFirst = index == 0, isLast = index == tracks.count - 1
        let reach = AccurateRip.maxPressingOffset
        var before = [UInt32](repeating: 0, count: isFirst ? reach : 0)
        if !isFirst {
            let previous = toc.sectors(of: tracks[index - 1]) * AccurateRip.samplesPerSector
            let n = min(reach, previous)
            before = try await audio.samples(track: index - 1, range: (previous - n)..<previous) ?? []
            if before.count != n { before = [] }
        }
        var after = [UInt32](repeating: 0, count: isLast ? reach : 0)
        if !isLast {
            let next = toc.sectors(of: tracks[index + 1]) * AccurateRip.samplesPerSector
            let n = min(reach, next)
            after = try await audio.samples(track: index + 1, range: 0..<n) ?? []
            if after.count != n { after = [] }
        }
        return AccurateRipTrackAudio(samples: before + own + after, lead: before.count, count: count, isFirst: isFirst, isLast: isLast)
    }
}
