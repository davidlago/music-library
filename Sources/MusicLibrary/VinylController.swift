import AVFoundation
import CoreAudio
import Foundation
import MusicLibraryCore

/// Digitize Vinyl (sidebar ▸ Import): records a record from an input, then cuts the recording into the album's
/// tracks and saves them as FLAC, like a CD's rip. One recording at a time, kept in Application Support with its
/// cuts (`VinylSession`) until it's discarded, so it survives quitting; it can hold some of the album's songs and a
/// later one the rest.
@MainActor @Observable
final class VinylController {
    enum RecordState: Equatable { case idle, monitoring, recording, paused }

    @ObservationIgnored private unowned let model: AppModel

    /// The record being digitized (the page's choice; a recording belongs to its session's item).
    var itemID: String? {
        didSet { if itemID != oldValue { loadRelease() } }
    }

    // Input
    var devices: [AudioInputDevice] = []
    var deviceUID: String? {
        didSet { UserDefaults.standard.set(deviceUID, forKey: Keys.device); if deviceUID != oldValue { fitSettings() } }
    }
    var sampleRate: Int { didSet { UserDefaults.standard.set(sampleRate, forKey: Keys.rate) } }
    var bitDepth: Int { didSet { UserDefaults.standard.set(bitDepth, forKey: Keys.depth) } }
    var state: RecordState = .idle
    var levels: [Float] = [0, 0]
    var clipped = false
    var microphoneDenied = false
    /// Listen: the input through the default output while it runs (it doesn't change what's recorded).
    var listen: Bool {
        didSet {
            UserDefaults.standard.set(listen, forKey: Keys.listen)
            if listen != oldValue { updateMonitor() }
        }
    }
    var listenVolume: Float {
        didSet {
            UserDefaults.standard.set(listenVolume, forKey: Keys.listenVolume)
            monitor?.volume = listenVolume
        }
    }
    /// What the input actually does, when it differs from what was asked ("The input stays at 48 kHz").
    var inputNote: String?
    var message: String?

    // Recording
    private(set) var session: VinylSession?
    @ObservationIgnored private(set) var recording: VinylRecordingFile?
    private(set) var envelope = VinylEnvelope(sampleRate: 44_100)
    /// The waveform's scale: the loudest peak fills its height (a quiet transfer is still easy to read).
    private(set) var waveformGain: Float = 1
    private(set) var frameCount = 0
    var isOpening = false

    // Editing
    var playhead = 0
    var selectedSegmentID: String?
    private(set) var isPreviewing = false

    // The record's release on MusicBrainz, for naming the tracks.
    private(set) var release: ReleaseInfo?
    private(set) var isLoadingRelease = false
    private(set) var releaseError: String?

    // Saving
    private(set) var isSaving = false
    var statusLine = ""
    /// A record the page was asked to switch to while another one's recording has unsaved cuts.
    var pendingItemID: String?

    @ObservationIgnored private var capture: AudioInputCapture?
    @ObservationIgnored private var monitor: VinylMonitor?
    @ObservationIgnored private let preview = VinylPreview()
    @ObservationIgnored private var previewEnd = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    private enum Keys {
        static let device = "vinylInputUID"
        static let rate = "vinylSampleRate"
        static let depth = "vinylBitDepth"
        static let listen = "vinylListen"
        static let listenVolume = "vinylListenVolume"
    }

    init(model: AppModel) {
        self.model = model
        let defaults = UserDefaults.standard
        deviceUID = defaults.string(forKey: Keys.device)
        sampleRate = defaults.object(forKey: Keys.rate) == nil ? 96_000 : defaults.integer(forKey: Keys.rate)
        bitDepth = VinylFormat.bitDepths.contains(defaults.integer(forKey: Keys.depth)) ? defaults.integer(forKey: Keys.depth) : 24
        listen = defaults.bool(forKey: Keys.listen)
        listenVolume = defaults.object(forKey: Keys.listenVolume) == nil ? 0.8 : min(1, max(0, defaults.float(forKey: Keys.listenVolume)))
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MusicLibrary/Vinyl Recordings", isDirectory: true)
    }

