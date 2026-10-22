import Foundation

// Digitizing a record: one continuous recording of it (a side, both sides, or a few songs), cut into tracks that
// are each saved as a FLAC file in the library like a CD's rip. A session can save some of the album's tracks
// and a later one the rest.

/// How a recording is stored: packed little-endian signed integers, channels interleaved, as WAV holds them.
public struct VinylFormat: Codable, Hashable, Sendable {
    public var sampleRate: Int
    /// 16 or 24.
    public var bitDepth: Int
    /// 1 or 2: the input's first two channels.
    public var channels: Int

    public static let bitDepths = [16, 24]

    public init(sampleRate: Int, bitDepth: Int, channels: Int) {
        self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channels = channels
    }

    public var bytesPerSample: Int { bitDepth / 8 }
    public var bytesPerFrame: Int { bytesPerSample * channels }
    public var isValid: Bool {
        (8000...768_000).contains(sampleRate) && Self.bitDepths.contains(bitDepth) && (1...2).contains(channels)
    }

    /// "24-bit / 96 kHz".
    public var summary: String { "\(bitDepth)-bit / \(AudioFormat.kHzString(Double(sampleRate))) kHz" }

    /// Bytes a minute of recording takes.
    public var bytesPerMinute: Int { bytesPerFrame * sampleRate * 60 }
}

/// The recording's loudness over time, for drawing it and finding the gaps between songs: per bucket of
/// `framesPerBucket` frames (a hundredth of a second), the peak and the RMS level of its loudest channel (0…1).
public struct VinylEnvelope: Sendable, Equatable {
    public static let bucketsPerSecond = 100

    public var framesPerBucket: Int
    public var peaks: [Float] = []
    public var levels: [Float] = []

    public init(sampleRate: Int) { framesPerBucket = max(1, sampleRate / Self.bucketsPerSecond) }

    public init(framesPerBucket: Int, peaks: [Float], levels: [Float]) {
        self.framesPerBucket = max(1, framesPerBucket); self.peaks = peaks; self.levels = levels
    }

    /// The largest peak of the buckets covering frames `range`, for drawing one pixel.
    public func peak(frames range: Range<Int>) -> Float {
        let lo = max(0, range.lowerBound / framesPerBucket), hi = min(peaks.count, (range.upperBound + framesPerBucket - 1) / framesPerBucket)
        guard lo < hi else { return 0 }
        var m: Float = 0
        var i = lo
        while i < hi {
            if peaks[i] > m { m = peaks[i] }
            i += 1
        }
        return m
    }
}

/// Adds samples to an envelope a bucket at a time, carrying a bucket that isn't full yet across appends.
struct VinylEnvelopeBuilder {
    private(set) var envelope: VinylEnvelope
    private let channels: Int
    private var peak: Float = 0
    private var squares: [Double]
    private var count = 0

    init(format: VinylFormat) {
        envelope = VinylEnvelope(sampleRate: format.sampleRate)
        channels = format.channels
        squares = Array(repeating: 0, count: format.channels)
    }

    /// `samples` interleaved, -1…1.
    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        var f = 0
        while f < frames {
            var c = 0
            while c < channels {
                let v = samples[f * channels + c]
                let a = abs(v)
                if a > peak { peak = a }
                squares[c] += Double(v) * Double(v)
                c += 1
            }
            count += 1
            if count == envelope.framesPerBucket { close() }
            f += 1
        }
    }

    private mutating func close() {
        envelope.peaks.append(min(peak, 1))
        envelope.levels.append(Float((squares.max() ?? 0) / Double(max(count, 1))).squareRoot())
        peak = 0
        for c in squares.indices { squares[c] = 0 }
        count = 0
    }

    /// The envelope including the bucket in progress.
    var current: VinylEnvelope {
        guard count > 0 else { return envelope }
        var e = envelope
        e.peaks.append(min(peak, 1))
        e.levels.append(Float((squares.max() ?? 0) / Double(count)).squareRoot())
        return e
    }
}

public enum VinylError: Error, LocalizedError {
    case invalidFormat
    case unreadable
    case tooLong
    case noInput

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "The recording's format isn't one the app can save."
        case .unreadable: "The recording couldn't be read."
        case .tooLong: "That track is too long to save as one file."
        case .noInput: "The input has no channels to record from."
        }
    }
}

