// Reading CD audio for AccurateRip: ripped files are decoded with ffmpeg, the disc's tracks read straight from the
// AIFF files macOS shows for an audio CD. macOS only, like ripping.
#if os(macOS)
import Foundation

/// One of the AIFF files macOS shows for an audio CD's tracks (AIFF-C with little-endian `sowt` samples; plain
/// big-endian AIFF is read too). Only the samples asked for are read, so the start or end of a neighboring track
/// costs a few sectors, not the whole track.
public struct CDTrackAudioFile: Sendable {
    public let url: URL
    let dataStart: UInt64
    let littleEndian: Bool
    public let sampleCount: Int

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        let form = header.count == 12 ? String(decoding: header.suffix(4), as: UTF8.self) : ""
        guard header.prefix(4) == Data("FORM".utf8), form == "AIFF" || form == "AIFC" else {
            throw CDAudioError.unreadable(url.lastPathComponent)
        }
        var littleEndian = false
        func bigEndian(_ d: Data, _ at: Int, _ bytes: Int) -> UInt64 {
            d[(d.startIndex + at)..<(d.startIndex + at + bytes)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        var position: UInt64 = 12
        var format: (channels: UInt64, bits: UInt64)?
        var frames: UInt64?
        while true {
            try handle.seek(toOffset: position)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = bigEndian(chunk, 4, 4)
            if id == "COMM", let comm = try handle.read(upToCount: 22), comm.count >= 8 {
                format = (bigEndian(comm, 0, 2), bigEndian(comm, 6, 2))
                frames = bigEndian(comm, 2, 4)
                // AIFF-C names its encoding after the sample rate: only uncompressed big- or little-endian PCM.
                if form == "AIFC" {
                    guard comm.count == 22 else { break }
                    let compression = String(decoding: comm.suffix(4), as: UTF8.self)
                    guard compression == "NONE" || compression == "sowt" else { break }
                    littleEndian = compression == "sowt"
                }
            } else if id == "SSND", let ssnd = try handle.read(upToCount: 8), ssnd.count == 8, let frames {
                guard format?.channels == 2, format?.bits == 16, frames * 4 + 8 <= size else { break }
                dataStart = position + 16 + bigEndian(ssnd, 0, 4)
                sampleCount = Int(frames)
                self.littleEndian = littleEndian
                self.url = url
                return
            }
            position += 8 + size + (size & 1)
        }
        throw CDAudioError.unreadable(url.lastPathComponent)
    }

    /// Samples `range` as AccurateRip words (left in the low half), from the file's 16-bit stereo frames.
    public func samples(_ range: Range<Int>) throws -> [UInt32]? {
        guard range.lowerBound >= 0, range.upperBound <= sampleCount else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: dataStart + UInt64(range.lowerBound) * 4)
        guard let data = try handle.read(upToCount: range.count * 4), data.count == range.count * 4 else { return nil }
        return words(data)
    }

    /// The whole track, read from the disc again: the system's file cache is bypassed, so each read of a damaged spot
    /// is a new attempt by the drive. Reads in 5-second chunks, reporting progress and stopping when cancelled.
    public func readAll(progress: @Sendable (Double) -> Void = { _ in }) async throws -> [UInt32] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        try handle.seek(toOffset: dataStart)
        let total = sampleCount * 4
        var data = Data()
        data.reserveCapacity(total)
        while data.count < total {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(5 * 75 * AccurateRip.samplesPerSector * 4, total - data.count)), !chunk.isEmpty else {
                throw CDAudioError.unreadable(url.lastPathComponent)
            }
            data.append(chunk)
            progress(Double(data.count) / Double(total))
        }
        return words(data)
    }

    /// 16-bit stereo frames as AccurateRip words (left in the low half).
    private func words(_ data: Data) -> [UInt32] {
        let littleEndian = littleEndian
        return data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return (0..<(data.count / 4)).map { i in
                let p = i * 4
                if littleEndian { return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24 }
                let left = UInt32(b[p]) << 8 | UInt32(b[p + 1]), right = UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
                return left | right << 16
            }
        }
    }
}

public enum CDAudioError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name) isn't CD audio that can be read."
        }
    }
}

public enum PCMDecoder {
    /// All of a file's samples as AccurateRip words, decoded to 16-bit little-endian PCM by ffmpeg. Only for 16-bit
    /// stereo files: anything else would be converted, and its checksums would mean nothing.
    public static func samples(of url: URL, tools: ToolLocator) async throws -> [UInt32] {
        let ffmpeg = try tools.require("ffmpeg")
        let result = try await ProcessRunner.run(ffmpeg, [
            "-nostdin", "-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "s16le", "-c:a", "pcm_s16le", "-",
        ])
        let data = result.stdout
        return data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return (0..<(data.count / 4)).map { i in
                let p = i * 4
                return UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
            }
        }
    }
}

public enum PCMEncoder {
    /// Writes CD audio (AccurateRip words) as a FLAC file like a rip's, through a WAV file ffmpeg reads.
    public static func writeFLAC(_ samples: [UInt32], to url: URL, tools: ToolLocator) async throws {
        let ffmpeg = try tools.require("ffmpeg")
        let wav = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let size = UInt32(samples.count * 4)
        var header = Data()
        func add(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func add32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func add16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        add("RIFF"); add32(36 + size); add("WAVE")
        add("fmt "); add32(16); add16(1); add16(2); add32(44100); add32(44100 * 4); add16(4); add16(16)
        add("data"); add32(size)
        // In memory (little-endian on every Mac) each word is a left/right pair of 16-bit samples, as WAV stores them.
        var file = header
        samples.withUnsafeBytes { file.append(contentsOf: $0) }
        try file.write(to: wav)
        _ = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", wav.path, "-c:a", "flac", "-compression_level", "8", url.path])
    }
}

/// A disc's audio for checking a rip: ripped tracks from their files (decoded once, the last few kept), the
/// others from the disc when it's in the drive, for the samples at the edges of the tracks around a ripped one.
public actor RipAudioSource: AccurateRipAudioSource {
    private let lengths: [Int]
    private let files: [Int: URL]
    private let disc: [Int: URL]
    private let tools: ToolLocator
    private var decoded: [(index: Int, samples: [UInt32])] = []

    /// `files` and `disc` are keyed by the track's index among the disc's audio tracks. A file whose length differs
    /// from its track's on `toc` isn't that track as ripped, and counts as unreadable.
    public init(toc: CDTOC, files: [Int: URL], disc: [Int: URL], tools: ToolLocator) {
        lengths = toc.audioTracks.map { toc.sectors(of: $0) * AccurateRip.samplesPerSector }
        self.files = files
        self.disc = disc
        self.tools = tools
    }

    public func samples(track index: Int, range: Range<Int>) async throws -> [UInt32]? {
        if let url = files[index] {
            let all: [UInt32]
            if let cached = decoded.first(where: { $0.index == index }) {
                all = cached.samples
            } else {
                all = try await PCMDecoder.samples(of: url, tools: tools)
                decoded.append((index, all))
                if decoded.count > 3 { decoded.removeFirst() }
            }
            guard lengths.indices.contains(index), all.count == lengths[index], range.lowerBound >= 0, range.upperBound <= all.count else { return nil }
            return Array(all[range])
        }
        if let url = disc[index] { return try CDTrackAudioFile(url: url).samples(range) }
        return nil
    }
}
#endif
