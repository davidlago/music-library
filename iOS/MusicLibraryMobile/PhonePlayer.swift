import AVFoundation
import MediaPlayer
import MusicLibraryCore
import UIKit

private struct ImageBox: @unchecked Sendable { let image: UIImage }

/// Where audio is going: the route's first output and the rate the hardware runs at.
struct AudioOutput: Equatable, Sendable {
    var name: String
    var isUSB: Bool
    var sampleRate: Double

    nonisolated static func current(_ session: AVAudioSession) -> AudioOutput? {
        guard let port = session.currentRoute.outputs.first else { return nil }
        return AudioOutput(name: port.portName, isUSB: port.portType == .usbAudio, sampleRate: session.sampleRate)
    }
}

/// Plays the queue in the background, with lock screen and Control Center controls. Modeled on the Mac app's
/// `Player`: before each song the output is switched to the song's sample rate (so a USB DAC plays it at its own
/// rate), and the next song is preloaded for a gapless transition when it has the same rate.
@Observable
final class PhonePlayer {
    private enum Keys {
        static let matchSampleRate = "matchSampleRate"
    }

    private(set) var queue = PlayQueue()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var cover: UIImage?
    private(set) var lastError: String?
    private(set) var output: AudioOutput?
    /// The output rate was just changed and the session doesn't report the new one yet.
    private(set) var outputSettling = false
    /// The system volume (0…1); below 1 a USB DAC gets a scaled-down signal.
    private(set) var systemVolume: Float = 1
    var matchSampleRate: Bool {
        didSet {
            UserDefaults.standard.set(matchSampleRate, forKey: Keys.matchSampleRate)
            prepareNext()
        }
    }
    /// Where track paths resolve; set when the library loads.
    var library: LibrarySnapshot?

    /// Called when a song actually starts playing (after any output rate change).
    @ObservationIgnored var onTrackStart: ((Track) -> Void)?
    /// Called on every position update.
    @ObservationIgnored var onProgress: ((Track, Double, Bool) -> Void)?
    /// Called when playback stops for good: the queue ran out.
    @ObservationIgnored var onPlaybackEnded: (() -> Void)?
    /// Called when the song, play/pause or position (a seek) changes: what the lock screen shows.
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private let avPlayer = AVQueuePlayer()
    /// The item playing the queue's current song, and the next song's item when it's preloaded.
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var preloaded: (item: AVPlayerItem, entry: PlayQueue.Entry.ID)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadGeneration = 0
    /// The queue ran out; pressing play again starts the last song over.
    @ObservationIgnored private var finishedQueue = false
    /// The current song was restored at launch and isn't loaded yet: playing it loads it from `currentTime`.
    @ObservationIgnored private var restoredPaused = false
    /// Another app (or a call) took the audio session while this was playing; resume if the system recommends it.
    @ObservationIgnored private var interrupted = false
    /// The sample rate last asked of the session; a different one needs the session reactivated.
    @ObservationIgnored private var requestedRate: Int?

    var currentTrack: Track? { queue.current }

    /// The song after this one.
    var nextTrack: Track? {
        guard let index = queue.index, index + 1 < queue.entries.count else { return nil }
        return queue.entries[index + 1].track
    }

