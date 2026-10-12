import MusicLibraryGlance
import SwiftUI
import WidgetKit

/// The song playing on the iPhone, with play/pause, previous, next and like buttons on the home screen.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceWidgetKind.nowPlaying.rawValue, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .widgetURL(GlanceLink.nowPlaying.url)
                .widgetBackground()
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing, with controls.")
        .supportedFamilies(Self.families)
        .contentMarginsDisabled()
    }

    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular, .accessoryInline]
    #else
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    #endif
}

/// The app reloads this widget whenever the song or play/pause changes; while playing, the timeline also ends when
/// the song does, in case the app couldn't (the next song's state comes from the app's next write).
struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        var glance = GlanceProvider.current(preview: context.isPreview)
        if context.isPreview && glance?.nowPlaying == nil { glance?.nowPlaying = Glance.sample.nowPlaying }
        completion(GlanceEntry(date: Date(), glance: glance))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        let glance = GlanceProvider.current(preview: false)
        var entries = [GlanceEntry(date: now, glance: glance)]
        var policy = TimelineReloadPolicy.never
        if let playing = glance?.nowPlaying, playing.isPlaying, playing.endDate > now {
            // At the end of the song show it stopped, unless the app has written what plays next by then.
            var ended = glance!
            ended.nowPlaying?.isPlaying = false
            ended.nowPlaying?.position = playing.duration
            entries.append(GlanceEntry(date: playing.endDate.addingTimeInterval(1), glance: ended))
            policy = .after(playing.endDate.addingTimeInterval(2))
        }
        completion(Timeline(entries: entries, policy: policy))
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GlanceEntry

    var body: some View {
        if let glance = entry.glance {
            if let playing = glance.nowPlaying {
                switch family {
                case .accessoryCircular: circular(playing)
                case .accessoryRectangular: rectangular(playing)
                case .accessoryInline: Label("\(playing.song.title) · \(playing.song.artist)", systemImage: playing.isPlaying ? "play.fill" : "pause.fill")
                #if os(iOS)
                case .systemMedium: medium(playing)
                default: small(playing)
                #else
                default: rectangular(playing)
                #endif
                }
            } else {
                idle(glance)
            }
        } else {
            NoLibraryView(systemImage: "play.circle").padding()
        }
    }

    // MARK: Home screen

    private func progress(_ p: Glance.NowPlaying, tint: Color) -> some View {
        Group {
            if p.isPlaying && p.endDate > entry.date {
                ProgressView(timerInterval: p.startDate...p.endDate, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: min(p.position, max(p.duration, 1)), total: max(p.duration, 1))
            }
        }
        .progressViewStyle(.linear)
        .tint(tint)
        .labelsHidden()
    }

    private func small(_ p: Glance.NowPlaying) -> some View {
        ZStack(alignment: .bottomLeading) {
            CoverBackground(name: p.song.cover, title: p.song.album)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Image(systemName: p.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption.weight(.bold))
                        .symbolEffect(.variableColor.iterative, isActive: p.isPlaying)
                    Spacer()
                    #if os(iOS)
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: p.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.isPlaying ? "Pause" : "Play")
                    #endif
                }
                Spacer(minLength: 0)
                Text(p.song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(p.song.artist).font(.caption).opacity(0.85).lineLimit(1)
                progress(p, tint: .white).padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
    }

    private func medium(_ p: Glance.NowPlaying) -> some View {
        HStack(spacing: 14) {
            Link(destination: GlanceLink.album(key: p.song.albumKey).url) {
                CoverArt(name: p.song.cover, title: p.song.album, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.song.title).font(.headline).lineLimit(1)
                Text(p.song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(p.song.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                progress(p, tint: .pink)
                #if os(iOS)
                HStack {
                    Button(intent: ToggleLikeIntent()) {
                        Image(systemName: p.liked ? "heart.fill" : "heart").foregroundStyle(p.liked ? .pink : .secondary)
                    }
                    .accessibilityLabel(p.liked ? "Unlike" : "Like")
                    Spacer()
                    Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                    Spacer()
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: p.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .accessibilityLabel(p.isPlaying ? "Pause" : "Play")
                    Spacer()
                    Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next")
                }
                .buttonStyle(.plain)
                .font(.body)
                .padding(.top, 6)
                #endif
            }
        }
        .padding(14)
    }

    /// Nothing queued: the last thing to play, or shuffle what's on the phone.
    @ViewBuilder
    private func idle(_ glance: Glance) -> some View {
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); Image(systemName: "music.note").font(.title2) }
        case .accessoryRectangular, .accessoryInline:
            Label("Nothing playing", systemImage: "music.note")
        default:
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(title: "Now Playing", systemImage: "music.note", tint: .pink)
                Spacer(minLength: 0)
                Text("Nothing playing").font(.headline)
                Text(GlanceFormat.count(glance.library.songsOnPhone, "song") + " on this iPhone")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                #if os(iOS)
                if glance.library.songsOnPhone > 0 {
                    Button(intent: ShuffleAllIntent()) {
                        Label("Shuffle", systemImage: "shuffle").font(.caption.weight(.semibold))
                    }
                    .tint(.pink)
                }
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    // MARK: Lock screen and watch

    private func circular(_ p: Glance.NowPlaying) -> some View {
        Group {
            if p.isPlaying && p.endDate > entry.date {
                ProgressView(timerInterval: p.startDate...p.endDate, countsDown: false) {
                    Image(systemName: "music.note")
                } currentValueLabel: {
                    Image(systemName: "play.fill")
                }
            } else {
                ProgressView(value: min(p.position, max(p.duration, 1)), total: max(p.duration, 1)) {
                    Image(systemName: "music.note")
                } currentValueLabel: {
                    Image(systemName: "pause.fill")
                }
            }
        }
        .progressViewStyle(.circular)
        .widgetAccentable()
        .accessibilityLabel("\(p.song.title) by \(p.song.artist)")
    }

    private func rectangular(_ p: Glance.NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(p.song.title, systemImage: p.isPlaying ? "play.fill" : "pause.fill")
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            Text(p.song.artist).font(.caption).lineLimit(1)
            progress(p, tint: .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
