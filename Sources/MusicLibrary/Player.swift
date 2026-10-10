import AVFoundation
import AppKit
import MediaPlayer
import MusicLibraryCore

private struct ImageBox: @unchecked Sendable { let image: NSImage }

@MainActor @Observable
final class Player {
    var queue: [Track] = []
    var index: Int?
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
    /// Called when playback stops for good: the queue ran out or the player was stopped.
    @ObservationIgnored var onPlaybackEnded: (@MainActor () -> Void)?
    /// The queue ran out; pressing play again starts the last track over as a new play.
    @ObservationIgnored private var finishedQueue = false
    @ObservationIgnored let matcher: OutputMatcher
    @ObservationIgnored private var loadGeneration = 0

    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var currentTrack: Track? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

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

    func play(queue: [Track], startAt: Int) {
        guard queue.indices.contains(startAt) else { return }
        self.queue = queue
        load(index: startAt)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if let index { queue.insert(contentsOf: tracks, at: index + 1) } else { play(queue: tracks, startAt: 0) }
    }

    func stop() {
        onPlaybackEnded?()
        finishedQueue = false
        loadGeneration += 1
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        queue = []; index = nil; isPlaying = false; currentTime = 0; duration = 0; cover = nil; outputState = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func load(index newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        let track = queue[newIndex]
        let url = track.fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "File missing: \(track.path)"
            if newIndex + 1 < queue.count { load(index: newIndex + 1) } else { isPlaying = false }
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
        if isPlaying { avPlayer.play() }
        updateNowPlaying()
        if let track = currentTrack { onTrackStart?(track) }
    }

    private func loadCover(for track: Track) {
        let coverURL = track.albumDirectory(root: root).appendingPathComponent("cover.jpg")
        cover = NSImage(contentsOf: coverURL)
        updateNowPlaying()
    }

    private func trackEnded() {
        if let index, index + 1 < queue.count {
            load(index: index + 1)
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
        if isPlaying { avPlayer.pause() } else { avPlayer.play() }
        isPlaying.toggle()
        updateNowPlaying()
        if isPlaying && finishedQueue {
            finishedQueue = false
            onTrackStart?(track)
        }
    }

    func next() {
        guard let index, index + 1 < queue.count else { return }
        load(index: index + 1)
    }

    func previous() {
        guard let index else { return }
        if currentTime > 3 || index == 0 { seek(to: 0) } else { load(index: index - 1) }
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
