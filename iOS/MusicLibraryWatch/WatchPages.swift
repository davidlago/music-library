import MusicLibraryGlance
import SwiftUI
import UIKit

// MARK: Now Playing

/// What the iPhone is playing, with its controls: a remote for the phone's player.
struct NowPlayingPage: View {
    @Environment(WatchModel.self) private var model
    let glance: Glance

    var body: some View {
        Group {
            if let playing = glance.nowPlaying {
                nowPlaying(playing)
            } else {
                idle
            }
        }
        .navigationTitle("Now Playing")
        .containerBackground(Color.pink.gradient, for: .tabView)
    }

    private func nowPlaying(_ p: Glance.NowPlaying) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                WatchCover(name: p.song.cover, title: p.song.album, size: 44)
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.song.title).font(.headline).lineLimit(2)
                    Text(p.song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let position = p.position(at: context.date)
                VStack(spacing: 1) {
                    // A plain bar: watchOS draws a linear ProgressView with a knob, as if it could be dragged.
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.25))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geo.size.width * min(1, position / max(p.duration, 1)))
                            }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(Self.time(position))
                        Spacer()
                        Text("−" + Self.time(max(0, p.duration - position)))
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                control("backward.fill", label: "Previous", command: .previous)
                control(p.isPlaying ? "pause.fill" : "play.fill", label: p.isPlaying ? "Pause" : "Play", command: .playPause, large: true)
                control("forward.fill", label: "Next", command: .next)
            }
            status
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.send(.toggleLike) } label: {
                    Image(systemName: p.liked ? "heart.fill" : "heart").foregroundStyle(p.liked ? .pink : .primary)
                }
                .accessibilityLabel(p.liked ? "Unlike" : "Like")
            }
        }
    }

    private var idle: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
                Text("Nothing is playing on your iPhone.").font(.footnote).multilineTextAlignment(.center)
                Button { model.send(.shuffleAll) } label: { Label("Shuffle All", systemImage: "shuffle") }
                    .disabled(glance.library.songsOnPhone == 0)
                if glance.library.likedSongs > 0 {
                    Button { model.send(.shuffleLiked) } label: { Label("Liked Songs", systemImage: "heart") }
                }
                status
            }
        }
    }

    private func control(_ symbol: String, label: String, command: GlanceCommand, large: Bool = false) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(large ? .title2 : .body)
                .frame(maxWidth: .infinity, minHeight: large ? 44 : 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .opacity(model.pending == command ? 0.5 : 1)
    }

    @ViewBuilder
    private var status: some View {
        if let message = model.message {
            Text(message).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
        } else if !model.reachable {
            Label("iPhone not connected", systemImage: "iphone.slash").font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(0, seconds) : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: Listening

struct ListeningPage: View {
    @Environment(WatchModel.self) private var model
    let glance: Glance
    @AppStorage("watchListeningMonth") private var month = false

    var body: some View {
        let l = month ? glance.month : glance.week
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(GlanceFormat.listened(l.listened))
                        .font(.system(.title, design: .rounded, weight: .bold))
                    HStack(spacing: 4) {
                        Text("past \(l.days) days")
                        if let change = l.change {
                            Text(GlanceFormat.change(change)).foregroundStyle(change >= 0 ? .green : .orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                WatchBars(days: l.daily).frame(height: 36)
                HStack {
                    if l.currentStreak > 1 {
                        Label("\(l.currentStreak) days", systemImage: "flame.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(GlanceFormat.count(l.plays, "play")).foregroundStyle(.secondary)
                }
                .font(.caption2)
                if !l.topArtists.isEmpty {
                    SectionTitle("Top Artists")
                    ForEach(l.topArtists.prefix(3), id: \.item) { artist in
                        HStack {
                            Text(artist.item).font(.footnote).lineLimit(1)
                            Spacer()
                            Text(GlanceFormat.count(artist.plays, "play")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !l.topSongs.isEmpty {
                    SectionTitle("Top Songs")
                    ForEach(l.topSongs.prefix(5), id: \.item.id) { song in
                        SongRow(song: song.item, detail: GlanceFormat.count(song.plays, "play"))
                    }
                }
            }
        }
        .navigationTitle("Listening")
        .containerBackground(Color.orange.gradient, for: .tabView)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(month ? "30d" : "7d") { month.toggle() }
                    .accessibilityLabel(month ? "Showing 30 days; show 7" : "Showing 7 days; show 30")
            }
        }
    }
}

// MARK: Purchases

struct PurchasesPage: View {
    let glance: Glance

    var body: some View {
        let owned = glance.owned
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.6)
                    Text("\(GlanceFormat.count(owned.boughtThisYear, "album")) this year")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(owned.ownedCount.formatted()) owned in all · \(glance.money(owned.totalSpent, whole: true))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if owned.recent.isEmpty {
                    Text("Record when you bought an album, and what you paid, on its page on the iPhone or the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    SectionTitle("Latest")
                    ForEach(owned.recent) { p in
                        NavigationLink(value: p.album) {
                            AlbumRow(album: p.album, detail: [p.price.map { glance.money($0) }, p.dateText].compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Purchases")
        .containerBackground(Color.green.gradient, for: .tabView)
    }
}

// MARK: Play

/// Starts something on the iPhone: shuffles, this month's favorites, forgotten ones and what's new.
struct PlayPage: View {
    @Environment(WatchModel.self) private var model
    let glance: Glance

    var body: some View {
        List {
            Section {
                Button { model.send(.shuffleAll) } label: { Label("Shuffle All", systemImage: "shuffle") }
                    .disabled(glance.library.songsOnPhone == 0)
                Button { model.send(.shuffleLiked) } label: { Label("Liked Songs", systemImage: "heart.fill") }
                    .disabled(glance.library.likedSongs == 0)
            } footer: {
                if let message = model.message { Text(message).foregroundStyle(.orange) }
            }
            if !glance.month.topAlbums.isEmpty {
                Section("Most Played") {
                    ForEach(glance.month.topAlbums.prefix(6), id: \.item.key) { album in
                        NavigationLink(value: album.item) { AlbumRow(album: album.item, detail: album.item.artist) }
                    }
                }
            }
            if !glance.rediscover.isEmpty {
                Section("Rediscover") {
                    ForEach(glance.rediscover.prefix(6), id: \.item.id) { song in
                        SongRow(song: song.item, detail: song.item.artist)
                    }
                }
            }
            if !glance.library.recentlyAdded.isEmpty {
                Section("Recently Added") {
                    ForEach(glance.library.recentlyAdded) { album in
                        NavigationLink(value: album) { AlbumRow(album: album, detail: album.artist) }
                    }
                }
            }
        }
        .navigationTitle("Play")
        .containerBackground(Color.indigo.gradient, for: .tabView)
    }
}

struct AlbumPage: View {
    @Environment(WatchModel.self) private var model
    let album: Glance.Album

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                WatchCover(name: album.cover, title: album.title, size: 96)
                Text(album.title).font(.headline).multilineTextAlignment(.center)
                Text([album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if album.playable {
                    Button { model.send(.playAlbum(key: album.key)) } label: { Label("Play on iPhone", systemImage: "play.fill") }
                        .tint(.pink)
                } else {
                    Text("Not on your iPhone. Download it there to play it.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let message = model.message { Text(message).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .navigationTitle(album.title)
    }
}

// MARK: Pieces

struct WatchCover: View {
    @Environment(WatchModel.self) private var model
    var name: String?
    var title: String
    var size: CGFloat

    var body: some View {
        let _ = model.coverRevision
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let name, let url = model.store.coverURL(name), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 10 : 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct AlbumRow: View {
    var album: Glance.Album
    var detail: String

    var body: some View {
        HStack(spacing: 8) {
            WatchCover(name: album.cover, title: album.title, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(album.title).font(.footnote.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .opacity(album.playable ? 1 : 0.6)
    }
}

/// A song; tapping it plays it (with the rest of its album) on the iPhone.
struct SongRow: View {
    @Environment(WatchModel.self) private var model
    var song: Glance.Song
    var detail: String

    var body: some View {
        Button { model.send(.playSong(id: song.id)) } label: {
            HStack(spacing: 8) {
                WatchCover(name: song.cover, title: song.album, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title).font(.footnote.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(!song.playable)
        .opacity(song.playable ? 1 : 0.6)
    }
}

struct SectionTitle: View {
    var title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

struct WatchBars: View {
    var days: [Glance.Listening.Day]

    var body: some View {
        let peak = max(days.map(\.listened).max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: days.count > 14 ? 1 : 3) {
                ForEach(days, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(day.listened > 0 ? AnyShapeStyle(Color.white) : AnyShapeStyle(.quaternary))
                        .frame(height: max(2, geo.size.height * day.listened / peak))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .accessibilityLabel("Listening per day")
    }
}
