import AVFoundation
import AppKit
import MediaPlayer
import MusicLibraryCore

private struct ImageBox: @unchecked Sendable { let image: NSImage }

@MainActor @Observable
final class Player {
    private(set) var queue = PlayQueue()
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Float = 1 { didSet { avPlayer.volume = volume } }
    var cover: NSImage?
    var lastError: String?
    var root: URL
    var outputState: OutputState?
    var matchOutputRate = true
    var matchOutputBitDepth = true
    @ObservationIgnored var formatProvider: (@MainActor (Track) async -> AudioFormat?)?
    /// Called when a track actually starts playing (after any output format change).
    @ObservationIgnored var onTrackStart: (@MainActor (Track) -> Void)?
    /// Called on every playback position update.
    @ObservationIgnored var onProgress: (@MainActor (Track, Double, Bool) -> Void)?
    /// Called before playback starts or resumes (stops a catalog preview).
    @ObservationIgnored var onWillPlay: (@MainActor () -> Void)?
    /// Called when playback stops for good: the queue ran out or the player was stopped.
    @ObservationIgnored var onPlaybackEnded: (@MainActor () -> Void)?
    /// The queue ran out; pressing play again starts the last track over as a new play.
    @ObservationIgnored private var finishedQueue = false
    @ObservationIgnored let matcher: OutputMatcher
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var currentTrack: Track? { queue.current }

    init(root: URL, matcher: OutputMatcher) {
        self.root = root
        self.matcher = matcher
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                if t.isFinite {
                    self.currentTime = t
                    if let track = self.currentTrack { self.onProgress?(track, t, self.isPlaying) }
                }
                if let d = self.avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        setupRemoteCommands()
    }

    /// Plays `tracks` from `startAt`, replacing the queue. `source` names the list ("Next from …").
    func play(queue tracks: [Track], startAt: Int, source: String? = nil) {
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
        if idle && currentTrack != nil { loadCurrent() }
    }

    /// Plays a queue entry now (double-click in the queue).
    func jump(to id: PlayQueue.Entry.ID) {
        if queue.jump(to: id) { loadCurrent() } else if id == queue.currentEntry?.id { seek(to: 0) }
    }

    func removeFromQueue(_ ids: Set<PlayQueue.Entry.ID>) { queue.remove(ids) }
    func clearQueued() { queue.clearQueued() }
    func moveQueued(from offsets: IndexSet, to destination: Int) { queue.moveQueued(from: offsets, to: destination) }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) { queue.moveUpcoming(from: offsets, to: destination) }

    func stop() {
        onPlaybackEnded?()
        finishedQueue = false
        loadGeneration += 1
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        queue.clear(); isPlaying = false; currentTime = 0; duration = 0; cover = nil; outputState = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Starts the queue's current song.
    private func loadCurrent() {
        guard let track = queue.current else { return }
        guard let url = track.resolvedFileURL(root: root), FileManager.default.fileExists(atPath: url.path) else {
            lastError = "File missing: \(track.path)"
            if queue.advance() { loadCurrent() } else { isPlaying = false }
            return
        }
        lastError = nil
        loadGeneration += 1
        let generation = loadGeneration
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isPlaying = true
        currentTime = 0
        duration = track.duration
        loadCover(for: track)
        let matchRate = matchOutputRate
        let matchBits = matchOutputBitDepth
        let matcher = matcher
        Task { [weak self] in
            var state: OutputState?
            if matchRate {
                var format = track.audioFormat
                if format == nil { format = await self?.formatProvider?(track) }
                if let format {
                    state = await Task.detached { matcher.apply(for: format, matchBitDepth: matchBits) }.value
                }
            }
            guard let self, generation == self.loadGeneration else { return }
            self.outputState = state
            self.start(url: url)
        }
    }

    private func start(url: URL) {
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        finishedQueue = false
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.volume = volume
        if isPlaying { onWillPlay?(); avPlayer.play() }
        updateNowPlaying()
        if let track = currentTrack { onTrackStart?(track) }
    }

    /// Reloads the current track's cover, after it was replaced.
    func reloadCover() {
        if let track = currentTrack { loadCover(for: track) }
    }

    private func loadCover(for track: Track) {
        cover = track.coverURL(root: root).flatMap { NSImage(contentsOf: $0) }
        updateNowPlaying()
    }

    private func trackEnded() {
        if queue.advance() {
            loadCurrent()
        } else {
            isPlaying = false
            avPlayer.seek(to: .zero)
            currentTime = 0
            updateNowPlaying()
            finishedQueue = true
            onPlaybackEnded?()
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        // Songs queued after the queue ran out play instead of the last song again.
        if !isPlaying && finishedQueue && queue.advance() {
            loadCurrent()
            return
        }
        if isPlaying { avPlayer.pause() } else { onWillPlay?(); avPlayer.play() }
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
        avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = cover {
            info[MPMediaItemPropertyArtwork] = Self.artwork(ImageBox(image: image))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
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
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayPause() } }
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