    var item: CollectionItem? { itemID.flatMap { model.item(id: $0) } }
    var duration: Double { session.map { Double(frameCount) / Double($0.format.sampleRate) } ?? 0 }
    var segments: [VinylSegment] { session?.segments ?? [] }
    var isBusy: Bool { state == .recording || state == .paused || isSaving }
    /// The recording has cuts that are named but not saved yet.
    var hasUnsavedCuts: Bool { segments.contains { !$0.isSaved } }
    var device: AudioInputDevice? { devices.first { $0.uid == deviceUID } }

    // MARK: Choosing the record

    /// Digitize This Record…: opens the page on `item`.
    func show(_ item: CollectionItem) {
        model.sidebar = .digitizeVinyl
        choose(item.id)
    }

    /// Picks the record to digitize. A recording of another record with unsaved cuts asks first (`pendingItemID`).
    func choose(_ id: String) {
        guard id != itemID else { return }
        if let session, session.itemID != id {
            guard !isBusy else {
                message = "Stop recording or saving before choosing another record."
                return
            }
            if frameCount > 0 && (hasUnsavedCuts || segments.isEmpty) {
                pendingItemID = id
                return
            }
            discard()
        }
        itemID = id
    }

    /// Discards the recording and goes on to the record that was asked for.
    func confirmSwitch() {
        guard let id = pendingItemID else { return }
        pendingItemID = nil
        discard()
        itemID = id
    }

    // MARK: Input

    func refreshDevices() {
        devices = CoreAudioInput.devices()
        if device == nil { deviceUID = devices.first?.uid }
        fitSettings()
        checkPermission()
    }

