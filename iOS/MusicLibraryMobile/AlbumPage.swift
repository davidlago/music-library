import MusicLibraryCore
import SwiftUI

/// The album page, top to bottom: the cover on a blurred backdrop with what the album is (type, year, artist,
/// label, length, quality, rating, genres), whether it's on this iPhone, Play, your listening, the track list
/// (with the release's tracks you don't have greyed out), your copies (CDs, records, downloads), then the
/// description, reviews, release details, credits and links. The same as the Mac's, from the info the Mac cached in the library.
struct AlbumPage: View {
    @Environment(PhoneModel.self) private var model
    let album: AlbumSummary

    var body: some View {
        if let library = model.library {
            AlbumPageContent(album: album, library: library, tracks: library.tracks(album: album), info: library.albumInfo(album))
        } else {
            LibraryStatusView()
        }
    }
}

private struct AlbumPageContent: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let album: AlbumSummary
    let library: LibrarySnapshot
    let tracks: [Track]
    let info: AlbumInfo?
    @State private var showAllCredits = false

    private var title: String { album.album.isEmpty ? "Unknown Album" : album.album }
    private var item: ExportItem { .album(album: album.album, artist: album.artist) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                AvailabilityBar(item: item, tracks: tracks, noun: "album")
                playButtons
                listening
                AlbumTrackList(album: album, tracks: tracks, info: info, source: title)
                YourCopiesSection(albumKey: SearchIndex.albumKey(album: album.album, artist: album.artist),
                                  plays: tracks.reduce(0) { $0 + (model.playTotals[$1.id]?.plays ?? 0) })
                if let text = info?.description, let info {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About")
                        ExpandableText(text: text, source: info.descriptionSource, sourceURL: info.descriptionURL)
                    }
                }
                if let reviews = info?.reviews.filter(\.url.isWebLink), !reviews.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Reviews")
                        LinkChips(links: reviews)
                    }
                }
                details
                credits
                if let links = info?.links.filter({ $0.kind != .review && $0.url.isWebLink }), !links.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Links")
                        LinkChips(links: links)
                    }
                }
                if info == nil, !album.album.isEmpty {
                    Text("The description, rating, links and full track list come from the Mac once it has looked up this album.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background { AlbumBackdrop(url: library.coverURL(album: album)) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu { AlbumMenu(album: album) } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            CopyArt(mark: model.copyMark(for: album), url: library.coverURL(album: album), width: 310, title: album.album)
            .padding(.top, 8)
            .padding(.bottom, 8)
            Text(typeLine).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center).textSelection(.enabled)
            artistButton
            if let meta = metaLine {
                Text(meta).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let info, let rating = info.rating { RatingView(rating: rating, votes: info.ratingVotes) }
            let genres = displayGenres
            if !genres.isEmpty { GenreChips(genres: genres).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artistButton: some View {
        let name = album.artist.isEmpty ? "Unknown Artist" : album.artist
        if let artist = library.artist(named: album.artist) {
            NavigationLink(value: artist) {
                HStack(spacing: 8) {
                    ArtistPhoto(name: artist.name, size: 26)
                    Text(name).font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(name).font(.title3.weight(.medium))
        }
    }

    private var typeLine: String {
        var parts = [(info?.typeLabel ?? "Album").uppercased()]
        if let y = info?.firstReleaseYear ?? album.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    private var metaLine: String? {
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

    private var displayGenres: [String] {
        if let g = info?.genres, !g.isEmpty { return g }
        var seen = Set<String>()
        return tracks.flatMap { SearchIndex.genres(of: $0.metadata) }.filter { seen.insert($0.lowercased()).inserted }.prefix(5).map { $0 }
    }

    private var playButtons: some View {
        let playable = model.playable(tracks)
        return HStack(spacing: 10) {
            Button { player.play(queue: playable, source: title) } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { player.play(queue: playable.shuffled(), source: title) } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Menu {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(playable) }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(playable) }
            } label: {
                Image(systemName: "ellipsis").frame(height: 20)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Play Next or Add to Queue")
        }
        .controlSize(.large)
        .disabled(playable.isEmpty)
    }

    /// Your listening history for the album: plays (listens that reached half the track or 4 minutes), all time
    /// actually listened, when you last played it and the track you play most.
    private var listening: some View {
        let totals = tracks.map { ($0, model.playTotals[$0.id] ?? PlayTotal()) }
        let total = totals.map(\.1).reduce(PlayTotal(), +)
        let top = totals.filter { $0.1.plays > 0 }.max { $0.1.plays != $1.1.plays ? $0.1.plays < $1.1.plays : $0.1.listened < $1.1.listened }
        return StatGrid {
            StatTile(value: total.plays.formatted(), label: total.plays == 1 ? "Play" : "Plays", icon: "play.circle")
            StatTile(value: formatListened(total.listened), label: "Time listened", icon: "headphones")
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

    private func firstValue(_ path: KeyPath<ExtendedMetadata, String>) -> String? {
        tracks.lazy.map { $0.metadata.extended[keyPath: path] }.first { !$0.isEmpty }
    }

    @ViewBuilder
    private var details: some View {
        let rows: [(String, String)] = [
            ("Record label", firstValue(\.label)), ("Catalog #", firstValue(\.catalogNumber)),
            ("Released", firstValue(\.releaseDate)), ("Original release", firstValue(\.originalDate)),
            ("Country", firstValue(\.releaseCountry).map(countryName)),
            ("Media", firstValue(\.mediaFormat)), ("Packaging", firstValue(\.packaging).flatMap { $0 == "None" ? nil : $0 }),
            ("Barcode", firstValue(\.barcode)),
        ].compactMap { k, v in v.map { (k, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Release")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        LabeledContent(row.0) { Text(row.1).textSelection(.enabled).multilineTextAlignment(.trailing) }
                            .font(.callout)
                            .padding(.vertical, 9).padding(.horizontal, 14)
                        if i < rows.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .card()
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
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.name) { i, p in
                        NavigationLink(value: DNARoute(name: p.name)) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).fontWeight(.medium)
                                    Text(p.roles.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                if tracks.count > 1 {
                                    Text(p.tracks == tracks.count ? "all tracks" : "\(p.tracks) track\(p.tracks == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            NavigationLink(value: DNARoute(name: p.name)) { Label("Show Music DNA", systemImage: "point.3.connected.trianglepath.dotted") }
                            NavigationLink(value: QueryRoute(query: SearchFilterKey.token("credit", p.name), title: p.name)) {
                                Label("Find Songs They're Credited On", systemImage: "magnifyingglass")
                            }
                        }
                        if i < shown.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .card()
                if all.count > 10 {
                    Button(showAllCredits ? "Show Fewer" : "Show All \(all.count)") { withAnimation(.snappy) { showAllCredits.toggle() } }
                        .font(.callout.weight(.medium))
                }
            }
        }
    }
}

// MARK: Tracks

/// The release's track list with the library's songs filled in: songs not on the phone are dimmed (tap to
/// download), and the release's tracks that aren't in the library are greyed out. Records show their sides ("A1").
/// For a collection item with no digital copy (`album` nil, no tracks), just the release's tracks.
struct AlbumTrackList: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let album: AlbumSummary?
    let tracks: [Track]
    let info: AlbumInfo?
    let source: String
    @State private var missing: Track?

    /// Nothing of it is in the library: every row is greyed out, without saying so on each.
    private var trackless: Bool { tracks.isEmpty }

    var body: some View {
        let rows = AlbumTracklist.merge(library: tracks, tracklist: info?.tracklist ?? [])
        let discs = Array(Set(rows.map(\.disc))).sorted()
        let notInLibrary = rows.filter { if case .missing = $0 { true } else { false } }.count
        let owned = rows.compactMap { if case .owned(let t, _) = $0 { t } else { nil } }
        if !rows.isEmpty {
            content(rows: rows, discs: discs, notInLibrary: notInLibrary, owned: owned)
        }
    }

    private func content(rows: [AlbumTracklist.Row], discs: [Int], notInLibrary: Int, owned: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Tracks")
                if notInLibrary > 0, !trackless {
                    Text("\(owned.count) of \(rows.count) in your library").font(.footnote).foregroundStyle(.secondary).fixedSize()
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
                        .padding(.horizontal, 14).padding(.top, disc == discs.first ? 12 : 18).padding(.bottom, 4)
                    }
                    ForEach(rows.filter { $0.disc == disc }) { row in
                        switch row {
                        case .owned(let track, let entry): ownedRow(track, entry, all: owned)
                        case .missing(let entry): missingRow(entry)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .card()
            if trackless {
                Text("The track list of the release, from MusicBrainz.").font(.caption).foregroundStyle(.secondary)
            } else if notInLibrary > 0 {
                Text("Greyed-out tracks are on this release but not in your library.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("“\(missing?.title ?? "")” isn't on this iPhone", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } }),
                            titleVisibility: .visible, presenting: missing) { track in
            if model.sync.isPaired {
                Button("Download Song") { model.download(.track(track.id)) }
                if let album {
                    Button("Download Album") { model.download(.album(album: album.album, artist: album.artist)) }
                }
            }
        } message: { _ in
            Text(model.sync.isPaired ? "Download it from your Mac to play it here." : "Pair with your Mac in the Sync tab to download music.")
        }
    }

    private func ownedRow(_ track: Track, _ entry: TracklistEntry?, all: [Track]) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let present = model.isPresent(track)
        let plays = model.playTotals[track.id]?.plays ?? 0
        let liked = model.isLiked(track)
        return HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
                } else {
                    Text(entry?.position ?? track.trackNo.map(String.init) ?? entry.map { String($0.number) } ?? "")
                        .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(2).fontWeight(isCurrent ? .semibold : .regular)
                if !track.artist.isEmpty, LibrarySnapshot.artistKey(track.artist) != LibrarySnapshot.artistKey(album?.artist ?? track.effectiveAlbumArtist) {
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !present {
                AvailabilityMark(availability: .notOnPhone, pending: model.pendingDownloads.contains(track.id))
            }
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.pink : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityLabel(liked ? "Unlike" : "Like")
            if plays > 0 {
                Text("\(plays)×").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("\(plays) plays")
            }
            Text(Format.time(track.duration)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .opacity(present ? 1 : 0.5)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard present else { missing = track; return }
            let playable = model.playable(all)
            player.play(queue: playable, startAt: playable.firstIndex(of: track) ?? 0, source: source)
        }
        .contextMenu { SongMenu(track: track) }
        .accessibilityAddTraits(.isButton)
    }

    private func missingRow(_ entry: TracklistEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.displayPosition).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).frame(width: 28)
            Text(entry.title).lineLimit(2)
            Spacer(minLength: 6)
            if !trackless {
                Text("Not in library").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    .fixedSize()
            }
            Text(entry.duration.map(Format.time) ?? "").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .opacity(trackless ? 0.8 : 0.6)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

// MARK: Your copies

/// "Your Copies": every copy of the album in your collection (CDs by label number, records, downloads), each opening
/// its item page, with how long it's been yours and what each play cost. Read-only: the collection is edited on the
/// Mac. Shown only when you own a copy.
struct YourCopiesSection: View {
    @Environment(PhoneModel.self) private var model
    let albumKey: String
    /// All-time plays of the album's tracks.
    let plays: Int

    var body: some View {
        let copies = model.collection.copies(albumKey: albumKey)
        if !copies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: copies.count == 1 ? "Your Copy" : "Your Copies")
                VStack(spacing: 0) {
                    ForEach(Array(copies.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 74) }
                        NavigationLink(value: CollectionItemRoute(id: item.id)) {
                            CopyRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .card()
                if let summary = summary(copies) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Yours since 2009 · 34 plays · $0.41 a play".
    private func summary(_ copies: [CollectionItem]) -> String? {
        var parts: [String] = []
        if let first = copies.compactMap(\.purchasedOn).min() {
            parts.append("Yours since \(first.date().formatted(.dateTime.year()))")
        }
        if plays > 0 { parts.append(playCount(plays)) }
        let spent = copies.compactMap(\.price).reduce(0, +)
        if spent > 0, plays > 0 { parts.append("\(formatMoney(spent / Decimal(plays))) a play") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One copy in a list: its case or sleeve, label, medium and format, when you bought it, what you paid and where its
/// digital copy came from.
struct CopyRow: View {
    @Environment(PhoneModel.self) private var model
    let item: CollectionItem

    var body: some View {
        let state = model.collection.digitalState(item)
        HStack(spacing: 12) {
            CopyArt(mark: model.copyMark(for: item), url: model.library?.coverURL(item: item), width: 50, title: nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let sticker = item.sticker { StickerPill(sticker: sticker, size: 11) }
                    Text(mediumLine).font(.subheadline.weight(.medium)).lineLimit(1)
                }
                let bought = [item.purchasedOn.map { $0.date().formatted(date: .abbreviated, time: .omitted) },
                              item.price.map { formatMoney($0) }].compactMap { $0 }
                if !bought.isEmpty {
                    Text(bought.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                DigitalStatusLabel(item: item, state: state, collection: model.collection)
                    .font(.caption)
            }
            Spacer(minLength: 6)
            InsightChevron()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    /// "CD", "2×CD", "12\" Vinyl", "Download (bought as songs)".
    private var mediumLine: String {
        if item.origin == .songs { return "Songs bought as downloads" }
        if case .other(let raw) = item.medium { return raw.capitalized }
        return item.formatDetail ?? item.medium.name
    }
}

// MARK: Backdrop

/// The cover, blurred and faded toward the background, behind the page.
struct AlbumBackdrop: View {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemGroupedBackground)
                PhotoImage(url: url, size: 120)
                    .scaleEffect(max(geo.size.width, geo.size.height) / 120 * 1.2)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 50)
                    .opacity(0.45)
                    .clipped()
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0.2), Color(.systemGroupedBackground).opacity(0.85),
                                        Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
