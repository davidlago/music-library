import AppKit
import MusicLibraryCore
import SwiftUI

/// Listen Now, the first row of the sidebar: the album playing (or played last) at the top, tinted by its cover,
/// then what you've been playing and your week, with the queue and the album's neighbors on the shelf beside them.
struct ListenNowView: View {
    @Environment(AppModel.self) private var model
    @State private var cover: NSImage?

    var body: some View {
        let album = model.listenNowAlbum
        GeometryReader { geo in
            ZStack {
                AlbumBackdrop(image: cover)
                if let album {
                    ScrollView {
                        // The queue and the shelf go in a column beside the rest when there's room and anything to show.
                        let side = !model.player.queue.upcoming.isEmpty || shelfCopy(album) != nil
                        let wide = geo.size.width >= 980 && side
                        VStack(alignment: .leading, spacing: 28) {
                            ListenNowHero(album: album)
                            if wide {
                                HStack(alignment: .top, spacing: 24) {
                                    VStack(alignment: .leading, spacing: 28) { recent(album); week }
                                    VStack(alignment: .leading, spacing: 18) { upNext; shelf(album) }
                                        .frame(width: 340)
                                }
                            } else {
                                recent(album)
                                week
                                upNext
                                shelf(album)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 1240, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("Nothing to Listen To Yet", systemImage: "play.circle",
                                           description: Text("Import some music, or add the CDs and records you own."))
                }
            }
        }
        .navigationTitle("Listen Now")
        .task(id: album.map { model.coverURL(forAlbum: $0) } ?? nil) {
            let url = album.flatMap { model.coverURL(forAlbum: $0) }
            cover = await Task.detached { url.flatMap { NSImage(contentsOf: $0) } }.value
        }
        .onAppear { model.loadWeekListeningIfNeeded() }
        .onChange(of: model.historyVersion) { model.loadWeekListeningIfNeeded() }
    }

    // MARK: Keep listening

    @ViewBuilder
    private func recent(_ hero: AlbumSummary) -> some View {
        let albums = model.recentlyPlayedAlbums(limit: 10, excluding: AlbumInfoStore.key(hero))
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ListenNowHeader(title: "Keep Listening") {
                    Button("All Albums") { model.sidebar = .albums }.buttonStyle(.link)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            VStack(alignment: .leading, spacing: 3) {
                                CopyArt(mark: model.copyMark(for: a), url: model.coverURL(forAlbum: a), width: 140, revision: model.coverRevision)
                                    .padding(.bottom, 4)
                                Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.headline).lineLimit(1)
                                Text(a.artist.isEmpty ? "Unknown Artist" : a.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { AlbumMenuButtons(album: a) }
                    }
                }
            }
        }
    }

    // MARK: Your week

    @ViewBuilder
    private var week: some View {
        if let w = model.weekListening, w.plays > 0 {
            VStack(alignment: .leading, spacing: 12) {
                ListenNowHeader(title: "Your Week") {
                    Button("Insights") { model.sidebar = .insights }.buttonStyle(.link)
                }
                HStack(spacing: 12) {
                    WeekTile(value: w.plays.formatted(), label: w.plays == 1 ? "play" : "plays", detail: change(w))
                    WeekTile(value: hoursAndMinutes(w.listened), label: "of music",
                             detail: w.artists.byPlays.first.map { "Top artist: \($0.name)" })
                    WeekTile(value: w.newArtists.total.formatted(), label: w.newArtists.total == 1 ? "artist new to you" : "artists new to you",
                             detail: w.newArtists.byPlays.prefix(3).map(\.name).joined(separator: ", ").nilIfEmpty)
                    WeekTile(value: w.currentStreak == 1 ? "1 day" : "\(w.currentStreak) days", label: "listening streak",
                             detail: w.longestStreak > w.currentStreak ? "Longest: \(w.longestStreak) days" : "Your longest yet")
                }
            }
        }
    }

    private func change(_ w: ListeningStats) -> String? {
        guard let before = w.previous?.plays, before > 0 else { return nil }
        let pct = Int((Double(w.plays - before) / Double(before) * 100).rounded())
        if pct == 0 { return "Same as the week before" }
        return pct > 0 ? "\(pct)% more than the week before" : "\(-pct)% fewer than the week before"
    }

    private func hoursAndMinutes(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: Up next

    @ViewBuilder
    private var upNext: some View {
        let upcoming = Array(model.player.queue.upcoming.prefix(5))
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ListenNowHeader(title: "Up Next") {
                    Button(model.showsQueue ? "Hide Queue" : "Show Queue") { model.showsQueue.toggle() }.buttonStyle(.link)
                }
                VStack(spacing: 0) {
                    ForEach(upcoming) { entry in
                        HStack(spacing: 10) {
                            CoverThumb(url: model.coverURL(for: entry.track), size: 36, revision: model.coverRevision, cornerRadius: 5)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(entry.track.title).font(.callout.weight(.medium)).lineLimit(1)
                                    if entry.isQueued {
                                        Text("NEXT").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(AppColor.accent))
                                    }
                                }
                                Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(formatTime(entry.track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        if entry.id != upcoming.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: On the shelf

    /// The album's labeled copy, if it has one: what the shelf section is about.
    private func shelfCopy(_ album: AlbumSummary) -> CollectionItem? {
        model.collection.copies(albumKey: AlbumInfoStore.key(album)).first { $0.sticker != nil }
    }

    @ViewBuilder
    private func shelf(_ album: AlbumSummary) -> some View {
        if let copy = shelfCopy(album), let sticker = copy.sticker {
            let around = model.collection.neighbors(of: sticker)
            VStack(alignment: .leading, spacing: 10) {
                ListenNowHeader(title: "Beside It on the Shelf") {
                    Button("Find by Label…") { model.findByLabel() }.buttonStyle(.link)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach([around.previous, copy, around.next].compactMap { $0 }) { item in
                        NavigationLink(value: CollectionItemRoute(id: item.id)) {
                            VStack(spacing: 6) {
                                CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 92, revision: model.coverRevision)
                                    .overlay {
                                        if item.id == copy.id {
                                            RoundedRectangle(cornerRadius: 6).strokeBorder(AppColor.accent, lineWidth: 2.5).padding(-4)
                                        }
                                    }
                                Text(item.album).font(.caption).lineLimit(1)
                                    .foregroundStyle(item.id == copy.id ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.secondary))
                            }
                            .frame(width: 96)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

/// The album at the top of Listen Now, as a card over its own tint: its cover or case, what it is, and play controls.
private struct ListenNowHero: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary

    var body: some View {
        let player = model.player
        let key = AlbumInfoStore.key(album)
        let playing = player.currentTrack.map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) == key } ?? false
        let lastPlayed = model.albumPlayTotals[key]?.lastPlayed
        let sticker = model.collection.copies(albumKey: key).compactMap(\.sticker).first
        HStack(alignment: .center, spacing: 28) {
            NavigationLink(value: album) {
                CopyArt(mark: model.copyMark(for: album), url: model.coverURL(forAlbum: album), width: 240, revision: model.coverRevision)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(playing ? "NOW PLAYING" : lastPlayed != nil ? "LAST PLAYED" : "RECENTLY ADDED")
                        .font(.caption.weight(.semibold)).kerning(1.2).foregroundStyle(.secondary)
                    if let sticker { StickerPill(sticker: sticker) }
                }
                Text(album.album.isEmpty ? "Unknown Album" : album.album)
                    .font(.system(size: 40, weight: .heavy)).lineLimit(2)
                NavigationLink(value: ArtistRoute(name: album.artist)) {
                    Text(album.artist.isEmpty ? "Unknown Artist" : album.artist).font(.title2.weight(.semibold))
                }
                .buttonStyle(.plain)
                Text(meta(lastPlayed: playing ? nil : lastPlayed)).font(.callout).foregroundStyle(.secondary)
                if playing, let track = player.currentTrack {
                    HStack(spacing: 10) {
                        Text(track.title).font(.callout).lineLimit(1)
                        ProgressView(value: min(player.currentTime, max(player.duration, 1)), total: max(player.duration, 1))
                            .progressViewStyle(.linear).frame(maxWidth: 360)
                    }
                    .padding(.top, 4)
                }
                HStack(spacing: 8) {
                    Button {
                        if playing { player.togglePlayPause() } else { play(shuffled: false) }
                    } label: {
                        Label(playing && player.isPlaying ? "Pause" : "Play", systemImage: playing && player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(minWidth: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    NavigationLink(value: album) { Text("Open Album") }
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func meta(lastPlayed: Date?) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.trackCount == 1 ? "1 song" : "\(album.trackCount) songs")
        if let lastPlayed { parts.append("played " + lastPlayed.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func play(shuffled: Bool) {
        let tracks = model.tracks(of: album)
        guard !tracks.isEmpty else { return }
        model.player.play(queue: shuffled ? tracks.shuffled() : tracks, startAt: 0, source: album.album)
    }
}

/// A section title with an action on the right.
private struct ListenNowHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing.font(.callout)
        }
    }
}

/// One number of the week.
private struct WeekTile: View {
    let value: String
    let label: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(2).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