    private func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneDenied = status == .denied || status == .restricted
    }

    /// The sample rate and bit depth, kept to what the input can do.
    private func fitSettings() {
        guard let device else { return }
        if !device.sampleRates.isEmpty, !device.sampleRates.contains(sampleRate) {
            sampleRate = device.sampleRates.contains(96_000) ? 96_000
                : device.sampleRates.filter { $0 <= 96_000 }.max() ?? device.sampleRates.max() ?? 44_100
        }
    }

    /// Starts the input (asking for microphone access the first time) for recording or just the level meter.
    private func startCapture() async -> Bool {
        if capture != nil { return true }
        guard let device else {
            message = "Connect the turntable, phono preamp or audio interface you record from."
            return false
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        checkPermission()
        guard !microphoneDenied else { return false }
        var notes: [String] = []
        do { try CoreAudioInput.setSampleRate(device.id, sampleRate) } catch {}
        if !device.bitDepths.isEmpty, !CoreAudioInput.setBitDepth(device.id, bitDepth, rate: sampleRate),
           let best = device.bitDepths.max(), best < bitDepth {
            notes.append("The input delivers \(best)-bit audio; recording at \(bitDepth) bits adds nothing to it.")
        }
        do {
            let c = try AudioInputCapture(device: device.id)
            if c.sampleRate != sampleRate {
                notes.insert("The input stays at \(AudioFormat.kHzString(Double(c.sampleRate))) kHz, so that's the recording's rate.", at: 0)
            }
            if let session, session.format.sampleRate != c.sampleRate || session.format.channels != c.channels {
                c.stop()
                message = "The input now runs at \(AudioFormat.kHzString(Double(c.sampleRate))) kHz; this recording is "
                    + "\(AudioFormat.kHzString(Double(session.format.sampleRate))) kHz. Choose that rate to record more."
                return false
            }
            capture = c
            inputNote = notes.isEmpty ? nil : notes.joined(separator: " ")
            updateMonitor()
            startTimer()
            return true
        } catch {
            message = "The input couldn't be started: \(error.localizedDescription)"
            return false
        }
    }

    private func stopCapture() {
        capture?.listener = nil
        monitor?.stop()
        monitor = nil
        capture?.stop()
        capture = nil
        levels = [0, 0]
    }

    /// The input went away (unplugged) or something changed its sample rate, which the input unit would resample:
    /// recording stops, what was recorded is kept.
    private func checkInput() {
        guard let capture, let device else { return }
        let gone = CoreAudioOutput.deviceID(forUID: device.uid) == nil
        guard gone || CoreAudioInput.sampleRate(capture.device) != capture.sampleRate else { return }
        let wasRecording = state == .recording || state == .paused
        stopCapture()
        state = .idle
        if wasRecording { finishRecording() }
        let what = gone ? "The input was disconnected" : "The input's sample rate was changed (by another app or Audio MIDI Setup)"
        message = wasRecording ? "\(what), so recording stopped. What was recorded is kept; Record goes on from there." : "\(what)."
        refreshDevices()
    }

    /// Starts or stops listening to the running input.
    private func updateMonitor() {
        guard let capture else { return }
        if listen, monitor == nil {
            do {
                let m = try VinylMonitor(sampleRate: capture.sampleRate, channels: capture.channels, volume: listenVolume)
                m.muted = isPreviewing
                monitor = m
                let buffer = m.buffer
                capture.listener = { buffer.push($0) }
            } catch {
                message = "The input can't be played through the output: \(error.localizedDescription)"
            }
        } else if !listen, let m = monitor {
            capture.listener = nil
            m.stop()
            monitor = nil
        }
    }

    /// The default output's name, for the Listen switch.
    var outputName: String {
        (try? CoreAudioOutput.defaultOutputDevice()).map(CoreAudioOutput.name(of:)).flatMap { $0.isEmpty ? nil : $0 } ?? "your speakers"
    }

    /// Check Levels: the meter without recording.
    func toggleMonitoring() {
        if state == .monitoring {
            stopCapture()
            state = .idle
        } else if state == .idle {
            Task {
                if await startCapture() { state = .monitoring }
            }
        }
    }

    func resetClip() { clipped = false }

    // MARK: Recording

    /// Record (a new recording, or more of this one after a stop) or Resume after a pause.
    func record() {
        guard let item, !isSaving else { return }
        message = nil
        stopPreview()
        if state == .paused {
            if let recording, recording.frameCount > 0 { session?.pauses.append(recording.frameCount) }
            capture?.sink = recording
            state = .recording
            persist()
            return
        }
        Task {
            guard await startCapture(), let capture else { return }
            do {
                if recording == nil {
                    let format = VinylFormat(sampleRate: capture.sampleRate, bitDepth: bitDepth, channels: capture.channels)
                    let s = VinylSession(itemID: item.id, libraryRoot: model.libraryRoot.path, format: format,
                                         inputName: device?.name ?? "Input")
                    guard let files = VinylSession.files(id: s.id, in: Self.folder) else { return }
                    recording = try VinylRecordingFile(creating: files.audio, format: format)
                    session = s
                    envelope = VinylEnvelope(sampleRate: format.sampleRate)
                    frameCount = 0
                    playhead = 0
                } else if let recording, recording.frameCount > 0 {
                    session?.pauses.append(recording.frameCount)
                }
                persist()
                capture.sink = recording
                state = .recording
            } catch {
                message = "The recording couldn't be started: \(error.localizedDescription)"
                stopCapture()
                state = .idle
            }
        }
    }

    /// Pause: the input keeps running (the meter too) while nothing is written; Resume goes on in the same
    /// recording with a cut there (turning the record over).
    func pause() {
        guard state == .recording else { return }
        capture?.sink = nil
        state = .paused
        refreshRecording()
        persist()
    }

    /// Stop: the input stops and the recording is ready to cut into tracks.
    func stop() {
        guard state == .recording || state == .paused else { return }
        capture?.sink = nil
        stopCapture()
        state = .idle
        finishRecording()
    }

    private func finishRecording() {
        refreshRecording()
        persist()
        if segments.isEmpty, frameCount > 0 { detectTracks() }
    }

    /// Discard Recording: deletes it and its cuts (songs already saved stay in the library).
    func discard() {
        stopPreview()
        capture?.sink = nil
        if state == .recording || state == .paused { stopCapture(); state = .idle }
        recording?.close()
        if let session, let files = VinylSession.files(id: session.id, in: Self.folder) {
            try? FileManager.default.removeItem(at: files.audio)
            try? FileManager.default.removeItem(at: files.info)
        }
        recording = nil
        session = nil
        frameCount = 0
        envelope = VinylEnvelope(sampleRate: 44_100)
        playhead = 0
        selectedSegmentID = nil
        statusLine = ""
    }

    /// Called when the app quits: what was recorded is written out with its session.
    func finish() {
        capture?.sink = nil
        stopCapture()
        recording?.close()
        persist()
    }

    private func refreshRecording() {
        guard let recording else { return }
        frameCount = recording.frameCount
        envelope = recording.envelope
        waveformGain = 1 / max(0.05, envelope.peaks.max() ?? 1)
    }

    private func persist() {
        guard let session, let files = VinylSession.files(id: session.id, in: Self.folder) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session).write(to: files.info, options: .atomic)
        } catch {
            message = "The recording's cuts couldn't be saved: \(error.localizedDescription)"
        }
    }

    /// When a library is opened: a recording of another library is put away (kept for when it's opened again), and
    /// this one's is brought back.
    func libraryOpened() {
        if let session, session.libraryRoot != model.libraryRoot.path {
            finish()
            recording = nil
            self.session = nil
            frameCount = 0
            itemID = nil
        }
        restore()
    }

    /// The recording kept from last time (of this library), read in the background.
    private func restore() {
        let folder = Self.folder
        let root = model.libraryRoot.path
        guard session == nil, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = names.filter { $0.hasSuffix(".json") }.compactMap { name -> VinylSession? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let s = try? decoder.decode(VinylSession.self, from: data), s.version == VinylSession.currentVersion,
                  s.libraryRoot == root, let files = VinylSession.files(id: s.id, in: folder),
                  FileManager.default.fileExists(atPath: files.audio.path) else { return nil }
            return s
        }
        guard let latest = sessions.max(by: { $0.createdAt < $1.createdAt }), let files = VinylSession.files(id: latest.id, in: folder) else { return }
        isOpening = true
        Task {
            let opened = await Task.detached { try? VinylRecordingFile(opening: files.audio, format: latest.format) }.value
            isOpening = false
            guard let opened, session == nil else { return }
            recording = opened
            session = latest.sanitized(frameCount: opened.frameCount)
            refreshRecording()
            itemID = latest.itemID
        }
    }

    // MARK: Meter and playhead

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        ticks += 1
        if let capture {
            let m = capture.readMeter()
            // Falls back gently, as a meter's needle does.
            levels = (0..<2).map { max(m.peaks[$0], levels[$0] * 0.85) }
            if m.clipped { clipped = true }
            if capture.writeFailed, state == .recording {
                pause()
                message = "The recording couldn't be written to disk (is it full?). Recording is paused; what was recorded is kept."
            }
            if state == .recording, ticks % 8 == 0 { refreshRecording() }
            if ticks % 30 == 0 { checkInput() }
            if state == .recording, let recording { frameCount = recording.frameCount }
        }
        if isPreviewing {
            if let p = preview.position { playhead = min(p, frameCount) }
            if playhead >= previewEnd || !preview.isRunning { stopPreview() }
        }
        if capture == nil, !isPreviewing {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Listening

    /// Plays the recording from `frame` (the playhead), to `end` or its end. The library's player pauses.
    func playPreview(from frame: Int? = nil, to end: Int? = nil) {
        guard let recording, state == .idle || state == .monitoring else { return }
        if model.player.isPlaying { model.player.togglePlayPause() }
        if model.previews.isPlaying { model.previews.togglePlayPause() }
        let start = max(0, min(frame ?? playhead, frameCount - 1))
        previewEnd = min(end ?? frameCount, frameCount)
        do {
            try preview.play(recording, from: start, to: previewEnd)
            playhead = start
            isPreviewing = true
            monitor?.muted = true
            startTimer()
        } catch {
            message = "The recording couldn't be played: \(error.localizedDescription)"
        }
    }

    func stopPreview() {
        guard isPreviewing else { return }
        preview.stop()
        isPreviewing = false
        monitor?.muted = false
    }

    func togglePreview() {
        if isPreviewing { stopPreview() } else { playPreview() }
    }

    /// Moves the playhead (and playing, when it is).
    func seek(to frame: Int) {
        let f = max(0, min(frame, frameCount))
        if isPreviewing { playPreview(from: f) } else { playhead = f }
    }

    /// Plays the last few seconds of a cut, to check where it ends.
    func playEnd(of segment: VinylSegment) {
        guard let rate = session?.format.sampleRate else { return }
        playPreview(from: max(segment.start, segment.end - 5 * rate), to: segment.end)
    }

    // MARK: Cutting

    var minimumLength: Int { (session?.format.sampleRate ?? 44_100) / 2 }

    /// Detect Tracks: replaces the cuts not saved yet with the songs found between gaps (at most `count`), named
    /// after the release's tracks they most likely are.
    func detectTracks(count: Int? = nil) {
        guard let session else { return }
        let saved = session.segments.filter(\.isSaved)
        let found = VinylTrackFinder.tracks(in: envelope, frameCount: frameCount, sampleRate: session.format.sampleRate,
                                            pauses: session.pauses, count: count)
        var fresh: [VinylSegment] = []
        for r in found {
            // Around saved cuts only what's left over.
            var start = r.lowerBound, end = r.upperBound
            for s in saved {
                if s.start <= start && start < s.end { start = s.end }
                if s.start < end && end <= s.end { end = s.start }
            }
            guard end - start >= minimumLength, !saved.contains(where: { $0.start >= start && $0.end <= end }) else { continue }
            fresh.append(VinylSegment(start: start, end: end))
        }
        self.session?.segments = (saved + fresh).sorted { $0.start < $1.start }
        selectedSegmentID = fresh.first?.id
        autoName(fresh.map(\.id))
        persist()
        if found.isEmpty { message = "No songs were found: the recording is silent. Check the input and its level." }
    }

    /// Names cuts after the run of the release's tracks whose lengths are closest (a side, say).
    private func autoName(_ ids: [String]) {
        let cuts = segments.filter { ids.contains($0.id) && $0.target == nil }
        guard !cuts.isEmpty, let rate = session?.format.sampleRate else { return }
        let tracks = targetOptions
        guard !tracks.isEmpty else { return }
        let durations = cuts.map { Double($0.end - $0.start) / Double(rate) }
        guard let k = VinylTrackMatcher.start(for: durations, tracks: tracks.map { ($0.duration, $0.isDone) }) else { return }
        for (j, cut) in cuts.enumerated() where k + j < tracks.count {
            setTarget(cut.id, tracks[k + j].target)
        }
    }

    /// Split at Playhead: cuts the cut there in two, or (between cuts) adds one from there to the next cut, pause
    /// or the end.
    func splitAtPlayhead() {
        guard var session else { return }
        let f = playhead
        if let i = session.segments.firstIndex(where: { $0.start < f && f < $0.end }) {
            let seg = session.segments[i]
            guard !seg.isSaved, f - seg.start >= minimumLength, seg.end - f >= minimumLength else { return }
            session.segments[i].end = f
            let next = VinylSegment(start: f, end: seg.end)
            session.segments.insert(next, at: i + 1)
            selectedSegmentID = next.id
        } else {
            let end = min(session.segments.map(\.start).filter { $0 > f }.min() ?? frameCount,
                          session.pauses.filter { $0 > f + minimumLength }.min() ?? frameCount)
            guard end - f >= minimumLength else { return }
            let seg = VinylSegment(start: f, end: end)
            session.segments.append(seg)
            session.segments.sort { $0.start < $1.start }
            selectedSegmentID = seg.id
        }
        self.session = session
        persist()
    }

    func deleteSegment(_ id: String) {
        guard let i = session?.segments.firstIndex(where: { $0.id == id }), session?.segments[i].isSaved == false else { return }
        session?.segments.remove(at: i)
        if selectedSegmentID == id { selectedSegmentID = nil }
        persist()
    }

    func setTarget(_ id: String, _ target: VinylTarget?) {
        guard let i = session?.segments.firstIndex(where: { $0.id == id }), session?.segments[i].isSaved == false else { return }
        session?.segments[i].target = target
        persist()
    }

    enum Edge { case start, end }

    /// Moves a cut's start or end. A cut that meets the one before or after moves that one's edge too; cuts never
    /// overlap, and saved ones don't change.
    func move(_ id: String, _ edge: Edge, to frame: Int) {
        guard var segs = session?.segments, let i = segs.firstIndex(where: { $0.id == id }), !segs[i].isSaved else { return }
        let min = minimumLength
        switch edge {
        case .start:
            let prev = i > 0 ? segs[i - 1] : nil
            let joined = prev.map { $0.end == segs[i].start && !$0.isSaved } ?? false
            let lo = prev.map { joined ? $0.start + min : $0.end } ?? 0
            let f = Swift.max(lo, Swift.min(frame, segs[i].end - min))
            if joined { segs[i - 1].end = f }
            segs[i].start = f
        case .end:
            let next = i + 1 < segs.count ? segs[i + 1] : nil
            let joined = next.map { $0.start == segs[i].end && !$0.isSaved } ?? false
            let hi = next.map { joined ? $0.end - min : $0.start } ?? frameCount
            let f = Swift.min(hi, Swift.max(frame, segs[i].start + min))
            if joined { segs[i + 1].start = f }
            segs[i].end = f
        }
        session?.segments = segs
    }

    /// After a drag: the cuts as moved are kept.
    func commitMoves() { persist() }

    func segment(at frame: Int) -> VinylSegment? { segments.first { $0.start <= frame && frame < $0.end } }

    // MARK: Tracks

    struct TargetOption: Identifiable, Hashable {
        var target: VinylTarget
        var label: String
        var title: String
        var duration: Double?
        /// Already in the library.
        var isDone: Bool
        var id: VinylTarget { target }
    }

    /// The tracks the cuts can be: the release's, with the ones already in your digital collection marked.
    var targetOptions: [TargetOption] {
        guard let release, let item else { return [] }
        let songs = model.collection.libraryTracks(item)
        return release.tracks.sorted { ($0.discNo, $0.trackNo) < ($1.discNo, $1.trackNo) }.map { t in
            let done = songs.contains { s in
                (!t.recordingId.isEmpty && s.metadata.mbRecordingId == t.recordingId)
                    || ((s.metadata.discNo ?? 1) == t.discNo && s.trackNo == t.trackNo)
            }
            let position = t.numberLabel.isEmpty ? "\(t.trackNo)" : t.numberLabel
            let discs = Set(release.tracks.map(\.discNo)).count
            return TargetOption(target: .release(disc: t.discNo, number: t.trackNo),
                                label: discs > 1 && t.numberLabel.isEmpty ? "\(t.discNo)-\(position)" : position,
                                title: t.title, duration: t.durationSeconds, isDone: done)
        }
    }

    /// The next song number for a cut of a record MusicBrainz doesn't know.
    func nextManualNumber() -> Int {
        let used = segments.compactMap { if case .manual(let n, _) = $0.target { n } else { nil } }
        let library = item.map { model.collection.libraryTracks($0).compactMap(\.trackNo) } ?? []
        return ((used + library).max() ?? 0) + 1
    }

    private func loadRelease() {
        releaseTask?.cancel()
        release = nil
        releaseError = nil
        guard let item, let id = item.releaseID else { return }
        isLoadingRelease = true
        let mb = model.musicBrainz
        releaseTask = Task {
            defer { isLoadingRelease = false }
            do {
                let r = try await mb.fetchRelease(id: id)
                guard !Task.isCancelled, self.itemID == item.id else { return }
                release = r
            } catch is CancellationError {
            } catch {
                releaseError = "The track list couldn't be downloaded from MusicBrainz: \(error.localizedDescription)"
            }
        }
    }

    /// After Change Edition… on the page's record.
    func reloadRelease() { loadRelease() }

    // MARK: Saving

    /// The cuts Save would save: named and not saved yet, and not a track already in the library.
    var cutsToSave: [VinylSegment] {
        let done = Set(targetOptions.filter(\.isDone).map(\.target))
        return segments.filter { seg in
            guard !seg.isSaved, let t = seg.target else { return false }
            if case .manual(_, let title) = t, title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            return !done.contains(t)
        }
    }

    func metadata(for target: VinylTarget) -> TrackMetadata? {
        guard let item else { return nil }
        switch target {
        case .release(let disc, let number):
            guard let release, let t = release.tracks.first(where: { $0.discNo == disc && $0.trackNo == number }) else { return nil }
            var m = TrackMetadata()
            release.apply(t, to: &m)
            return m
        case .manual(let number, let title):
            return .unmatchedDisc(album: item.album, artist: item.artist, title: title, track: number, of: item.trackCount ?? 0)
        }
    }

    /// Save to Library: each cut as a FLAC file in the library, tagged as its track, with the record's cover.
    func save() {
        guard !isSaving, let item, let recording, let service = model.importService else { return }
        let cuts = cutsToSave
        guard !cuts.isEmpty else { return }
        stopPreview()
        isSaving = true
        message = nil
        let importer = VinylImporter(tools: model.tools)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLibrary-Vinyl-\(UUID().uuidString)")
        let release = self.release
        let ownCover = model.coverURL(for: item)
        saveTask = Task {
            var cover = await Task.detached { ownCover.flatMap { try? Data(contentsOf: $0) } }.value
            if cover == nil, let release {
                cover = (try? await model.coverArt.fetchFront(releaseId: release.id, releaseGroupId: release.releaseGroupId)) ?? nil
            }
            var saved = 0, failures: [String] = []
            for (n, cut) in cuts.enumerated() {
                if Task.isCancelled { break }
                guard let target = cut.target, var metadata = metadata(for: target) else { continue }
                metadata.title = metadata.title.isEmpty ? "Track \(metadata.trackNo ?? n + 1)" : metadata.title
                statusLine = "Saving \(n + 1) of \(cuts.count): \(metadata.title)"
                do {
                    let track = try await importer.importSegment(recording, frames: cut.frames, metadata: metadata, cover: cover,
                                                                 service: service, workDir: work)
                    if let i = session?.segments.firstIndex(where: { $0.id == cut.id }) { session?.segments[i].savedTrackID = track.id }
                    persist()
                    link(item.id, track: track)
                    saved += 1
                } catch is CancellationError {
                    break
                } catch ImportError.duplicate {
                    failures.append("\(metadata.title): already in your digital collection")
                } catch {
                    failures.append("\(metadata.title): \(error.localizedDescription)")
                }
            }
            try? FileManager.default.removeItem(at: work)
            if saved > 0 { model.reloadLibrary() }
            isSaving = false
            statusLine = saved > 0 ? "Saved \(saved) \(saved == 1 ? "track" : "tracks") to your digital collection." : ""
            if !failures.isEmpty { message = "Some tracks weren't saved. " + failures.joined(separator: "; ") }
        }
    }

    func cancelSave() { saveTask?.cancel() }

    /// The record is digitized once a track of it is saved: its digital copy is these songs, made from it. Only
    /// when they're under its album key, or it has no music of its own yet.
    private func link(_ id: String, track: Track) {
        guard let current = model.item(id: id), current.medium == .vinyl, current.isEditable else { return }
        let key = SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)
        guard current.albumKey == key || model.collection.libraryTracks(current).isEmpty else { return }
        guard current.albumKey != key || current.digitalSource != .rip else { return }
        model.changeItem(id: id) {
            $0.albumKey = key
            $0.digitalSource = .rip
        }
    }
}

