import CoreAudio
import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct VinylRecordingTests {
    private func sine(frames: Int, channels: Int, amplitude: Float, rate: Int = 48_000) -> [Float] {
        var s = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * 440 * Double(f) / Double(rate)))
            for c in 0..<channels { s[f * channels + c] = c == 0 ? v : -v }
        }
        return s
    }

    @Test func samplesRoundTripAtEachDepth() {
        for bits in VinylFormat.bitDepths {
            let scale = Float(1 << (bits - 1))
            let input: [Float] = [0, 1 / scale, -1 / scale, 0.5, -0.5, -1, (scale - 1) / scale, 0.25]
            let data = input.withUnsafeBufferPointer { VinylRecordingFile.encode($0, bitDepth: bits) }
            #expect(data.count == input.count * bits / 8)
            #expect(VinylRecordingFile.decode(data, bitDepth: bits) == input)
        }
    }

    @Test func louderThanFullScaleIsClipped() {
        let data = [Float(1.5), -2, .nan].withUnsafeBufferPointer { VinylRecordingFile.encode($0, bitDepth: 16) }
        #expect(VinylRecordingFile.decode(data, bitDepth: 16) == [Float(32767) / 32768, -1, 0])
    }

    @Test func appendsReadsAndReopens() throws {
        let dir = try TestSupport.tempDir()
        let format = VinylFormat(sampleRate: 48_000, bitDepth: 24, channels: 2)
        let url = dir.appendingPathComponent("take.pcm")
        let file = try VinylRecordingFile(creating: url, format: format)
        let samples = sine(frames: 48_000, channels: 2, amplitude: 0.5)
        // In buffers that don't line up with the envelope's buckets.
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + 2 * 1234)
            try samples[i..<end].withUnsafeBufferPointer { try file.append(interleaved: $0) }
            i = end
        }
        #expect(file.frameCount == 48_000)
        #expect(file.duration == 1)
        let envelope = file.envelope
        #expect(envelope.peaks.count == 100)
        #expect(abs(envelope.peaks[50] - 0.5) < 0.01)
        #expect(abs(envelope.levels[50] - 0.5 / Float(2).squareRoot()) < 0.01)
        let middle = try file.read(1000..<1010)
        #expect(middle.count == 20)
        for (a, b) in zip(middle, samples[2000..<2020]) { #expect(abs(a - b) < 1e-6) }
        file.close()

        // A partial frame left by a quit mid-write is cut off; appending goes on after the last frame.
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()
        let reopened = try VinylRecordingFile(opening: url, format: format)
        #expect(reopened.frameCount == 48_000)
        // Rebuilt from the stored samples, which are the recorded ones to within a 24-bit step.
        #expect(reopened.envelope.peaks.count == envelope.peaks.count)
        #expect(zip(reopened.envelope.levels, envelope.levels).allSatisfy { abs($0 - $1) < 1e-5 })
        try sine(frames: 480, channels: 2, amplitude: 0.1).withUnsafeBufferPointer { try reopened.append(interleaved: $0) }
        #expect(reopened.frameCount == 48_480)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == 48_480 * 6)
    }

    @Test func savesACutAsLosslessFLAC() async throws {
        let dir = try TestSupport.tempDir()
        let format = VinylFormat(sampleRate: 96_000, bitDepth: 24, channels: 2)
        let file = try VinylRecordingFile(creating: dir.appendingPathComponent("take.pcm"), format: format)
        let samples = sine(frames: 96_000, channels: 2, amplitude: 0.7, rate: 96_000)
        try samples.withUnsafeBufferPointer { try file.append(interleaved: $0) }
        let wav = dir.appendingPathComponent("cut.wav")
        try file.writeWAV(24_000..<72_000, to: wav)
        #expect(try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int == 68 + 48_000 * 6)
        let flac = dir.appendingPathComponent("cut.flac")
        try await TestSupport.ffmpeg(["-i", wav.path, "-c:a", "flac", flac.path])
        let info = try await TagReader(tools: TestSupport.tools).read(flac)
        #expect(info.audio?.codec == "flac")
        #expect(info.audio?.sampleRate == 96_000)
        #expect(info.audio?.bitDepth == 24)
        #expect(abs(info.duration - 0.5) < 0.01)
        // Decoded back, the samples are the recording's.
        let raw = try await TestSupport.ffmpeg(["-i", flac.path, "-f", "s32le", "-c:a", "pcm_s32le", "-"]).stdout
        let decoded = raw.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }.map { Float($0 >> 8) / Float(1 << 23) }
        let expected = try file.read(24_000..<72_000)
        #expect(decoded.count == expected.count)
        #expect(decoded == expected)
    }

    @Test func importsACutIntoTheLibrary() async throws {
        let (root, db, service) = try TestSupport.makeLibrary()
        let format = VinylFormat(sampleRate: 44_100, bitDepth: 16, channels: 2)
        let file = try VinylRecordingFile(creating: root.deletingLastPathComponent().appendingPathComponent("take.pcm"), format: format)
        try sine(frames: 88_200, channels: 2, amplitude: 0.3, rate: 44_100).withUnsafeBufferPointer { try file.append(interleaved: $0) }
        var metadata = TrackMetadata.unmatchedDisc(album: "Blue Train", artist: "John Coltrane", title: "Moment's Notice", track: 2, of: 5)
        metadata.discNo = 1
        let track = try await VinylImporter(tools: TestSupport.tools).importSegment(
            file, frames: 0..<44_100, metadata: metadata, cover: nil, service: service,
            workDir: root.deletingLastPathComponent().appendingPathComponent("work"))
        #expect(track.path == "Music/John Coltrane/Blue Train/02 - Moment's Notice.flac")
        #expect(track.audioFormat?.bitDepth == 16)
        #expect(abs(track.duration - 1) < 0.02)
        #expect(try db.fetchAllTracks().count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.path).path))
    }

    @Test func sessionsAreSanitized() {
        var s = VinylSession(itemID: "x", libraryRoot: "/", format: VinylFormat(sampleRate: 44_100, bitDepth: 16, channels: 2), inputName: "USB")
        s.pauses = [0, 500, 500, 2000, 99]
        s.segments = [VinylSegment(start: 300, end: 900), VinylSegment(start: -5, end: 400), VinylSegment(start: 950, end: 950),
                      VinylSegment(start: 1000, end: 5000)]
        let clean = s.sanitized(frameCount: 1500)
        #expect(clean.pauses == [99, 500])
        #expect(clean.segments.map(\.frames) == [0..<400, 400..<900, 1000..<1500])
        #expect(VinylSession.files(id: "../x", in: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(VinylSession.files(id: s.id, in: URL(fileURLWithPath: "/tmp"))?.audio.lastPathComponent == "\(s.id).pcm")
    }
}

