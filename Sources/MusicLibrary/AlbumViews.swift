import AppKit
import MusicLibraryCore
import SwiftUI

/// The album page: a blurred-cover backdrop with the album's details on the left and the track list on
/// the right (stacked in narrow windows). Online info comes from the album info cache.
struct AlbumDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let album: AlbumSummary
    @State private var tracks: [Track] = []
    @State private var cover: NSImage?
    @State private var descriptionExpanded = false
    @State private var showAllCredits = false
    @State private var coverSheet: CoverSheetRequest?
    @State private var hoveringCover = false
    @State private var coverDropTargeted = false
    /// A record sleeve's disc label, tinted from the cover.
    @State private var coverTint: Color?

    private var title: String { album.album.isEmpty ? "Unknown Album" : album.album }

    var body: some View {
        let info = model.albumInfo.info(for: album)
        GeometryReader { geo in
            ZStack {
                AlbumBackdrop(image: cover)
                if geo.size.width >= 920 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                header(info, coverSize: min(380, geo.size.width * 0.42 - 56))
                                sections(info)
                            }
                            .padding(28)
                        }
                        .frame(width: min(460, geo.size.width * 0.42))
                        ScrollView {
                            trackList(info).padding(.vertical, 28).padding(.trailing, 28).padding(.leading, 4)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header(info, coverSize: min(300, geo.size.width - 48))
                            trackList(info)
                            sections(info)
                        }
                        .padding(24)
                    }
                }
            }
        }
        .radioDJ { [model, album] in model.radioDJSubject(album: album) }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem { AddToExportListButton(album: album) }
            ToolbarItem {
                Button { coverSheet = CoverSheetRequest() } label: { Label("Change Cover…", systemImage: "photo") }
                    .disabled(tracks.isEmpty)
                    .help("Find a cover on MusicBrainz or use an image of your own")
            }
            ToolbarItem {
                Button { model.refreshAlbumInfo(album) } label: { Label("Update Album Info", systemImage: "arrow.clockwise") }
                    .disabled(model.albumInfo.isFetching(album))
                    .help("Download the latest description, rating, links and track list")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.libraryVersion) {
            load()
            // The album was removed from the library.
            if tracks.isEmpty { dismiss() }
        }
        .sheet(item: $coverSheet) { AlbumCoverSheet(album: album, tracks: tracks, request: $0) }
        .task(id: "\(album.id)|\(model.coverRevision)") {
            guard let url = model.coverURL(forAlbum: album) else { cover = nil; return }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            cover = data.flatMap(NSImage.init(data:))
            coverTint = await CoverTint.color(of: url)
        }
    }

    /// Every CD-quality track already checked accurate: their audio doesn't change (Rip Again checks a track itself), so
    /// there's nothing to check again.
    private var allAccurate: Bool {
        let cd = tracks.filter(RipDiscMatcher.isCDAudio)
        return !cd.isEmpty && cd.allSatisfy { model.ripChecks[$0.id]?.result == .accurate }
    }

    private func load() {
        tracks = model.tracks(of: album)
        model.ensureAlbumInfo(album)
    }

    // MARK: Header

    private func header(_ info: AlbumInfo?, coverSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            coverArt(size: coverSize).padding(.bottom, 10)

            Text(typeLine(info)).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(title).font(.system(size: 30, weight: .bold)).lineLimit(3).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            artistButton
            if let meta = metaLine(info) { Text(meta).font(.callout).foregroundStyle(.secondary) }
            if let info, let rating = info.rating { RatingView(rating: rating, votes: info.ratingVotes) }
            let genres = displayGenres(info)
            if !genres.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(genres, id: \.self) { g in
                        Button { model.search(SearchFilterKey.token("genre", g)) } label: {
                            Text(g.capitalized).font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(AppColor.fill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { play(tracks, at: 0) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                    .buttonStyle(.borderedProminent)
                Button { play(tracks.shuffled(), at: 0) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .buttonStyle(.bordered)
                Menu {
                    QueueMenuButtons(player: model.player) { tracks }
                    Divider()
                    Button(allAccurate ? "AccurateRip: All Tracks Accurate" : "Check with AccurateRip", systemImage: "checkmark.seal") {
                        model.rips.check(album: album)
                    }
                    .disabled(allAccurate || model.rips.albumStates[AlbumInfoStore.key(album)] == .checking
                              || !tracks.contains(where: RipDiscMatcher.isCDAudio) || !model.ffmpegAvailable)
                    Button("Shop for This CD", systemImage: "cart") {
                        let releaseId = tracks.lazy.compactMap(\.metadata.mbReleaseId).first
                        model.cdShop.shop(releaseId: releaseId, album: album.album, artist: album.artist)
                        model.sidebar = .cdShop
                    }
                    Button("Shop for It on Vinyl", systemImage: "cart") {
                        // The tagged release is usually the CD's: find the album's records by name.
                        model.cdShop.shop(releaseId: nil, album: album.album, artist: album.artist, format: .vinyl)
                        model.sidebar = .cdShop
                    }
                    Divider()
                    RemoveFromLibraryButton(album: album)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
                    .help("Play Next, Add to Queue, check the rip with AccurateRip, shop for the CD or record, or remove the album")
            }
            .controlSize(.large)
            .disabled(tracks.isEmpty)
            .padding(.top, 6)
            listening(info).padding(.top, 8)
            AlbumRipSummary(album: album, tracks: tracks)
        }
    }

    /// The cover as you own it (`CopyMark`): in its jewel case with your label sticker when you have the CD, in its
    /// sleeve when your only physical copy is a record, else flat with its badge (a download, or borrowed). "Change
    /// Cover…" shows on hover (or "Add Cover…" when there is none); dropping an image on it opens the cover sheet with
    /// that image.
    private func coverArt(size: CGFloat) -> some View {
        let mark = model.copyMark(for: album)
        return Group {
            switch mark {
            case .cd:
                JewelCase(width: size, mark: mark) { booklet(side: JewelCase<EmptyView>.bookletSide(width: size)) }
            case .vinyl:
                RecordSleeve(width: size, mark: mark, tint: coverTint) { booklet(side: RecordSleeve<EmptyView>.sleeveSide(width: size)) }
            default:
                let side = JewelCase<EmptyView>.height(width: size)
                booklet(side: side)
                    .overlay { CoverCopyMark(mark: mark, size: side) }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.3), radius: 14 * size / 380, y: 14 * size / 380)
                    .frame(width: size, height: side, alignment: .topLeading)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if cover != nil, hoveringCover, !tracks.isEmpty {
                Button { coverSheet = CoverSheetRequest() } label: { Label("Change Cover…", systemImage: "photo") }
                    .controlSize(.small)
                    .padding(14)
            }
        }
        .overlay {
            if coverDropTargeted {
                RoundedRectangle(cornerRadius: JewelCase<EmptyView>.cornerRadius(width: size)).strokeBorder(AppColor.accent, lineWidth: 3)
            }
        }
        .onHover { hoveringCover = $0 }
        .contextMenu {
            Button(cover == nil ? "Add Cover…" : "Change Cover…") { coverSheet = CoverSheetRequest() }.disabled(tracks.isEmpty)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL, !tracks.isEmpty else { return false }
            let data = try? Data(contentsOf: url)
            guard let data, NSImage(data: data) != nil else { return false }
            coverSheet = CoverSheetRequest(image: data, source: url.lastPathComponent)
            return true
        } isTargeted: { coverDropTargeted = $0 }
    }

    /// The cover image, or a placeholder with "Add Cover…".
    @ViewBuilder
    private func booklet(side: CGFloat) -> some View {
        if let cover {
            Image(nsImage: cover).resizable().scaledToFill()
                .frame(width: side, height: side).clipped()
        } else {
            ZStack {
                Rectangle().fill(AppColor.fill)
                VStack(spacing: 12) {
                    Image(systemName: "music.note").font(.system(size: side / 4)).foregroundStyle(.secondary)
                    if !tracks.isEmpty {
                        Button("Add Cover…") { coverSheet = CoverSheetRequest() }
                    }
                }
            }
            .frame(width: side, height: side)
        }
    }

    @ViewBuilder
    private var artistButton: some View {
        let name = album.artist.isEmpty ? "Unknown Artist" : album.artist
        if let artist = model.artistSummary(named: album.artist) {
            Button { model.navigationPath.append(artist) } label: {
                HStack(spacing: 8) {
                    ArtistPhoto(name: artist.name, size: 26)
                    Text(name).font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(name)")
        } else {
            Text(name).font(.title3.weight(.medium))
        }
    }

    private func typeLine(_ info: AlbumInfo?) -> String {
        var parts = [(info?.typeLabel ?? "Album").uppercased()]
        if let y = info?.firstReleaseYear ?? album.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    private func metaLine(_ info: AlbumInfo?) -> String? {
        var parts: [String] = []
        if let original = info?.firstReleaseYear, let year = album.year, year != original { parts.append("This edition \(year)") }
        if let label = firstValue(\.label) { parts.append(label) }
        let total = tracks.reduce(0) { $0 + $1.duration }
        parts.append("\(songCount(tracks.count)), \(formatLongDuration(total))")
        if let quality = qualityLabel { parts.append(quality) }
        return parts.joined(separator: " · ")
    }

    /// "FLAC 24/96 · Hi-Res" for the most common format among the album's tracks.
    private var qualityLabel: String? {
        let formats = tracks.compactMap(\.audioFormat)
        guard let common = Dictionary(grouping: formats, by: \.compact).max(by: { $0.value.count < $1.value.count }) else { return nil }
        let hiRes = tracks.contains(where: \.isHiRes)
        return common.key + (hiRes ? " · Hi-Res" : (tracks.allSatisfy { $0.isLossless == true } ? " · Lossless" : ""))
    }

    private func displayGenres(_ info: AlbumInfo?) -> [String] {
        if let g = info?.genres, !g.isEmpty { return g }
        var seen = Set<String>()
        return tracks.flatMap { SearchIndex.genres(of: $0.metadata) }.filter { seen.insert($0.lowercased()).inserted }.prefix(5).map { $0 }
    }

    /// Your listening history for the album: plays (listens that reached half the track or 4 minutes),
    /// all time actually listened, when you last played it and the track you play most.
    private func listening(_ info: AlbumInfo?) -> some View {
        let totals = tracks.map { ($0, model.playTotals[$0.id] ?? PlayTotal()) }
        let total = totals.map(\.1).reduce(PlayTotal(), +)
        let top = totals.filter { $0.1.plays > 0 }.max { $0.1.plays != $1.1.plays ? $0.1.plays < $1.1.plays : $0.1.listened < $1.1.listened }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], alignment: .leading, spacing: 10) {
            StatTile(value: total.plays.formatted(), label: total.plays == 1 ? "Play" : "Plays", icon: "play.circle")
                .help("Listens that reached half the track or 4 minutes")
            StatTile(value: formatListened(total.listened), label: "Time listened", icon: "headphones")
                .help("All the time you've spent listening to this album, including short listens")
            StatTile(value: total.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                     label: "Last played", icon: "calendar")
            if let top {
                StatTile(value: top.0.title, label: "Most played · \(top.1.plays)×", icon: "flame")
            }
            if let scrobbles = info?.lastfmUserPlaycount, scrobbles > 0 {
                StatTile(value: scrobbles.formatted(), label: "Last.fm scrobbles", icon: "dot.radiowaves.left.and.right")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ info: AlbumInfo?) -> some View {
        if !album.album.isEmpty {
            YourCopiesSection(album: album, plays: tracks.reduce(0) { $0 + (model.playTotals[$1.id]?.plays ?? 0) })
        }
        if let text = info?.description { about(text, info!) }
        else if model.albumInfo.isFetching(album) {
            Label("Looking up album info…", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
        }
        if let reviews = info?.reviews.filter(\.url.isWebLink), !reviews.isEmpty { linkChips("Reviews", reviews) }
        details
        credits
        if let links = info?.links.filter({ $0.kind != .review && $0.url.isWebLink }), !links.isEmpty { linkChips("Links", links) }
    }

    private func about(_ text: String, _ info: AlbumInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "About")
            Text(text).lineSpacing(3).lineLimit(descriptionExpanded ? nil : 6).textSelection(.enabled)
            HStack(spacing: 14) {
                if text.count > 350 {
                    Button(descriptionExpanded ? "Show Less" : "Read More") { withAnimation(.snappy) { descriptionExpanded.toggle() } }
                        .buttonStyle(.link)
                }
                if let source = info.descriptionSource {
                    if let url = info.descriptionURL?.webLink { Link("From \(source)", destination: url).font(.caption) }
                    else { Text("From \(source)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func linkChips(_ title: String, _ links: [ArtistLink]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            FlowLayout(spacing: 8) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: ArtistDetail.icon(link.kind))
                            .font(.callout)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(AppColor.fill))
                    }
                    .buttonStyle(.plain)
                    .help(link.url.absoluteString)
                }
            }
        }
    }

    private func firstValue(_ path: KeyPath<ExtendedMetadata, String>) -> String? {
        tracks.lazy.map { $0.metadata.extended[keyPath: path] }.first { !$0.isEmpty }
    }

    @ViewBuilder
    private var details: some View {
        let rows: [(String, String)] = [
            ("Record label", firstValue(\.label)), ("Catalog #", firstValue(\.catalogNumber)),
            ("Released", firstValue(\.releaseDate)), ("Original release", firstValue(\.originalDate)),
            ("Country", firstValue(\.releaseCountry).map(LabelsCard.countryName)),
            ("Media", firstValue(\.mediaFormat)), ("Packaging", firstValue(\.packaging).flatMap { $0 == "None" ? nil : $0 }),
            ("Barcode", firstValue(\.barcode)),
        ].compactMap { k, v in v.map { (k, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Release")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(rows, id: \.0) { k, v in
                        GridRow {
                            Text(k).foregroundStyle(.secondary)
                            Text(v).textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// Everyone credited across the album's tracks, most frequent first.
    private var people: [(name: String, roles: [String], tracks: Int)] {
        var roles: [String: [String: Int]] = [:]
        var trackSets: [String: Set<Int64>] = [:]
        var order: [String] = []
        for t in tracks {
            for c in t.metadata.extended.credits {
                if roles[c.name] == nil { order.append(c.name) }
                trackSets[c.name, default: []].insert(t.id)
                for r in CreditFormatter.label(c) { roles[c.name, default: [:]][r, default: 0] += 1 }
            }
        }
        return order.map { name in
            (name, (roles[name] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key),
             trackSets[name]?.count ?? 0)
        }
        .enumerated().sorted { $0.element.2 != $1.element.2 ? $0.element.2 > $1.element.2 : $0.offset < $1.offset }
        .map(\.element)
    }

    @ViewBuilder
    private var credits: some View {
        let all = people
        if !all.isEmpty {
            let shown = showAllCredits ? all : Array(all.prefix(10))
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Credits")
                ForEach(shown, id: \.name) { p in
                    HStack(alignment: .firstTextBaseline) {
                        PersonLink(name: p.name) { model.showMusicDNA($0) }
                            .fontWeight(.medium)
                            .contextMenu {
                                Button("Show Music DNA") { model.showMusicDNA(p.name) }
                                Button("Find Songs They're Credited On") { model.search(SearchFilterKey.token("credit", p.name)) }
                            }
                        Text(p.roles.prefix(3).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        if tracks.count > 1 {
                            Text(p.tracks == tracks.count ? "all tracks" : "\(p.tracks) track\(p.tracks == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                if all.count > 10 {
                    Button(showAllCredits ? "Show Fewer" : "Show All \(all.count)") { withAnimation(.snappy) { showAllCredits.toggle() } }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Tracks

    private func trackList(_ info: AlbumInfo?) -> some View {
        let rows = AlbumTracklist.merge(library: tracks, tracklist: info?.tracklist ?? [])
        let discs = Array(Set(rows.map(\.disc))).sorted()
        let missing = rows.filter { if case .missing = $0 { true } else { false } }.count
        let playable = rows.compactMap { if case .owned(let t, _) = $0 { t } else { nil } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Tracks")
                Spacer()
                if missing > 0 {
                    Text("\(playable.count) of \(rows.count) in your digital collection").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(discs, id: \.self) { disc in
                    if discs.count > 1 {
                        HStack {
                            Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                            Text("Disc \(disc)").font(.callout.weight(.semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.top, disc == discs.first ? 10 : 18).padding(.bottom, 4)
                    }
                    ForEach(rows.filter { $0.disc == disc }) { row in
                        AlbumTrackRow(row: row, albumArtist: album.artist, total: playTotal(row)) {
                            if case .owned(let t, _) = row, let i = playable.firstIndex(of: t) { play(playable, at: i) }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(AppColor.card.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppColor.separator.opacity(0.5), lineWidth: 0.5))
            if missing > 0 {
                Text("Greyed-out tracks are on this release but not in your digital collection.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func playTotal(_ row: AlbumTracklist.Row) -> PlayTotal? {
        if case .owned(let t, _) = row { return model.playTotals[t.id] }
        return nil
    }

    private func play(_ list: [Track], at index: Int) {
        guard list.indices.contains(index) else { return }
        model.player.play(queue: list, startAt: index, source: title)
    }
}

struct AlbumTrackRow: View {
    @Environment(AppModel.self) private var model
    let row: AlbumTracklist.Row
    let albumArtist: String
    let total: PlayTotal?
    /// A record's side and track ("A1", "B2") where the release prints them, instead of the track number.
    var showsPositions = false
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        switch row {
        case .owned(let track, let entry): owned(track, entry)
        case .missing(let entry): missing(entry)
        }
    }

    private func owned(_ track: Track, _ entry: TracklistEntry?) -> some View {
        let isCurrent = model.player.currentTrack?.id == track.id
        return HStack(spacing: 12) {
            ZStack {
                if hovering { Image(systemName: "play.fill").font(.caption) }
                else if isCurrent { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(AppColor.accent) }
                else {
                    Text((showsPositions ? entry?.position : nil) ?? track.trackNo.map(String.init) ?? entry.map { String($0.number) } ?? "")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
                if !track.artist.isEmpty, ArtistInfoStore.key(track.artist) != ArtistInfoStore.key(albumArtist) {
                    PersonLinks(names: CollaborationGraph.splitArtists(track.artist)) { model.showMusicDNA($0) }.font(.caption)
                }
            }
            Spacer()
            RipCheckMark(check: model.ripChecks[track.id])
            LikeButton(model: model, track: track, showsUnliked: hovering)
            if let plays = total?.plays, plays > 0 {
                Text("\(plays)×").font(.caption).foregroundStyle(.secondary).monospacedDigit().help("\(plays) plays")
            }
            Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hovering ? AppColor.fill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            QueueMenuButtons(player: model.player) { [track] }
            LikeMenuButton(tracks: [track])
            Menu("Add to Playlist") {
                ForEach(model.playlists) { p in Button(p.name) { model.add([track.id], toPlaylist: p.id) } }
                if !model.playlists.isEmpty { Divider() }
                Button("New Playlist…") { model.createPlaylist(adding: [track.id]) }
            }
            AddToExportListButton(tracks: [track])
            Divider()
            Button("Show in Finder") { model.showInFinder([track]) }
            RemoveFromLibraryButton(tracks: [track])
        }
        .help("Double-click to play")
    }

    private func missing(_ entry: TracklistEntry) -> some View {
        HStack(spacing: 12) {
            Text(showsPositions ? entry.displayPosition : String(entry.number)).monospacedDigit().frame(width: 24)
            Text(entry.title).lineLimit(1)
            Spacer()
            Text("Not in digital collection").font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().strokeBorder(AppColor.separator, lineWidth: 0.5))
            Text(entry.duration.map(formatTime) ?? "").monospacedDigit().frame(width: 46, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .opacity(0.6)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}

/// Five stars with halves, plus the vote count.
struct RatingView: View {
    let rating: Double
    let votes: Int

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0..<5) { i in
                    let fill = rating - Double(i)
                    Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                }
            }
            .foregroundStyle(AppColor.accent)
            Text(String(format: "%.1f", rating)).monospacedDigit().fontWeight(.semibold)
            Text("· \(votes) MusicBrainz rating\(votes == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.callout)
        .help("Community rating on MusicBrainz")
    }
}

/// The cover, blurred and tinted toward the window background, filling the page.
struct AlbumBackdrop: View {
    let image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppColor.background
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 70)
                        .opacity(0.55)
                        .clipped()
                    LinearGradient(colors: [AppColor.background.opacity(0.35), AppColor.background.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .ignoresSafeArea()
    }
}