/// Plays the recording from a frame, a half second at a time read from the file, through the default output.
final class VinylPreview: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "local.musiclibrary.vinyl-preview")
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var file: VinylRecordingFile?
    private var next = 0
    private var end = 0
    private var start = 0
    private var generation = 0
    /// Buffers scheduled and not played yet.
    private var outstanding = 0

    init() { engine.attach(node) }

    func play(_ recording: VinylRecordingFile, from frame: Int, to last: Int) throws {
        stop()
        let rate = Double(recording.format.sampleRate), ch = AVAudioChannelCount(recording.format.channels)
        if format?.sampleRate != rate || format?.channelCount != ch {
            guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: ch) else { throw VinylError.invalidFormat }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: f)
            format = f
        }
        if !engine.isRunning { try engine.start() }
        let gen: Int = lock.withLock {
            file = recording
            start = frame
            next = frame
            end = last
            outstanding = 0
            generation += 1
            return generation
        }
        for _ in 0..<3 { scheduleNext(gen) }
        node.play()
    }

    func stop() {
        lock.withLock { generation += 1 }
        node.stop()
    }

    var isRunning: Bool { node.isPlaying && lock.withLock { next < end || outstanding > 0 } }

    /// The frame playing now.
    var position: Int? {
        guard node.isPlaying, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return nil }
        return lock.withLock { start } + Int(p.sampleTime)
    }

    private func scheduleNext(_ gen: Int, played: Bool = false) {
        queue.async { [self] in
            let chunk: (file: VinylRecordingFile, range: Range<Int>)? = lock.withLock {
                guard gen == generation else { return nil }
                if played { outstanding -= 1 }
                guard let file, next < end else { return nil }
                let r = next..<min(end, next + file.format.sampleRate / 2)
                next = r.upperBound
                outstanding += 1
                return (file, r)
            }
            guard let chunk, let format, let samples = try? chunk.file.read(chunk.range),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.range.count)),
                  let out = buffer.floatChannelData else {
                if chunk != nil { lock.withLock { if gen == generation { outstanding -= 1 } } }
                return
            }
            let ch = Int(format.channelCount), frames = samples.count / ch
            buffer.frameLength = AVAudioFrameCount(frames)
            var f = 0
            while f < frames {
                var c = 0
                while c < ch { out[c][f] = samples[f * ch + c]; c += 1 }
                f += 1
            }
            node.scheduleBuffer(buffer) { [weak self] in self?.scheduleNext(gen, played: true) }
        }
    }
}

/// Plays what the input delivers through the default output while recording (`Listen`), from a `MonitorBuffer`
/// pulled by a source node; the mixer converts to the output's rate, and the output device's own rate is never
/// changed (the input's, when it's the same device, stays what the recording needs).
final class VinylMonitor: @unchecked Sendable {
    let buffer: MonitorBuffer
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var _muted = false
    private var observer: NSObjectProtocol?

    init(sampleRate: Int, channels: Int, volume: Float) throws {
        let buffer = MonitorBuffer(channels: channels, sampleRate: sampleRate)
        self.buffer = buffer
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else {
            throw VinylError.invalidFormat
        }
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frames, list in
            let outputs = UnsafeMutableAudioBufferListPointer(list)
            if self?.muted ?? true {
                // What arrives meanwhile is dropped once it's too far behind (`MonitorBuffer`).
                for b in outputs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            } else {
                buffer.pull(frames: Int(frames), into: outputs)
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        try engine.start()
        // A new default output (headphones plugged in, say) stops the engine: go on on the new one.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Silent while the recording itself is played.
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    func stop() { engine.stop() }
}
