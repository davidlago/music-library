import MusicLibraryCore
import SwiftUI

struct FormatCaption: View {
    let player: Player
    var font: Font = .caption2
    var lineLimit: Int? = 1

    var body: some View {
        if let format = player.currentTrack?.audioFormat {
            HStack(spacing: 0) {
                Text(format.summary).foregroundStyle(.subtext)
                if let out = player.outputState {
                    Text(" → \(out.summary)")
                        .foregroundStyle(out.matched ? Color.secondary : Color.orange)
                        .help(out.matched ? "" : "Output device doesn't support \(AudioFormat.kHzString(out.sourceRate)) kHz; using \(AudioFormat.kHzString(out.sampleRate)) kHz")
                }
            }
            .font(font).lineLimit(lineLimit)
        }
    }
}

struct ScrubberView: View {
    @Environment(AppModel.self) private var model
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        let player = model.player
        HStack {
            Text(formatTime(scrubbing ? scrubValue : player.currentTime)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { scrubbing ? scrubValue : player.currentTime }, set: { scrubValue = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if editing { scrubbing = true; scrubValue = player.currentTime }
                else { player.seek(to: scrubValue); scrubbing = false }
            }
            .disabled(player.currentTrack == nil)
            Text("-" + formatTime(max(player.duration - (scrubbing ? scrubValue : player.currentTime), 0))).monospacedDigit().font(.caption)
        }
    }
}

struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var large = false

    var body: some View {
        let player = model.player
        HStack(spacing: large ? 28 : 14) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                if large {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.primary))
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.borderless)
        .font(large ? .system(size: 26) : .title2)
        .disabled(player.currentTrack == nil)
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var model
    var width: CGFloat = 90

    var body: some View {
        let player = model.player
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").foregroundStyle(.subtext)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .frame(width: width)
        }
    }
}

/// Shows or hides the queue inspector; from the expanded Now Playing view it also collapses that.
struct QueueButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let shown = model.showsQueue && !model.nowPlayingExpanded
        Button {
            withAnimation(.spring(duration: 0.35)) {
                if model.nowPlayingExpanded {
                    model.nowPlayingExpanded = false
                    model.showsQueue = true
                } else {
                    model.showsQueue.toggle()
                }
            }
        } label: {
            Image(systemName: "list.bullet").font(.title3)
                .foregroundStyle(shown ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.subtext))
        }
        .buttonStyle(.borderless)
        .help(shown ? "Hide Queue" : "Show Queue")
        .accessibilityLabel("Queue")
    }
}

struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let player = model.player
        HStack(spacing: 16) {
            Button {
                withAnimation(.spring(duration: 0.35)) { model.nowPlayingExpanded = true }
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let cover = player.cover {
                            Image(nsImage: cover).resizable().scaledToFill()
                        } else {
                            ZStack { Rectangle().fill(.quaternary); Image(systemName: "music.note").foregroundStyle(.subtext) }
                        }
                    }
                    .frame(width: 48, height: 48)
                    .overlay {
                        if hovering && player.currentTrack != nil {
                            ZStack {
                                Color.black.opacity(0.45)
                                Image(systemName: "chevron.up").font(.headline).foregroundStyle(.white)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Not Playing").font(.headline).lineLimit(1)
                        Text(player.currentTrack?.artist ?? "").font(.subheadline).foregroundStyle(.subtext).lineLimit(1)
                        FormatCaption(player: player)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 320, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
            .help("Show Now Playing")
            .onHover { hovering = $0 }

            TransportControls()
            ScrubberView()
            VolumeControl()
            QueueButton()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.bar)
        .overlay(alignment: .top) {
            if let err = player.lastError { Text(err).font(.caption).foregroundStyle(.red).offset(y: -16) }
        }
    }
}
