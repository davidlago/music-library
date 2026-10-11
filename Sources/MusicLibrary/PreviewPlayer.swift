import AVFoundation
import MusicLibraryCore

/// Plays Apple Music preview clips of catalog CDs, one after another. Separate from `Player`: previews never
/// join the play queue, the listening history or Last.fm, and starting one pauses the library's player (and
/// the other way around).
@MainActor @Observable
final class PreviewPlayer {
    private(set) var tracks: [ApplePreviewTrack] = []
    private(set) var current: ApplePreviewTrack?
    private(set) var isPlaying = false
    /// 0…1 through the current clip.
    private(set) var progress: Double = 0
    private(set) var lastError: String?
    /// Called before a clip starts playing.
    @ObservationIgnored var onWillPlay: (@MainActor () -> Void)?

    @ObservationIgnored private let avPlayer = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init() {
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(1, max(0, time.seconds / d))
            }
        }
    }

    func isCurrent(_ track: ApplePreviewTrack) -> Bool { current?.id == track.id }

    /// Plays `tracks` from `startAt`, then the ones after it.
    func play(_ tracks: [ApplePreviewTrack], startAt: Int = 0) {
        self.tracks = tracks.filter { $0.previewURL != nil }
        guard let start = tracks.indices.contains(startAt) ? self.tracks.firstIndex(of: tracks[startAt]) : nil else { return }
        load(start)
    }

    /// Plays or pauses `track`, starting it (and the ones after it in `list`) if it isn't the current one.
    func toggle(_ track: ApplePreviewTrack, in list: [ApplePreviewTrack]) {
        if isCurrent(track) {
            togglePlayPause()
        } else if let i = list.firstIndex(of: track) {
            play(list, startAt: i)
        }
    }

    func togglePlayPause() {
        guard current != nil else { return }
        if isPlaying {
            avPlayer.pause()
        } else {
            onWillPlay?()
            if progress >= 1 { avPlayer.seek(to: .zero) }
            avPlayer.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        guard current != nil else { return }
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        statusObservation = nil
        tracks = []
        current = nil
        isPlaying = false
        progress = 0
    }

    private func load(_ index: Int) {
        guard tracks.indices.contains(index), let url = tracks[index].previewURL, ApplePreviewParser.isAppleURL(url) else {
            stop()
            return
        }
        onWillPlay?()
        lastError = nil
        current = tracks[index]
        progress = 0
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipEnded() }
        }
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "unknown error"
            Task { @MainActor in
                guard let self, self.current?.previewURL == url else { return }
                self.lastError = "Couldn't play the preview: \(message)"
                self.clipEnded()
            }
        }
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.play()
        isPlaying = true
    }

    private func clipEnded() {
        if let current, let i = tracks.firstIndex(of: current), i + 1 < tracks.count {
            load(i + 1)
        } else {
            avPlayer.pause()
            isPlaying = false
            progress = 1
        }
    }
}
