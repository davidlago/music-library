import MusicLibraryCore
import SwiftUI

/// The bar above the tab bar: the current song with play/pause; tapping it opens Now Playing.
struct MiniPlayer: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(url: player.currentTrack.flatMap { t in model.library.flatMap { t.coverURL(root: $0.root) } }, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.currentTrack?.title ?? "Not Playing").font(.subheadline).lineLimit(1)
                if let artist = player.currentTrack?.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 32, height: 32)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(player.currentTrack == nil)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 32, height: 32)
            }
            .accessibilityLabel("Next")
            .disabled(player.currentTrack == nil)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if player.currentTrack != nil { open() } }
    }
}

/// Where the song is going and at what rate: "→ USB Audio · 96 kHz", with a warning when the hardware didn't
/// follow the song's rate and a hint when the system volume scales down what a USB DAC receives.
private struct OutputLine: View {
    let track: Track
    let output: AudioOutput
    /// The rate was just changed and the session may still report the old one.
    let settling: Bool
    let volume: Float

    var body: some View {
        VStack(spacing: 2) {
            Text("→ \(output.name) · \(AudioFormat.kHzString(output.sampleRate)) kHz")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !settling, let rate = track.audioFormat?.sampleRate, abs(output.sampleRate - Double(rate)) > 0.5 {
                Label("Resampled from \(AudioFormat.kHzString(Double(rate))) kHz", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if output.isUSB && volume < 0.99 {
                Text("Turn the iPhone's volume all the way up for bit-perfect output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NowPlayingView: View {
    @Environment(PhonePlayer.self) private var player
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// While the scrubber is dragged, the position it shows (the player seeks when it's let go).
    @State private var scrubbing: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let track = player.currentTrack {
                    ScrollView {
                        VStack(spacing: 20) {
                            nowPlaying(track)
                            upNext
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView("Not Playing", systemImage: "music.note")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.down") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func nowPlaying(_ track: Track) -> some View {
        Group {
            if let cover = player.cover {
                Image(uiImage: cover).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12, y: 6)
        .padding(.horizontal, 12)

        VStack(spacing: 4) {
            Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(track.artist).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(track.album).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let format = track.audioFormat {
                Text(format.compact)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .padding(.top, 4)
            }
            if let output = player.output {
                OutputLine(track: track, output: output, settling: player.outputSettling, volume: player.systemVolume)
            }
        }

        VStack(spacing: 2) {
            let duration = max(player.duration, 1)
            Slider(value: Binding(get: { scrubbing ?? min(player.currentTime, duration) }, set: { scrubbing = $0 }),
                   in: 0...duration) { editing in
                if !editing, let position = scrubbing {
                    player.seek(to: position)
                    scrubbing = nil
                }
            }
            HStack {
                Text(Format.time(scrubbing ?? player.currentTime))
                Spacer()
                Text("-" + Format.time(max(0, player.duration - (scrubbing ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 40) {
            let liked = model.isLiked(track)
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.pink : Color.primary)
            }
            .font(.title2)
            .accessibilityLabel(liked ? "Unlike" : "Like")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
            // Balances the heart, so play/pause stays centered.
            Image(systemName: "heart").font(.title2).hidden()
        }
        .font(.title)
        .buttonStyle(.plain)

        if let error = player.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var upNext: some View {
        let queued = Array(player.queue.queued)
        let upcoming = Array(player.queue.upcoming.prefix(50))
        if !queued.isEmpty || !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !queued.isEmpty {
                    Text("Queue").font(.headline)
                    ForEach(queued) { entry in queueRow(entry) }
                }
                if !upcoming.isEmpty {
                    Text(player.queue.source.map { "Next from \($0)" } ?? "Up Next").font(.headline).padding(.top, 8)
                    ForEach(upcoming) { entry in queueRow(entry) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func queueRow(_ entry: PlayQueue.Entry) -> some View {
        Button { player.jump(to: entry.id) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.track.title).lineLimit(1)
                    Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Format.time(entry.track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
