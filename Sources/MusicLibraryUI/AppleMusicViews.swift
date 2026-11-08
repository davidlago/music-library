import MusicLibraryCore
import SwiftUI

// An album's songs as Apple Music lists them, for the Shop on both apps: tap a song for its 30-second preview (each
// app plays it with its own preview player, apart from the library's), Play Previews for all of them in a row, and
// Open in Apple Music for the album in the Music app.

/// What the track list needs from the app's preview player.
public struct PreviewControls {
    /// The song playing or paused, and whether it's playing.
    public var current: Int?
    public var isPlaying: Bool
    /// How far into the current clip (0…1), when the player reports it.
    public var progress: Double?
    /// Plays, pauses or resumes a song (in the list given, so the next one follows).
    public var toggle: (ApplePreviewTrack, [ApplePreviewTrack]) -> Void

    public init(current: Int?, isPlaying: Bool, progress: Double? = nil, toggle: @escaping (ApplePreviewTrack, [ApplePreviewTrack]) -> Void) {
        self.current = current
        self.isPlaying = isPlaying
        self.progress = progress
        self.toggle = toggle
    }
}

/// "Tracks": the album's songs from Apple Music, each playable as a preview, with Play Previews and Open in Apple Music.
public struct AppleAlbumTracks: View {
    let album: AppleAlbum?
    let loading: Bool
    let controls: PreviewControls

    public init(album: AppleAlbum?, loading: Bool, controls: PreviewControls) {
        self.album = album
        self.loading = loading
        self.controls = controls
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Tracks")
                Spacer()
                buttons
            }
            #else
            SectionHeader(title: "Tracks")
            if album != nil { HStack { buttons } }
            #endif
            list
        }
    }

    @ViewBuilder
    private var buttons: some View {
                if let album, !album.previews.isEmpty {
                    let playingHere = controls.isPlaying && album.tracks.contains { $0.id == controls.current }
                    Button {
                        if let current = album.previews.first(where: { $0.id == controls.current }) ?? album.previews.first {
                            controls.toggle(current, album.previews)
                        }
                    } label: {
                        Label(playingHere ? "Pause" : "Play Previews", systemImage: playingHere ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    #if os(macOS)
                    .help("Play 30-second previews of the songs from Apple Music, one after another")
                    #endif
                }
                if let page = album?.pageURL { OpenInAppleMusicButton(page: page) }
    }

    @ViewBuilder
    private var list: some View {
            if let album {
                VStack(spacing: 0) {
                    let multiDisc = Set(album.tracks.map(\.disc)).count > 1
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                        if multiDisc, i == 0 || album.tracks[i - 1].disc != track.disc {
                            Text("Disc \(track.disc)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, i == 0 ? 8 : 14).padding(.bottom, 2)
                        }
                        AppleTrackRow(track: track, albumArtist: album.artist, controls: controls, queue: album.previews)
                        if i < album.tracks.count - 1 { Divider().padding(.leading, 48).opacity(0.5) }
                    }
                }
                .padding(.vertical, 4)
                .card()
                Text(album.previews.isEmpty ? "Apple Music has no previews of these songs."
                     : "Song previews from Apple Music: \(album.title)\(album.releaseYear.map { " (\($0))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding it on Apple Music…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Apple Music doesn't seem to have this album, so there's no track list or previews.")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }
}

private struct AppleTrackRow: View {
    let track: ApplePreviewTrack
    let albumArtist: String
    let controls: PreviewControls
    let queue: [ApplePreviewTrack]
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        let isCurrent = controls.current == track.id
        let playing = isCurrent && controls.isPlaying
        let canPlay = track.previewURL != nil
        Button {
            if canPlay { controls.toggle(track, queue) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if canPlay, isCurrent || hovering {
                        Image(systemName: playing ? "pause.fill" : "play.fill").foregroundStyle(AppColor.accent)
                    } else {
                        Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1).foregroundStyle(isCurrent ? AppColor.accent : canPlay ? .primary : .secondary)
                    if !track.artist.isEmpty, track.artist != albumArtist {
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let duration = track.duration {
                    Text(Self.time(duration)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .background(alignment: .bottomLeading) {
            if isCurrent, let progress = controls.progress {
                GeometryReader { g in
                    Capsule().fill(AppColor.accent.opacity(0.7))
                        .frame(width: max(0, g.size.width - 28) * progress, height: 2)
                        .offset(x: 14, y: g.size.height - 2)
                }
            }
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        .help(canPlay ? (playing ? "Pause the preview" : "Play a 30-second preview from Apple Music") : "No preview of this song")
        #endif
        .contextMenu {
            if canPlay { Button(playing ? "Pause Preview" : "Play Preview") { controls.toggle(track, queue) } }
            if let page = track.pageURL, let app = AppleMusicLink.appURL(page) {
                Button("Open Song in Apple Music") {
                    openURL(app) { accepted in if !accepted, page.isWebLink { openURL(page) } }
                }
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Opens the album in the Music app (for Apple Music subscribers: it opens on the album, ready to play), falling
/// back to its page on the web when the Music app doesn't take the link.
public struct OpenInAppleMusicButton: View {
    let page: URL
    @Environment(\.openURL) private var openURL

    public init(page: URL) { self.page = page }

    public var body: some View {
        Button {
            guard let app = AppleMusicLink.appURL(page) else { if page.isWebLink { openURL(page) }; return }
            openURL(app) { accepted in if !accepted, page.isWebLink { openURL(page) } }
        } label: {
            Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.bordered)
        #if os(macOS)
        .help("Open the album in the Music app, ready to play")
        #endif
    }
}
