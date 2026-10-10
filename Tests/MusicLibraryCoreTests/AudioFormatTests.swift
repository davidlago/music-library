import AVFoundation
import CoreAudio
import Foundation
import SQLite3
import Testing
@testable import MusicLibraryCore

private func discrete(_ rates: Double...) -> [ClosedRange<Double>] { rates.map { $0...$0 } }

@Suite struct OutputFormatChooserTests {
    @Test func exactMatch() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 96000, available: discrete(44100, 48000, 96000)) == 96000)
    }

    @Test func smallestIntegerMultiple() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 44100, available: discrete(48000, 88200, 96000)) == 88200)
        #expect(OutputFormatChooser.chooseSampleRate(source: 44100, available: discrete(48000, 176400, 88200)) == 88200)
    }

    @Test func fallsBackToSmallestHigherRate() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 44100, available: discrete(48000, 96000)) == 48000)
    }

    @Test func largestEvenDivisor() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 192000, available: discrete(44100, 48000, 88200, 96000)) == 96000)
        #expect(OutputFormatChooser.chooseSampleRate(source: 352800, available: discrete(44100, 88200, 96000, 176400)) == 176400)
    }

    @Test func upsamplesLowRates() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 22050, available: discrete(44100, 48000)) == 44100)
    }

    @Test func continuousRange() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 96000, available: [8000...192000]) == 96000)
        #expect(OutputFormatChooser.chooseSampleRate(source: 384000, available: [8000...192000]) == 192000)
    }

    @Test func highestWhenNothingElseFits() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 100000, available: discrete(44100, 48000)) == 48000)
    }

    @Test func emptyIsNil() {
        #expect(OutputFormatChooser.chooseSampleRate(source: 44100, available: []) == nil)
    }

    func fmt(_ bits: Int, _ lo: Double = 44100, _ hi: Double = 192000, float: Bool = false, mixable: Bool = true, pcm: Bool = true) -> PhysicalFormatOption {
        PhysicalFormatOption(minRate: lo, maxRate: hi, bitDepth: bits, isFloat: float, isMixable: mixable, isLinearPCM: pcm)
    }

    @Test func physicalExactDepth() {
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 96000, sourceBits: 24, available: [fmt(16), fmt(24), fmt(32)]) == 1)
    }

    @Test func physicalSmallestLarger() {
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 44100, sourceBits: 16, available: [fmt(32), fmt(24)]) == 1)
    }

    @Test func physicalLargestWhenSourceExceedsAll() {
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 44100, sourceBits: 24, available: [fmt(16)]) == 0)
    }

    @Test func physicalLossyPicksLargest() {
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 44100, sourceBits: nil, available: [fmt(16), fmt(32), fmt(24)]) == 1)
    }

    @Test func physicalPrefersIntegerThenMixable() {
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 48000, sourceBits: 32, available: [fmt(32, float: true), fmt(32)]) == 1)
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 48000, sourceBits: 24, available: [fmt(24, mixable: false), fmt(24)]) == 1)
    }

    @Test func physicalIgnoresFormatsNotCoveringRateOrNotPCM() {
        let options = [fmt(24, 44100, 48000), fmt(24, 96000, 96000, pcm: false), fmt(16, 88200, 192000)]
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 96000, sourceBits: 24, available: options) == 2)
        #expect(OutputFormatChooser.choosePhysicalFormat(rate: 8000, sourceBits: 24, available: options) == nil)
    }
}

@Suite struct AudioFormatSummaryTests {
    @Test func summaries() {
        #expect(AudioFormat(codec: "flac", sampleRate: 96000, bitDepth: 24).summary == "FLAC · 24-bit / 96 kHz")
        #expect(AudioFormat(codec: "flac", sampleRate: 44100, bitDepth: 16).summary == "FLAC · 16-bit / 44.1 kHz")
        #expect(AudioFormat(codec: "mp3", sampleRate: 44100, bitrate: 320_000).summary == "MP3 · 320 kbps / 44.1 kHz")
        #expect(AudioFormat(codec: "flac", sampleRate: 88200, bitDepth: 24).summary == "FLAC · 24-bit / 88.2 kHz")
        #expect(AudioFormat(codec: "flac", sampleRate: 176400, bitDepth: 24).summary == "FLAC · 24-bit / 176.4 kHz")
        #expect(AudioFormat(codec: "flac", sampleRate: 192000, bitDepth: 24).summary == "FLAC · 24-bit / 192 kHz")
        #expect(AudioFormat(codec: "pcm_s24le", sampleRate: 48000, bitDepth: 24).summary == "PCM · 24-bit / 48 kHz")
    }

