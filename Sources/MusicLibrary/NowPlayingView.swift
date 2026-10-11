import MusicLibraryCore
import SwiftUI

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.spring(duration: 0.35)) { model.nowPlayingExpanded = false }
                } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Hide Now Playing")
                Spacer()
                QueueButton()
            }
            .padding(.horizontal, 16).padding(.top, 10)

            GeometryReader { geo in
                Group {
                    if let track = player.currentTrack {
                        content(track: track, size: geo.size)
                            .id(track.id)
                            .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.easeInOut(duration: 0.25), value: player.currentTrack?.id)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)

            VStack(spacing: 14) {
                ScrubberView().frame(maxWidth: 720)
                ZStack {
                    TransportControls(large: true)
                    HStack { Spacer(); VolumeControl() }
                }
                .frame(maxWidth: 720)
                if let err = player.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            }
            .padding(.horizontal, 40).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            theme.background
                .overlay {
                    if let cover = player.cover {
                        Image(nsImage: cover).resizable().scaledToFill().blur(radius: 60).opacity(0.4)
                    }
                }
                .clipped()
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(track: Track, size: CGSize) -> some View {
        let player = model.player
        let m = track.metadata
        if size.width >= 720 {
            let side = max(120, min(size.height, size.width * 0.5, 560))
            HStack(alignment: .top, spacing: 40) {
                cover(player.cover, side: side)
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.title).font(.largeTitle.bold()).lineLimit(2)
                    Text(m.artist).font(.title2).foregroundStyle(.subtext).lineLimit(1)
                    Text(albumLine(m)).font(.title3).foregroundStyle(.subtext).lineLimit(1)
                    FormatCaption(player: player, font: .callout, lineLimit: 2)
                    ScrobbleCaption()
                    ScrollView {
                        details(m).padding(.top, 12)
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(maxWidth: .infinity, maxHeight: side, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            let side = max(120, min(size.width - 80, size.height * 0.5))
            VStack(spacing: 8) {
                cover(player.cover, side: side)
                    .padding(.bottom, 12)
                Text(m.title).font(.title.bold()).lineLimit(2).multilineTextAlignment(.center)
                Text(m.artist).font(.title3).foregroundStyle(.subtext).lineLimit(1)
                Text(albumLine(m)).font(.headline).foregroundStyle(.subtext).lineLimit(1)
                FormatCaption(player: player, font: .callout, lineLimit: 2)
                ScrobbleCaption()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func albumLine(_ m: TrackMetadata) -> String {
        [m.album, m.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func cover(_ image: NSImage?, side: CGFloat) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.system(size: side / 4)).foregroundStyle(.subtext)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    @ViewBuilder
    private func details(_ m: TrackMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !m.albumArtist.isEmpty && m.albumArtist != m.artist { row("Album Artist", m.albumArtist) }
            if !m.composer.isEmpty { PeopleRow(label: "Composer", names: CollaborationGraph.splitNames(m.composer), labelWidth: 120) }
            if !m.genre.isEmpty { row("Genre", m.genre) }
            if let n = m.trackNo { row("Track", m.trackTotal.map { "\(n) of \($0)" } ?? "\(n)") }
            if let d = m.discNo, (m.discTotal ?? 1) > 1 { row("Disc", "\(d) of \(m.discTotal ?? d)") }
            MetadataDetailsView(metadata: m, labelWidth: 120, showsEmptyState: false)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        DetailRow(label: label, value: value, labelWidth: 120)
    }
}

/// Shows whether the current play has been (or will be) scrobbled, when Last.fm is connected.
struct ScrobbleCaption: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scrobbler = model.scrobbler
        if scrobbler.isActive, let track = model.player.currentTrack, track.duration > ListenTracker.minimumDuration {
            Label(scrobbler.currentPlayScrobbled ? "Scrobbled to Last.fm" : "Will scrobble to Last.fm",
                  systemImage: scrobbler.currentPlayScrobbled ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.subtext)
                .help(scrobbler.currentPlayScrobbled ? "" : "After half the song or 4 minutes of listening")
        }
    }
}