/// Records two seconds from a real input whose name contains `MUSICLIB_LIVE_INPUT` (play something into it first):
/// `MUSICLIB_LIVE_INPUT=Scarlett swift test --filter LiveInputTests`.
@Suite struct LiveInputTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_LIVE_INPUT"] != nil))
    func recordsFromTheInput() async throws {
        let wanted = ProcessInfo.processInfo.environment["MUSICLIB_LIVE_INPUT"] ?? ""
        let device = try #require(CoreAudioInput.devices().first { $0.name.localizedCaseInsensitiveContains(wanted) })
        let capture = try AudioInputCapture(device: device.id)
        let format = VinylFormat(sampleRate: capture.sampleRate, bitDepth: 24, channels: capture.channels)
        let file = try VinylRecordingFile(creating: try TestSupport.tempDir().appendingPathComponent("live.pcm"), format: format)
        capture.sink = file
        // Listening gets a copy of what's recorded.
        let listening = MonitorBuffer(channels: capture.channels, sampleRate: capture.sampleRate)
        capture.listener = { listening.push($0) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        capture.stop()
        let meter = capture.readMeter()
        print("live input: \(device.name), \(capture.sampleRate) Hz, \(device.channels) ch, \(capture.deliveries) deliveries, peaks \(meter.peaks), \(file.frameCount) frames")
        #expect(capture.deliveries > 0)
        #expect(listening.buffered > 0)
        #expect(abs(file.frameCount - 2 * capture.sampleRate) < capture.sampleRate / 4)
        #expect((file.envelope.peaks.max() ?? 0) > 0.001, "silent: is anything playing into the input?")
    }
}

@Suite struct MonitorBufferTests {
    private func pull(_ buffer: MonitorBuffer, _ frames: Int, outputs: Int = 2) -> [[Float]] {
        let list = AudioBufferList.allocate(maximumBuffers: outputs)
        defer { for b in list { b.mData?.deallocate() }; free(list.unsafeMutablePointer) }
        for i in 0..<outputs {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16))
        }
        buffer.pull(frames: frames, into: list)
        return list.map { Array(UnsafeBufferPointer(start: $0.mData!.assumingMemoryBound(to: Float.self), count: frames)) }
    }

    private func push(_ buffer: MonitorBuffer, frames: Range<Int>, channels: Int = 2) {
        var s: [Float] = []
        for f in frames { for c in 0..<channels { s.append(Float(f) + (c == 0 ? 0 : 0.5)) } }
        s.withUnsafeBufferPointer { buffer.push($0) }
    }

    @Test func waitsForTheLatencyThenPlaysInOrder() {
        let b = MonitorBuffer(channels: 2, sampleRate: 1000, latency: 0.1)   // 100 frames
        push(b, frames: 0..<50)
        #expect(pull(b, 10)[0] == Array(repeating: 0, count: 10))
        push(b, frames: 50..<120)
        let out = pull(b, 10)
        #expect(out[0] == (0..<10).map(Float.init))
        #expect(out[1] == (0..<10).map { Float($0) + 0.5 })
        #expect(b.buffered == 110)
    }

    @Test func catchesUpAndRefills() {
        let b = MonitorBuffer(channels: 2, sampleRate: 1000, latency: 0.1)
        // Far ahead of the output: only the latest `latency` is kept.
        push(b, frames: 0..<450)
        #expect(b.buffered == 100)
        #expect(pull(b, 5)[0] == (350..<355).map(Float.init))
        // Running dry plays the rest, then silence until it's filled up again.
        let dry = pull(b, 100)[0]
        #expect(Array(dry[0..<95]) == (355..<450).map(Float.init))
        #expect(Array(dry[95...]) == Array(repeating: 0, count: 5))
        push(b, frames: 450..<500)
        #expect(pull(b, 10)[0] == Array(repeating: 0, count: 10))
    }

    @Test func monoPlaysOnEveryOutput() {
        let b = MonitorBuffer(channels: 1, sampleRate: 1000, latency: 0.1)
        push(b, frames: 0..<100, channels: 1)
        let out = pull(b, 4)
        #expect(out[0] == [0, 1, 2, 3] && out[1] == [0, 1, 2, 3])
    }
}