    @Test func compact() {
        #expect(AudioFormat(codec: "flac", sampleRate: 96000, bitDepth: 24).compact == "FLAC 24/96")
        #expect(AudioFormat(codec: "mp3", sampleRate: 44100, bitrate: 319_800).compact == "MP3 320k")
        #expect(AudioFormat(codec: "flac", sampleRate: 44100, bitDepth: 16).compact == "FLAC 16/44.1")
    }
}

@Suite struct AudioFormatProbeTests {
    func make(_ dir: URL, _ name: String, rate: Int, _ codecArgs: [String]) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        try await TestSupport.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=\(rate)"] + codecArgs + [url.path])
        return url
    }

    @Test func flac24bit96k() async throws {
        let dir = try TestSupport.tempDir()
        let url = try await make(dir, "a.flac", rate: 96000, ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"])
        let a = try #require(try await TagReader().read(url).audio)
        #expect(a.codec == "flac" && a.sampleRate == 96000 && a.bitDepth == 24 && a.channels == 1)
    }

    @Test func flac16bit44k() async throws {
        let dir = try TestSupport.tempDir()
        let url = try await make(dir, "b.flac", rate: 44100, ["-c:a", "flac", "-sample_fmt", "s16"])
        let a = try #require(try await TagReader().read(url).audio)
        #expect(a.sampleRate == 44100 && a.bitDepth == 16)
    }

    @Test func mp3320k() async throws {
        let dir = try TestSupport.tempDir()
        let url = try await make(dir, "c.mp3", rate: 44100, ["-b:a", "320k"])
        let a = try #require(try await TagReader().read(url).audio)
        #expect(a.codec == "mp3" && a.sampleRate == 44100 && a.bitDepth == nil)
        #expect(abs((a.bitrate ?? 0) - 320_000) < 16_000)
    }

    @Test func wav24bit() async throws {
        let dir = try TestSupport.tempDir()
        let url = try await make(dir, "d.wav", rate: 48000, ["-c:a", "pcm_s24le"])
        let a = try #require(try await TagReader().read(url).audio)
        #expect(a.sampleRate == 48000 && a.bitDepth == 24)
    }

    @Test func commitStoresAudioFormat() async throws {
        let (_, db, service) = try TestSupport.makeLibrary()
        let url = try await make(try TestSupport.tempDir(), "e.flac", rate: 96000, ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"])
        let item = try await service.prepare(url)
        let t = try await service.commit(item, metadata: TrackMetadata(title: "T", artist: "A", album: "B"), cover: nil)
        #expect(t.audioFormat?.sampleRate == 96000 && t.audioFormat?.bitDepth == 24)
        #expect(try db.track(id: t.id)?.audioFormat == t.audioFormat)
        #expect(try db.tracksMissingAudioFormat().isEmpty)
    }
}

@Suite struct AudioFormatDatabaseTests {
    @Test func roundTripAndMissing() throws {
        let db = try Database(path: ":memory:")
        let with = AudioFormat(codec: "flac", sampleRate: 44100, bitDepth: 16, bitrate: 900_000, channels: 2)
        let a = try db.insertTrack(Track(path: "a", metadata: TrackMetadata(title: "A"), duration: 1, format: "flac", sha256: "a", audioFormat: with))
        let b = try db.insertTrack(Track(path: "b", metadata: TrackMetadata(title: "B"), duration: 1, format: "mp3", sha256: "b"))
        #expect(try db.track(id: a.id)?.audioFormat == with)
        #expect(try db.tracksMissingAudioFormat().map(\.id) == [b.id])
        let mp3 = AudioFormat(codec: "mp3", sampleRate: 48000, bitrate: 192_000, channels: 2)
        try db.updateAudioFormat(id: b.id, mp3)
        #expect(try db.track(id: b.id)?.audioFormat == mp3)
        #expect(try db.tracksMissingAudioFormat().isEmpty)
        var t = try #require(try db.track(id: a.id))
        t.audioFormat = nil
        try db.updateTrack(t)
        #expect(try db.tracksMissingAudioFormat().count == 1)
    }

    @Test func v3DatabaseMigratesToV4() throws {
        let path = try TestSupport.tempDir().appendingPathComponent("v3.sqlite").path
        var raw: OpaquePointer?
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        let sql = """
        CREATE TABLE tracks(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, title TEXT, artist TEXT, album TEXT, album_artist TEXT,
          year INT, track_no INT, track_total INT, disc_no INT, disc_total INT, genre TEXT, duration REAL, format TEXT,
          mb_recording_id TEXT, mb_release_id TEXT, sha256 TEXT UNIQUE, added_at REAL, search_text TEXT, composer TEXT, details_json TEXT);
        CREATE TABLE playlists(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at REAL);
        CREATE TABLE playlist_tracks(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
          track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, position INT NOT NULL, PRIMARY KEY(playlist_id, position));
        INSERT INTO tracks(path,title,artist,album,sha256,added_at,search_text) VALUES('a.flac','Old','X','Y','sha',0,'old x y');
        PRAGMA user_version=3;
        """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let db = try Database(path: path)
        #expect(try db.query("PRAGMA user_version") { $0.int(0) }.first == Database.schemaVersion)
        let t = try #require(try db.tracksMissingAudioFormat().first)
        #expect(t.title == "Old" && t.audioFormat == nil)
        try db.updateAudioFormat(id: t.id, AudioFormat(codec: "flac", sampleRate: 44100, bitDepth: 16))
        #expect(try db.track(id: t.id)?.audioFormat?.bitDepth == 16)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MUSICLIB_AUDIO_DEVICE_TESTS"] == "1"))
struct AudioDeviceTests {
    @Test func switchPlayAndRestore() async throws {
        let device = try CoreAudioOutput.defaultOutputDevice()
        let name = CoreAudioOutput.name(of: device)
        let rates = try CoreAudioOutput.availableNominalRates(device)
        let stream = try #require(try CoreAudioOutput.outputStreams(device).first)
        let originalRate = try CoreAudioOutput.nominalRate(device)
        let originalPhysical = try CoreAudioOutput.physicalFormat(stream)
        let formats = try CoreAudioOutput.availablePhysicalFormats(stream)
        print("DEVICE \(name): rates=\(rates.map { "\($0.lowerBound)-\($0.upperBound)" })")
        print("DEVICE formats=\(formats.map { "\($0.mFormat.mBitsPerChannel)b@\($0.mSampleRateRange.mMinimum)-\($0.mSampleRateRange.mMaximum)\($0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "i")" })")
        print("DEVICE before: rate=\(originalRate) physical=\(originalPhysical.mSampleRate)/\(originalPhysical.mBitsPerChannel)bit flags=\(originalPhysical.mFormatFlags)")

        let matcher = OutputMatcher()
        defer { matcher.restoreAll() }

        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("hi.flac")
        try await TestSupport.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=96000", "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", url.path])
        let format = try #require(try await TagReader().read(url).audio)
        let state = try #require(matcher.apply(for: format, matchBitDepth: true), "apply failed: \(matcher.lastError ?? "?")")
        let expected = OutputFormatChooser.chooseSampleRate(source: 96000, available: rates) ?? originalRate
        let duringRate = try CoreAudioOutput.nominalRate(device)
        let duringPhysical = try CoreAudioOutput.physicalFormat(stream)
        print("DEVICE during: rate=\(duringRate) physical=\(duringPhysical.mSampleRate)/\(duringPhysical.mBitsPerChannel)bit state=\(state)")
        #expect(abs(duringRate - expected) < 0.5)

        let player = AVPlayer(url: url)
        player.play()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let t = player.currentTime().seconds
        print("DEVICE playback: currentTime=\(t) status=\(player.currentItem?.status.rawValue ?? -1) error=\(String(describing: player.currentItem?.error))")
        #expect(t > 0.5)
        #expect(player.currentItem?.error == nil)
        player.pause()

        matcher.restoreAll()
        let afterRate = try CoreAudioOutput.nominalRate(device)
        let afterPhysical = try CoreAudioOutput.physicalFormat(stream)
        print("DEVICE after: rate=\(afterRate) physical=\(afterPhysical.mSampleRate)/\(afterPhysical.mBitsPerChannel)bit flags=\(afterPhysical.mFormatFlags)")
        #expect(abs(afterRate - originalRate) < 0.5)
        #expect(CoreAudioOutput.matches(afterPhysical, originalPhysical))
    }
}