/// A recording on disk: raw PCM in `format`, appended to while recording (from the audio thread) and read while
/// it's edited. Thread-safe.
public final class VinylRecordingFile: @unchecked Sendable {
    public let url: URL
    public let format: VinylFormat
    private let lock = NSLock()
    private var writer: FileHandle?
    private var frames = 0
    private var builder: VinylEnvelopeBuilder

    /// Starts a new, empty recording at `url` (replacing a file there).
    public init(creating url: URL, format: VinylFormat) throws {
        guard format.isValid else { throw VinylError.invalidFormat }
        self.url = url
        self.format = format
        builder = VinylEnvelopeBuilder(format: format)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        writer = try FileHandle(forWritingTo: url)
    }

    /// Opens a recording made before (reading it once for its envelope; slow for a long one), to append to it or
    /// edit it. A partial frame at the end (the app quit while writing it) is cut off.
    public init(opening url: URL, format: VinylFormat) throws {
        guard format.isValid else { throw VinylError.invalidFormat }
        self.url = url
        self.format = format
        builder = VinylEnvelopeBuilder(format: format)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        frames = size / format.bytesPerFrame
        let handle = try FileHandle(forUpdating: url)
        if size != frames * format.bytesPerFrame { try handle.truncate(atOffset: UInt64(frames * format.bytesPerFrame)) }
        try handle.seekToEnd()
        writer = handle
        let chunk = 1 << 16
        var start = 0
        while start < frames {
            let samples = try read(start..<min(frames, start + chunk))
            samples.withUnsafeBufferPointer { builder.add($0) }
            start += chunk
        }
    }

    deinit { try? writer?.close() }

    public var frameCount: Int { lock.withLock { frames } }
    public var duration: Double { Double(frameCount) / Double(format.sampleRate) }
    public var envelope: VinylEnvelope { lock.withLock { builder.current } }

    /// Appends interleaved samples (-1…1, `format.channels` per frame), converted to the file's bit depth.
    public func append(interleaved samples: UnsafeBufferPointer<Float>) throws {
        let frameCount = samples.count / format.channels
        guard frameCount > 0 else { return }
        let data = Self.encode(UnsafeBufferPointer(rebasing: samples[0..<(frameCount * format.channels)]), bitDepth: format.bitDepth)
        try lock.withLock {
            guard let writer else { throw CocoaError(.fileWriteUnknown) }
            try writer.write(contentsOf: data)
            frames += frameCount
            builder.add(UnsafeBufferPointer(rebasing: samples[0..<(frameCount * format.channels)]))
        }
    }

    /// Stops appending (the file stays for editing; reopen it to append again).
    public func close() {
        lock.withLock {
            try? writer?.synchronize()
            try? writer?.close()
            writer = nil
        }
    }

    /// Frames `range` as interleaved samples, -1…1 (clipped to the recording).
    public func read(_ range: Range<Int>) throws -> [Float] {
        let r = range.clamped(to: 0..<frameCount)
        guard !r.isEmpty else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(r.lowerBound * format.bytesPerFrame))
        guard let data = try handle.read(upToCount: r.count * format.bytesPerFrame) else { throw VinylError.unreadable }
        return Self.decode(data, bitDepth: format.bitDepth)
    }

    /// Writes frames `range` as a WAV file, as recorded (no conversion), for ffmpeg to encode.
    public func writeWAV(_ range: Range<Int>, to destination: URL) throws {
        let r = range.clamped(to: 0..<frameCount)
        let size = r.count * format.bytesPerFrame
        guard size + 80 < Int(UInt32.max) else { throw VinylError.tooLong }
        guard FileManager.default.createFile(atPath: destination.path, contents: VinylWAV.header(format: format, dataSize: size)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.seekToEnd()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(r.lowerBound * format.bytesPerFrame))
        var left = size
        while left > 0 {
            guard let data = try input.read(upToCount: min(left, 1 << 20)), !data.isEmpty else { throw VinylError.unreadable }
            try out.write(contentsOf: data)
            left -= data.count
        }
    }

    // MARK: Samples

    static func encode(_ samples: UnsafeBufferPointer<Float>, bitDepth: Int) -> Data {
        let bytes = bitDepth / 8
        let scale = Float(1 << (bitDepth - 1))
        let lo = -scale, hi = scale - 1
        var data = Data(count: samples.count * bytes)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            var i = 0, o = 0
            while i < samples.count {
                // A 24-bit converter's samples come back exactly; louder than full scale is clipped.
                let x = samples[i].isNaN ? 0 : min(max((samples[i] * scale).rounded(), lo), hi)
                let v = UInt32(bitPattern: Int32(x))
                out[o] = UInt8(truncatingIfNeeded: v)
                out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                if bytes == 3 { out[o + 2] = UInt8(truncatingIfNeeded: v >> 16) }
                i += 1
                o += bytes
            }
        }
        return data
    }

    static func decode(_ data: Data, bitDepth: Int) -> [Float] {
        let bytes = bitDepth / 8
        let scale = Float(1 << (bitDepth - 1))
        let count = data.count / bytes
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0, o = 0
            while i < count {
                var v = Int32(b[o]) | Int32(b[o + 1]) << 8
                if bytes == 3 { v |= Int32(b[o + 2]) << 16; v = (v << 8) >> 8 } else { v = (v << 16) >> 16 }
                result[i] = Float(v) / scale
                i += 1
                o += bytes
            }
        }
        return result
    }
}