    init() {
        let defaults = UserDefaults.standard
        matchSampleRate = defaults.object(forKey: Keys.matchSampleRate) == nil ? true : defaults.bool(forKey: Keys.matchSampleRate)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeChanged(time) }
        }
        observeItems()
        observeAudioSession()
        setupRemoteCommands()
        output = AudioOutput.current(AVAudioSession.sharedInstance())
    }

    // MARK: Queue

    /// Plays `tracks` from `startAt`, replacing the queue. `source` names the list ("Next from …").
    func play(queue tracks: [Track], startAt: Int = 0, source: String? = nil) {
        guard tracks.indices.contains(startAt) else { return }
        queue.replace(with: tracks, startAt: startAt, source: source)
        loadCurrent()
    }

    /// Queues `tracks` to play right after the current song; plays them if nothing is playing.
    func playNext(_ tracks: [Track]) { enqueue { $0.playNext(tracks) } }

    /// Appends `tracks` to the end of the queue; plays them if nothing is playing.
    func addToQueue(_ tracks: [Track]) { enqueue { $0.addToQueue(tracks) } }

    private func enqueue(_ change: (inout PlayQueue) -> Void) {
        let idle = currentTrack == nil
        change(&queue)
        if idle && currentTrack != nil { loadCurrent() } else { prepareNext(); onStateChange?() }
    }

    func jump(to id: PlayQueue.Entry.ID) {
        if queue.jump(to: id) { loadCurrent() } else if id == queue.currentEntry?.id { seek(to: 0) }
    }

    /// The queue to save when the app goes to the background.
    var snapshot: PlayQueue.Snapshot? { queue.snapshot(position: currentTime) }

    /// Puts back a queue saved earlier, paused where it was. Nothing is loaded (and the output rate isn't
    /// touched) until it's played.
    func restore(_ snapshot: PlayQueue.Snapshot, track: (Int64) -> Track?) {
        guard currentTrack == nil, let position = queue.restore(snapshot, track: track), let current = currentTrack else { return }
        restoredPaused = true
        isPlaying = false
        duration = current.duration
        currentTime = min(position, max(0, current.duration - 1))
        loadCover(for: current)
        updateNowPlaying()
    }

    // MARK: Transport

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if restoredPaused {
            loadCurrent(at: currentTime)
            return
        }
        // Songs queued after the queue ran out play instead of the last song again.
        if !isPlaying && finishedQueue && queue.advance() {
            loadCurrent()
            return
        }
        if isPlaying {
            avPlayer.pause()
        } else {
            avPlayer.play()
        }
        isPlaying.toggle()
        updateNowPlaying()
        if isPlaying && finishedQueue {
            finishedQueue = false
            onTrackStart?(track)
        }
    }

    func next() {
        if queue.advance() { loadCurrent() }
    }

    func previous() {
        guard currentTrack != nil else { return }
        if currentTime > 3 || !queue.goBack() { seek(to: 0) } else { loadCurrent() }
    }

    func seek(to seconds: Double) {
        // Seek the song's own item once it's ready: a seek sent to the queue player can land in the preloaded next
        // song when this one ends first (scrubbing to the very end).
        if !restoredPaused {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let item = currentItem, item.status == .readyToPlay {
                item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            } else {
                avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        currentTime = seconds
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        avPlayer.pause()
        isPlaying = false
        updateNowPlaying()
    }

    // MARK: Loading

    /// Starts the queue's current song from `position` seconds, switching the output rate first.
    private func loadCurrent(at position: Double = 0) {
        restoredPaused = false
        guard let track = queue.current else { return }
        guard let url = fileURL(track) else {
            lastError = "File missing: \(track.path)"
            if queue.advance() { loadCurrent() } else { stopItems(); isPlaying = false; updateNowPlaying() }
            return
        }
        lastError = nil
        finishedQueue = false
        loadGeneration += 1
        let generation = loadGeneration
        stopItems()
        isPlaying = true
        currentTime = position
        duration = track.duration
        loadCover(for: track)
        let rate = matchSampleRate ? track.audioFormat?.sampleRate : nil
        let reactivate = rate != nil && rate != requestedRate
        if let rate { requestedRate = rate }
        outputSettling = reactivate
        Task { [weak self] in
            // Activating the session and changing its rate can block for a moment; keep it off the main thread.
            let error = await Task.detached(priority: .userInitiated) { Self.configureSession(rate: rate, reactivate: reactivate) }.value
            guard let self, generation == self.loadGeneration else { return }
            if let error { self.lastError = "Couldn't set up audio output: \(error)" }
            self.start(url: url, track: track, at: position)
            self.refreshOutput(generation: generation)
        }
    }

    /// Reads the output again once playback has started: right after a rate change the session still reports
    /// the old rate (the DAC itself has switched), so reading it immediately would show the previous song's.
    private func refreshOutput(generation: Int) {
        Task { [weak self] in
            for delay in [0.3, 1.0, 2.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, generation == self.loadGeneration else { return }
                self.output = AudioOutput.current(AVAudioSession.sharedInstance())
                if delay >= 1.0 { self.outputSettling = false }
            }
        }
    }

    private func start(url: URL, track: Track, at position: Double) {
        let item = Self.item(url)
        currentItem = item
        avPlayer.insert(item, after: nil)
        // The new item is the only one queued, so the player's seek (applied once it's ready) can only land in it.
        if position > 0 { avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        if isPlaying { avPlayer.play() }
        currentTime = position
        updateNowPlaying()
        onTrackStart?(track)
        prepareNext()
    }

    private func stopItems() {
        avPlayer.pause()
        avPlayer.removeAllItems()
        currentItem = nil
        preloaded = nil
    }

    /// Preloads the next song behind the current one for a gapless transition, when it plays at the same rate
    /// (a different rate needs the output switched, which takes a short stop).
    private func prepareNext() {
        if let preloaded { avPlayer.remove(preloaded.item) }
        preloaded = nil
        guard let currentItem, let current = currentTrack, let index = queue.index, index + 1 < queue.entries.count else { return }
        let next = queue.entries[index + 1]
        guard !matchSampleRate || next.track.audioFormat?.sampleRate == current.audioFormat?.sampleRate,
              let url = fileURL(next.track) else { return }
        let item = Self.item(url)
        guard avPlayer.canInsert(item, after: currentItem) else { return }
        avPlayer.insert(item, after: currentItem)
        preloaded = (item, next.id)
    }

    /// Without precise timing AVFoundation estimates positions in FLAC files without a seek table, so a seek
    /// lands seconds away from where the clock says and the song runs past its length.
    private static func item(_ url: URL) -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
    }

    private func fileURL(_ track: Track) -> URL? {
        guard let root = library?.root, let url = track.resolvedFileURL(root: root), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func itemEnded(_ item: ObjectIdentifier) {
        guard let currentItem, item == ObjectIdentifier(currentItem) else { return }
        if let preloaded, queue.index.map({ $0 + 1 < queue.entries.count && queue.entries[$0 + 1].id == preloaded.entry }) == true {
            // AVQueuePlayer has moved on to the preloaded song already.
            _ = queue.advance()
            self.currentItem = preloaded.item
            self.preloaded = nil
            guard let track = currentTrack else { return }
            currentTime = 0
            duration = track.duration
            loadCover(for: track)
            updateNowPlaying()
            onTrackStart?(track)
            prepareNext()
        } else if queue.advance() {
            loadCurrent()
        } else {
            isPlaying = false
            avPlayer.seek(to: .zero)
            currentTime = 0
            finishedQueue = true
            updateNowPlaying()
            onPlaybackEnded?()
        }
    }

    private func timeChanged(_ time: CMTime) {
        // Right after a gapless transition the player can report the next item's time before `itemEnded` runs.
        guard let item = avPlayer.currentItem, item === currentItem, let track = currentTrack else { return }
        if time.seconds.isFinite {
            currentTime = time.seconds
            onProgress?(track, time.seconds, isPlaying)
        }
        if item.duration.seconds.isFinite, item.duration.seconds > 0 { duration = item.duration.seconds }
    }

    private func loadCover(for track: Track) {
        cover = library.flatMap { track.coverURL(root: $0.root) }.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    // MARK: Audio session

    /// Activates the playback session, at `rate` when given. With `reactivate` (the rate differs from the last
    /// song's) the session is deactivated first, so the new preferred rate applies on every route; nothing is
    /// playing at that point. The session's `sampleRate` isn't read here: it lags behind the hardware.
    nonisolated private static func configureSession(rate: Int?, reactivate: Bool) -> String? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            if let rate, rate > 0 {
                try session.setPreferredSampleRate(Double(rate))
                if reactivate { try? session.setActive(false) }
            }
            try session.setActive(true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func observeItems() {
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as AnyObject? else { return }
            let id = ObjectIdentifier(item)
            MainActor.assumeIsolated { self?.itemEnded(id) }
        })
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.interrupted = true
                self.isPlaying = false
                self.updateNowPlaying()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            let resume = context?.recommendation == .shouldResume
            MainActor.assumeIsolated {
                guard let self, self.interrupted else { return }
                self.interrupted = false
                if resume && !self.isPlaying { self.togglePlayPause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        })
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { @Sendable [weak self] session, _ in
            let volume = session.outputVolume
            Task { @MainActor in self?.systemVolume = volume }
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        output = AudioOutput.current(AVAudioSession.sharedInstance())
        switch reason {
        case .oldDeviceUnavailable:
            // Unplugging the DAC (or headphones) pauses instead of switching to the speaker.
            pause()
        case .newDeviceAvailable:
            // A DAC plugged in mid-song starts at its own default rate: restart the song at the song's rate.
            if isPlaying, matchSampleRate, currentTrack?.audioFormat?.sampleRate != nil {
                requestedRate = nil
                loadCurrent(at: currentTime)
            }
        default:
            break
        }
    }

    // MARK: Now playing

    private func updateNowPlaying() {
        onStateChange?()
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let cover { info[MPMediaItemPropertyArtwork] = Self.artwork(ImageBox(image: cover)) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer calls the image handler on a background thread.
    nonisolated private static func artwork(_ box: ImageBox) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}
