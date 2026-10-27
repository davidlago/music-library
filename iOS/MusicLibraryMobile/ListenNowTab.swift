import MusicLibraryCore
import SwiftUI

/// Listen Now, the first tab: the album playing (or played last) at the top, tinted by its cover, then what you've
/// been playing, your week, what's beside the album on the shelf, and what's up next. Sync and Settings are at the top.
struct ListenNowTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        LibraryStack {
            Group {
                if let library = model.library, !library.isEmpty, let album = model.listenNowAlbum {
                    ListenNowPage(library: library, album: album)
                } else {
                    LibraryStatusView()
                }
            }
            .navigationTitle("Listen Now")
            .radioDJPage(.page("Listen Now, their home page", details: [
                model.player.currentTrack.map { "Now playing: \($0.title) by \($0.artist)" } ?? "Nothing is playing.",
                model.listenNowAlbum.map { "Leading the page: the album \($0.album) by \($0.artist)" } ?? "",
            ].filter { !$0.isEmpty }))
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { model.showsSync = true } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Sync with Your Mac")
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

private struct ListenNowPage: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let library: LibrarySnapshot
    let album: AlbumSummary

    var body: some View {
        let key = SearchIndex.albumKey(album: album.album, artist: album.artist)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.isSample { sampleNote }
                ListenNowHero(library: library, album: album)
                recent(excluding: key)
                shelf(key)
                week
                upNext
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background { AlbumBackdrop(url: library.coverURL(album: album)) }
        .refreshable { model.reload() }
        .onAppear { model.loadWeekListening() }
        .onChange(of: model.historyVersion) { model.loadWeekListening() }
    }

    private var sampleNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample Library").font(.headline)
                Text("Fictional artists and albums, made up so you can try the app. Your own music replaces it after your first sync.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Hide Sample Library") { model.hideSample() }.font(.subheadline.weight(.medium)).padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Keep listening

    @ViewBuilder
    private func recent(excluding key: String) -> some View {
        let albums = model.recentlyPlayedAlbums(limit: 12, excluding: key)
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Keep Listening")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { a in
                            NavigationLink(value: a) {
                                VStack(alignment: .leading, spacing: 3) {
                                    CopyArt(mark: model.copyMark(for: a), url: library.coverURL(album: a), width: 130, title: a.album)
                                        .padding(.bottom, 4)
                                    Text(a.album.isEmpty ? "Unknown Album" : a.album).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 130, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
            }
        }
    }

    // MARK: Beside it on the shelf

    @ViewBuilder
    private func shelf(_ key: String) -> some View {
        let copy = model.collection.copies(albumKey: key).first { $0.sticker != nil }
        if let copy, let sticker = copy.sticker {
            let around = model.collection.neighbors(of: sticker)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Beside It on the Shelf")
                HStack(alignment: .top, spacing: 12) {
                    ForEach([around.previous, copy, around.next].compactMap { $0 }) { item in
                        NavigationLink(value: CollectionItemRoute(id: item.id)) {
                            VStack(spacing: 6) {
                                CopyArt(mark: model.copyMark(for: item), url: library.coverURL(item: item), width: 96, title: item.album)
                                    .overlay {
                                        if item.id == copy.id {
                                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-4)
                                        }
                                    }
                                Text(item.album).font(.caption).lineLimit(1)
                                    .foregroundStyle(item.id == copy.id ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .card()
            }
        }
    }

    // MARK: Your week

    @ViewBuilder
    private var week: some View {
        if let w = model.weekListening, w.plays > 0 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Your Week")
                StatGrid {
                    tile(w.plays.formatted(), w.plays == 1 ? "play" : "plays", detail: change(w))
                    tile(hoursAndMinutes(w.listened), "of music", detail: w.artists.byPlays.first.map { "Top: \($0.name)" })
                    tile(w.newArtists.total.formatted(), w.newArtists.total == 1 ? "artist new to you" : "artists new to you",
                         detail: w.newArtists.byPlays.first?.name)
                    tile(w.currentStreak == 1 ? "1 day" : "\(w.currentStreak) days", "listening streak",
                         detail: w.longestStreak > w.currentStreak ? "Longest: \(w.longestStreak) days" : "Your longest yet")
                }
            }
        }
    }

    private func tile(_ value: String, _ label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func change(_ w: ListeningStats) -> String? {
        guard let before = w.previous?.plays, before > 0 else { return nil }
        let pct = Int((Double(w.plays - before) / Double(before) * 100).rounded())
        if pct == 0 { return "Same as the week before" }
        return pct > 0 ? "\(pct)% more than before" : "\(-pct)% fewer than before"
    }

    private func hoursAndMinutes(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    // MARK: Up next

    @ViewBuilder
    private var upNext: some View {
        let upcoming = Array(player.queue.upcoming.prefix(4))
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Up Next")
                VStack(spacing: 0) {
                    ForEach(upcoming) { entry in
                        HStack(spacing: 12) {
                            CoverImage(url: cover(entry.track), size: 40, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if entry.isQueued {
                                Text("NEXT").font(.caption2.weight(.heavy)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            Text(Format.time(entry.track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if entry.id != upcoming.last?.id { Divider().padding(.leading, 66) }
                    }
                }
                .padding(.vertical, 2)
                .card()
            }
        }
    }

    private func cover(_ track: Track) -> URL? {
        library.album(forKey: SearchIndex.albumKey(album: track.album, artist: track.effectiveAlbumArtist)).flatMap(library.coverURL(album:))
    }
}

/// The album at the top of Listen Now: its cover or case, what it is, and play controls.
private struct ListenNowHero: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let library: LibrarySnapshot
    let album: AlbumSummary

    var body: some View {
        let key = SearchIndex.albumKey(album: album.album, artist: album.artist)
        let current = player.currentTrack.map { SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist) == key } ?? false
        let playable = model.playable(library.tracks(album: album))
        let lastPlayed = model.albumPlayTotals[key]?.lastPlayed
        let sticker = model.collection.copies(albumKey: key).compactMap(\.sticker).first
        HStack(alignment: .top, spacing: 14) {
            NavigationLink(value: album) {
                CopyArt(mark: model.copyMark(for: album), url: library.coverURL(album: album), width: 118, title: album.album)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(current ? "NOW PLAYING" : lastPlayed != nil ? "LAST PLAYED" : "RECENTLY ADDED")
                        .font(.caption2.weight(.semibold)).kerning(1).foregroundStyle(.secondary)
                    if let sticker { StickerPill(sticker: sticker) }
                }
                Text(album.album.isEmpty ? "Unknown Album" : album.album).font(.title3.bold()).lineLimit(2)
                Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if current, let track = player.currentTrack {
                    Text(track.title).font(.caption).lineLimit(1).padding(.top, 2)
                    ProgressView(value: min(player.currentTime, max(player.duration, 1)), total: max(player.duration, 1))
                        .progressViewStyle(.linear)
                }
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    Button {
                        if current { player.togglePlayPause() } else { player.play(queue: playable, source: album.album) }
                    } label: {
                        Label(current && player.isPlaying ? "Pause" : "Play", systemImage: current && player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { player.play(queue: playable.shuffled(), source: album.album) } label: {
                        Image(systemName: "shuffle").frame(height: 20)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Shuffle")
                }
                .disabled(playable.isEmpty && !current)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