enum VinylWAV {
    /// A canonical WAV header (WAVE_FORMAT_EXTENSIBLE for 24-bit, as the format asks for samples over 16 bits).
    static func header(format: VinylFormat, dataSize: Int) -> Data {
        var h = Data()
        func text(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        let extensible = format.bitDepth > 16
        let fmtSize: UInt32 = extensible ? 40 : 16
        text("RIFF"); u32(UInt32(4 + 8 + Int(fmtSize) + 8 + dataSize)); text("WAVE")
        text("fmt "); u32(fmtSize)
        u16(extensible ? 0xFFFE : 1)
        u16(UInt16(format.channels)); u32(UInt32(format.sampleRate))
        u32(UInt32(format.sampleRate * format.bytesPerFrame)); u16(UInt16(format.bytesPerFrame)); u16(UInt16(format.bitDepth))
        if extensible {
            u16(22); u16(UInt16(format.bitDepth)); u32(format.channels == 2 ? 3 : 4)
            // KSDATAFORMAT_SUBTYPE_PCM
            h.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        text("data"); u32(UInt32(dataSize))
        return h
    }
}

// MARK: Session

/// Which of the album's songs a cut of the recording is.
public enum VinylTarget: Codable, Hashable, Sendable {
    /// A track of the record's release on MusicBrainz (its medium and position).
    case release(disc: Int, number: Int)
    /// A record MusicBrainz doesn't know: the song's number on the album and its title.
    case manual(number: Int, title: String)
}

/// One cut of the recording, frames `start..<end`.
public struct VinylSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var start: Int
    public var end: Int
    public var target: VinylTarget?
    /// The library track it was saved as.
    public var savedTrackID: Int64?

    public init(id: String = UUID().uuidString.lowercased(), start: Int, end: Int, target: VinylTarget? = nil, savedTrackID: Int64? = nil) {
        self.id = id; self.start = start; self.end = end; self.target = target; self.savedTrackID = savedTrackID
    }

    public var frames: Range<Int> { start..<max(start, end) }
    public var isSaved: Bool { savedTrackID != nil }
}

/// What's kept next to a recording (`<id>.json` beside `<id>.pcm`), so it can be edited after the app quits.
public struct VinylSession: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var id: String
    public var itemID: String
    public var libraryRoot: String
    public var format: VinylFormat
    public var inputName: String
    public var createdAt: Date
    /// Where recording was paused and went on (the record turned over, say): always a cut between songs.
    public var pauses: [Int] = []
    public var segments: [VinylSegment] = []

    public init(id: String = UUID().uuidString.lowercased(), itemID: String, libraryRoot: String, format: VinylFormat,
                inputName: String, createdAt: Date = Date()) {
        self.id = id; self.itemID = itemID; self.libraryRoot = libraryRoot; self.format = format
        self.inputName = inputName; self.createdAt = createdAt
    }

    /// The sessions folder's files for a session id (nil for an id that isn't a plain name).
    public static func files(id: String, in folder: URL) -> (audio: URL, info: URL)? {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return (folder.appendingPathComponent("\(id).pcm"), folder.appendingPathComponent("\(id).json"))
    }

    /// Cuts kept within the recording's `frameCount` frames, ordered, without overlaps (a later cut starts where
    /// the one before ends) or empty ones; pauses inside it.
    public func sanitized(frameCount: Int) -> VinylSession {
        var s = self
        s.pauses = Array(Set(pauses.filter { $0 > 0 && $0 < frameCount })).sorted()
        var last = 0
        s.segments = segments.sorted { $0.start < $1.start }.compactMap { seg in
            var seg = seg
            seg.start = max(seg.start, last, 0)
            seg.end = min(seg.end, frameCount)
            guard seg.end > seg.start else { return nil }
            last = seg.end
            return seg
        }
        return s
    }
}

// MARK: Finding tracks

/// Finds the songs in a recording from the gaps between them: stretches quieter than the music around them (the
/// record's surface noise) lasting at least `minGap`.
public enum VinylTrackFinder {
    public struct Options: Sendable {
        /// The shortest quiet stretch that is a gap between songs, in seconds.
        public var minGap = 0.8
        /// Sounds shorter than this between gaps (a click, the needle landing) aren't a song.
        public var minTrack = 6.0
        /// Kept before a song's first sound and after its last one (a fade's tail) at the record's ends.
        public var lead = 0.4
        public var tail = 1.5
        public init() {}
    }

    private struct Gap {
        var start: Int, end: Int
        var pause: Int?
        var score: Double
    }

    /// The songs' frame ranges, in order. With `count`, at most that many: the weakest gaps (shortest and least
    /// quiet) are dropped first; a pause is always a cut.
    public static func tracks(in envelope: VinylEnvelope, frameCount: Int, sampleRate: Int, pauses: [Int] = [],
                              count: Int? = nil, options: Options = Options()) -> [Range<Int>] {
        let fpb = envelope.framesPerBucket
        let n = envelope.levels.count
        guard n > 0, frameCount > 0, sampleRate > 0 else { return [] }
        let bucketsPerSecond = Double(sampleRate) / Double(fpb)
        // Levels in dB, smoothed over a fifth of a second.
        let db = envelope.levels.map { 20 * log10(Double(max($0, 1e-6))) }
        let window = max(1, Int(bucketsPerSecond / 5))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + db[i] }
        let smooth = (0..<n).map { i -> Double in
            let lo = max(0, i - window / 2), hi = min(n, i + window / 2 + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
        // The surface noise between songs is far quieter than the music: well below the loud parts, though a
        // noisy pressing's is closer to them. The gaps are a small part of a side, hence the low percentile.
        let sorted = smooth.sorted()
        let floor = sorted[min(n - 1, n / 100)], loud = sorted[min(n - 1, n * 9 / 10)]
        guard loud > -70 else { return [] }
        let spread = loud - floor
        let lenient = count != nil
        let threshold = spread < 10 ? -.infinity
            : max(floor + 6, min(loud - (lenient ? 20 : 28), floor + spread * (lenient ? 0.7 : 0.6)))

        let minGap = max(1, Int(options.minGap * bucketsPerSecond))
        var gaps: [Gap] = []
        var i = 0
        while i < n {
            guard smooth[i] < threshold else { i += 1; continue }
            var j = i
            var depth = 0.0
            while j < n, smooth[j] < threshold { depth += threshold - smooth[j]; j += 1 }
            // Quiet at either end of the recording is always a gap (before the needle drops, after it lifts).
            if j - i >= minGap || i == 0 || j == n { gaps.append(Gap(start: i, end: j, score: depth)) }
            i = j
        }
        // A sound too short to be a song between two gaps joins them.
        let minTrack = Int(options.minTrack * bucketsPerSecond)
        var merged: [Gap] = []
        for g in gaps {
            if var last = merged.last, g.start - last.end < minTrack {
                last.end = g.end
                last.score += g.score
                merged[merged.count - 1] = last
            } else {
                merged.append(g)
            }
        }
        if let first = merged.first, first.start > 0, first.start < minTrack { merged[0].start = 0 }
        if let last = merged.last, last.end < n, n - last.end < minTrack { merged[merged.count - 1].end = n }
        // Pauses: inside a gap they mark it; inside music they're a cut of their own.
        for p in pauses.sorted() where p > 0 && p < frameCount {
            let b = min(n, p / fpb)
            if let k = merged.firstIndex(where: { $0.start <= b && b <= $0.end }) {
                if merged[k].pause == nil { merged[k].pause = p }
            } else {
                merged.append(Gap(start: b, end: b, pause: p, score: .infinity))
            }
        }
        merged.sort { $0.start < $1.start }

        // Music runs between the gaps, each with the gap before it (nil for music from the very start).
        var runs: [(start: Int, end: Int)] = []
        var before: [Gap?] = []
        var cursor = 0
        var previous: Gap?
        for g in merged {
            if g.start > cursor {
                runs.append((cursor, g.start))
                before.append(previous)
                previous = g
            } else if var p = previous {
                // Gaps that touch (a pause at a gap's edge) are one.
                p.end = max(p.end, g.end)
                p.pause = p.pause ?? g.pause
                previous = p
            } else {
                previous = g
            }
            cursor = max(cursor, g.end)
        }
        if cursor < n {
            runs.append((cursor, n))
            before.append(previous)
            previous = nil
        }
        let trailing = previous
        guard !runs.isEmpty else { return [] }

        // Too many songs: join across the weakest gaps that aren't pauses.
        if let count, count > 0 {
            while runs.count > count, let k = (1..<runs.count).filter({ before[$0]?.pause == nil })
                .min(by: { (before[$0]?.score ?? 0) < (before[$1]?.score ?? 0) }) {
                runs[k - 1].end = runs[k].end
                runs.remove(at: k)
                before.remove(at: k)
            }
        }

        let lead = Int(options.lead * Double(sampleRate)), tail = Int(options.tail * Double(sampleRate))
        func frame(_ bucket: Int) -> Int { min(frameCount, bucket * fpb) }
        var result: [Range<Int>] = []
        for (k, run) in runs.enumerated() {
            // Between two songs the cut is in the middle of the gap; at a pause or the recording's ends, the song
            // keeps a little before its first sound and after its last.
            let gapBefore = before[k], gapAfter = k + 1 < runs.count ? before[k + 1] : trailing
            let start: Int, end: Int
            if let p = gapBefore?.pause {
                start = max(p, frame(run.start) - lead)
            } else if k == 0 {
                start = max(0, frame(run.start) - lead)
            } else {
                start = frame((gapBefore!.start + gapBefore!.end) / 2)
            }
            if let p = gapAfter?.pause {
                end = min(p, frame(run.end) + tail)
            } else if k == runs.count - 1 {
                end = min(frameCount, frame(run.end) + tail)
            } else {
                end = frame((gapAfter!.start + gapAfter!.end) / 2)
            }
            // A sound too short for a song next to a pause (the needle landing) is left out.
            if end > start, run.end - run.start >= minTrack || runs.count == 1 { result.append(start..<end) }
        }
        return result
    }
}

/// Which of the album's songs a set of cuts most likely is: the run of consecutive tracks whose lengths are
/// closest to theirs (a side, say), preferring tracks not in the library yet.
public enum VinylTrackMatcher {
    /// The index of the first track of the best run of `durations.count` tracks in `tracks` (lengths in seconds,
    /// nil when unknown; `done` = already in the library). Nil when there are fewer tracks than cuts.
    public static func start(for durations: [Double], tracks: [(duration: Double?, done: Bool)]) -> Int? {
        guard !durations.isEmpty, tracks.count >= durations.count else { return tracks.isEmpty ? nil : 0 }
        var best: (index: Int, score: Double)?
        for k in 0...(tracks.count - durations.count) {
            var score = 0.0
            for (j, d) in durations.enumerated() {
                let t = tracks[k + j]
                // A track of unknown length counts as a fair miss; one already saved costs a little more.
                score += t.duration.map { abs($0 - d) } ?? 20
                if t.done { score += 15 }
            }
            if best == nil || score < best!.score { best = (k, score) }
        }
        return best?.index
    }
}

#if os(macOS)
/// Saves cuts of a recording to the library: as FLAC (from a WAV of the cut, by ffmpeg), imported like a CD's rip.
public struct VinylImporter: Sendable {
    public let tools: ToolLocator
    public init(tools: ToolLocator = ToolLocator()) { self.tools = tools }

    public func importSegment(
        _ recording: VinylRecordingFile, frames: Range<Int>, metadata: TrackMetadata, cover: Data?,
        service: ImportService, workDir: URL
    ) async throws -> Track {
        let ffmpeg = try tools.require("ffmpeg")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let wav = workDir.appendingPathComponent(".\(token).wav")
        let number = metadata.trackNo.map { String(format: "%02d", $0) } ?? "00"
        let flac = workDir.appendingPathComponent("\(number) \(token).flac")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: flac)
        }
        try recording.writeWAV(frames, to: wav)
        try Task.checkCancellation()
        _ = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", wav.path,
                                                 "-map", "0:a:0", "-c:a", "flac", "-compression_level", "8", flac.path])
        try? FileManager.default.removeItem(at: wav)
        try Task.checkCancellation()
        let item = try await service.prepare(flac)
        return try await service.commit(item, metadata: metadata, cover: cover)
    }
}
#endif
