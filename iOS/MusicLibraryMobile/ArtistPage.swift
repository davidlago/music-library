import MusicLibraryCore
import SwiftUI

/// The artist page, top to bottom: the photo on a blurred backdrop with who they are (summary, genres), Play and
/// Music DNA, whether they're on this iPhone, your listening, the bio, links, concerts near you, what of theirs is in
/// your collection, their albums and their most played songs. Also opens for artists who are only in the collection. The same as the Mac's, from the info the Mac cached in the library.
struct ArtistPage: View {
    @Environment(PhoneModel.self) private var model
    /// The artist's name (`ArtistSummary.name`, or an item's artist for one only in the collection).
    let name: String

    init(artist: ArtistSummary) { name = artist.name }
    init(name: String) { self.name = name }

    var body: some View {
        if let library = model.library {
            ArtistPageContent(artistName: name, library: library, tracks: library.tracks(artist: name),
                              albums: library.albums(artist: name), info: library.artistInfo(name))
        } else {
            LibraryStatusView()
        }
    }
}

private struct ArtistPageContent: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let artistName: String
    let library: LibrarySnapshot
    let tracks: [Track]
    let albums: [AlbumSummary]
    let info: ArtistInfo?
    @State private var showAllSongs = false

    private var name: String { artistName.isEmpty ? "Unknown Artist" : artistName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if !tracks.isEmpty {
                    AvailabilityBar(item: .artist(artistName), tracks: tracks, noun: "artist")
                    statTiles
                }
                if let bio = info?.bio, let info {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About")
                        ExpandableText(text: bio, lines: 5, source: info.bioSource, sourceURL: info.bioURL, credit: library.photoCredit(artistName))
                    }
                } else if let credit = library.photoCredit(artistName) {
                    if let url = credit.url?.webLink { Link("Photo: \(credit.label)", destination: url).font(.caption) }
                    else { Text("Photo: \(credit.label)").font(.caption).foregroundStyle(.secondary) }
                }
                if let links = info?.links.filter(\.url.isWebLink), !links.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Links")
                        LinkChips(links: links)
                    }
                }
                ArtistConcertsSection(artist: artistName, mbid: info?.mbid)
                collectionSection
                if !albums.isEmpty { albumsSection }
                if !tracks.isEmpty { songsSection }
                if info == nil, !artistName.isEmpty {
                    Text("The photo, bio and links come from the Mac once it has looked up this artist.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .radioDJ { [model, artistName, tracks, albums, info] in
            model.radioDJSubject(artist: artistName, tracks: tracks, albums: albums, info: info)
        }
    }

    // MARK: Hero

    private var hero: some View {
        let playable = model.playable(tracks)
        return VStack(spacing: 10) {
            ArtistPhoto(name: artistName, size: 170)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .padding(.top, 12)
            Text("ARTIST").font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1.2)
            Text(name).font(.largeTitle.bold()).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
            if let info {
                let summary = [info.summary(), info.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if !info.genres.isEmpty { GenreChips(genres: info.genres) }
            }
            HStack(spacing: 10) {
                Button { player.play(queue: playable, source: name) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(playable.isEmpty)
                Button { player.play(queue: playable.shuffled(), source: name) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(playable.isEmpty)
                Menu {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(playable) }
                        .disabled(playable.isEmpty)
                    Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(playable) }
                        .disabled(playable.isEmpty)
                    if library.collaborations.person(named: artistName) != nil {
                        NavigationLink(value: DNARoute(name: artistName)) {
                            Label("Music DNA", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(height: 20)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("More")
            }
            .controlSize(.large)
            .padding(.top, 6)
            if library.collaborations.person(named: artistName) != nil {
                NavigationLink(value: DNARoute(name: artistName)) {
                    Label("See who \(name) worked with", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .background { ArtistBackdrop(url: library.artistImageURL(artistName)) }
    }

    private var statTiles: some View {
        let p = model.artistPlayTotal(artistName)
        let total = tracks.reduce(0) { $0 + $1.duration }
        return StatGrid {
            StatTile(value: tracks.count.formatted(), label: tracks.count == 1 ? "Song" : "Songs", icon: "music.note")
            StatTile(value: albums.count.formatted(), label: albums.count == 1 ? "Album" : "Albums", icon: "square.stack")
            StatTile(value: formatLongDuration(total), label: "Total length", icon: "clock")
            StatTile(value: formatListened(p.listened), label: "Time listened", icon: "headphones")
            StatTile(value: p.plays.formatted(), label: p.plays == 1 ? "Play" : "Plays", icon: "play.circle")
            StatTile(value: p.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                     label: "Last played", icon: "calendar")
            if let scrobbles = info?.lastfmUserPlaycount, scrobbles > 0 {
                StatTile(value: scrobbles.formatted(), label: "Last.fm scrobbles", icon: "dot.radiowaves.left.and.right")
            }
        }
    }

    // MARK: Collection, albums and songs

    /// Their CDs and records you own, ripped or not (downloads are digital: they're among the albums below).
    @ViewBuilder
    private var collectionSection: some View {
        let items = model.collection.items(artist: artistName).filter(\.medium.isPhysical)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "In Your Physical Collection")
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionCell(item: item, width: 150) }
                                .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .padding(.horizontal, -20)
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "In Your Digital Collection")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            AlbumCell(album: a, library: library, size: 150,
                                      subtitle: [a.year.map(String.init), songCount(a.trackCount)].compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { AlbumMenu(album: a) }
                        .environment(\.explainsMarksOnPress, false)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .padding(.horizontal, -20)
        }
    }

    private var songsSection: some View {
        let ranked = rankedTracks
        let anyPlays = ranked.contains { (model.playTotals[$0.id]?.plays ?? 0) > 0 }
        let shown = showAllSongs ? ranked : Array(ranked.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: anyPlays ? "Most Played" : "Songs")
                if ranked.count > 8 {
                    Button(showAllSongs ? "Show Fewer" : "Show All \(ranked.count)") { withAnimation(.snappy) { showAllSongs.toggle() } }
                        .font(.callout.weight(.medium))
                        .fixedSize()
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    ArtistSongRow(index: i + 1, track: t, ranked: ranked, source: name)
                    if i < shown.count - 1 { Divider().padding(.leading, 50) }
                }
            }
            .padding(.vertical, 4)
            .card()
        }
    }

    /// Most played first, then album order.
    private var rankedTracks: [Track] {
        tracks.enumerated().sorted { a, b in
            let pa = model.playTotals[a.element.id]?.plays ?? 0, pb = model.playTotals[b.element.id]?.plays ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
    }
}

private struct ArtistSongRow: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let index: Int
    let track: Track
    let ranked: [Track]
    let source: String
    @State private var offerDownload = false

    var body: some View {
        let isCurrent = player.currentTrack?.id == track.id
        let present = model.isPresent(track)
        let plays = model.playTotals[track.id]?.plays ?? 0
        let liked = model.isLiked(track)
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
                Text([track.album, track.year.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                     + (plays > 0 ? " · \(playCount(plays))" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !present { AvailabilityMark(availability: .notOnPhone, pending: model.pendingDownloads.contains(track.id)) }
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.pink : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityLabel(liked ? "Unlike" : "Like")
            Text(Format.time(track.duration)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .opacity(present ? 1 : 0.5)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard present else { offerDownload = true; return }
            let playable = model.playable(ranked)
            player.play(queue: playable, startAt: playable.firstIndex(of: track) ?? 0, source: source)
        }
        .contextMenu { SongMenu(track: track) }
        .accessibilityAddTraits(.isButton)
        .confirmationDialog("“\(track.title)” isn't on this iPhone", isPresented: $offerDownload, titleVisibility: .visible) {
            if model.sync.isPaired {
                Button("Download Song") { model.download(.track(track.id)) }
                if let album = model.library?.album(of: track) {
                    Button("Download Album") { model.download(.album(album: album.album, artist: album.artist)) }
                }
            }
        } message: {
            Text(model.sync.isPaired ? "Download it from your Mac to play it here." : "Pair with your Mac in the Sync tab to download music.")
        }
    }
}

/// The artist's photo, blurred, behind the top of the page.
private struct ArtistBackdrop: View {
    let url: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PhotoImage(url: url, size: 100)
                    .scaleEffect(max(geo.size.width, geo.size.height) / 100 * 1.2)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 40)
                    .opacity(0.4)
                    .clipped()
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0.1), Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .padding(.horizontal, -20)
        .padding(.top, -200)
        .accessibilityHidden(true)
    }
}

// MARK: Concerts

/// Upcoming concerts near home, with the Mac's concert settings (sent at each sync).
struct ArtistConcertsSection: View {
    @Environment(PhoneModel.self) private var model
    let artist: String
    let mbid: String?
    @State private var showAll = false

    var body: some View {
        let store = model.concerts
        if !artist.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Concerts Near You")
                    if store.isConfigured {
                        Button { store.load(artist: artist, mbid: mbid, force: true) } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isLoading(artist))
                        .accessibilityLabel("Refresh")
                    }
                }
                if store.isConfigured {
                    Text(store.areaDescription.prefix(1).uppercased() + store.areaDescription.dropFirst())
                        .font(.footnote).foregroundStyle(.secondary)
                }
                content(store)
            }
            .task(id: "\(artist)|\(store.isConfigured)|\(store.areaDescription)") {
                store.load(artist: artist, mbid: mbid)
            }
        }
    }

    @ViewBuilder
    private func content(_ store: PhoneConcerts) -> some View {
        if !store.isConfigured {
            Label("Set your ZIP code and a free Ticketmaster or JamBase key in Music Library's settings on the Mac, then sync, to see when artists play near you.",
                  systemImage: "ticket")
                .font(.callout).foregroundStyle(.secondary)
        } else if let found = store.concerts(for: artist) {
            let concerts = found.concerts
            if concerts.isEmpty {
                Text(store.isLoading(artist) ? "Checking for new dates…" : "No upcoming concerts \(store.areaDescription).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let shown = showAll ? concerts : Array(concerts.prefix(5))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                        ConcertRow(concert: c, store: store, pageArtist: artist)
                        if i < shown.count - 1 { Divider().padding(.leading, 72) }
                    }
                }
                .padding(.vertical, 4)
                .card()
                if concerts.count > 5 {
                    Button(showAll ? "Show Fewer" : "Show All \(concerts.count) Concerts") { withAnimation(.snappy) { showAll.toggle() } }
                        .font(.callout.weight(.medium))
                }
            }
            footer(found)
        } else if store.isLoading(artist) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking for concerts \(store.areaDescription)…").font(.callout).foregroundStyle(.secondary)
            }
        }
        if let error = store.error(for: artist) {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        ForEach(store.warnings(for: artist), id: \.self) { w in
            Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func footer(_ found: NearbyConcerts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if found.elsewhereCount > 0 {
                Text("\(found.elsewhereCount) more show\(found.elsewhereCount == 1 ? "" : "s") farther away").foregroundStyle(.secondary)
            }
            ForEach(found.bySource.filter { $0.artistURL?.webLink != nil }, id: \.source) { s in
                Link("All dates on \(s.source.name)", destination: s.artistURL!)
            }
            let sources = found.bySource.map(\.source)
            if !sources.isEmpty {
                HStack(spacing: 4) {
                    Text("Concert listings from").foregroundStyle(.secondary)
                    ForEach(Array(sources.enumerated()), id: \.element) { i, s in
                        if i > 0 { Text(i == sources.count - 1 ? "and" : ",").foregroundStyle(.secondary) }
                        Link(s.name, destination: s.homepage)
                    }
                }
            }
        }
        .font(.caption)
    }
}

/// One concert on an artist's page: the date, the venue, where and when, the tour or who else plays, the price
/// and a link to tickets.
private struct ConcertRow: View {
    let concert: Concert
    let store: PhoneConcerts
    /// The artist whose page this is, to leave out of "with …".
    let pageArtist: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            dateTile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(concert.venue).font(.headline).lineLimit(2)
                    statusBadge
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let extra { Text(extra).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let price = priceText { Text(price).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 6)
            if let url = concert.url?.webLink {
                Link(destination: url) {
                    Image(systemName: "ticket")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(concert.sources.first == .ticketmaster ? "Tickets" : "Details")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .opacity(concert.status == .cancelled ? 0.6 : 1)
        .contextMenu {
            if let url = concert.url?.webLink {
                Link(destination: url) { Label("Open on \(concert.sources.first?.name ?? "the Web")", systemImage: "safari") }
                ShareLink(item: url)
                Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
            }
        }
    }

    /// A calendar-page date: "NOV" over "2".
    private var dateTile: some View {
        let date = concert.day.date()
        return VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
            Text(date.formatted(.dateTime.day())).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 56)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
    }

    /// "Boston, MA · 3 mi · 7:30 PM"
    private var details: String {
        [concert.place, store.distance(concert.distanceKm), concert.formattedTime()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tour or festival, or who else is playing.
    private var extra: String? {
        if let title = concert.title(for: pageArtist) { return title }
        let others = concert.otherActs(than: pageArtist)
        guard !others.isEmpty else { return nil }
        let shown = others.prefix(3)
        return "with " + ListFormatter.localizedString(byJoining: Array(shown)) + (others.count > 3 ? " and more" : "")
    }

    private var priceText: String? {
        guard let price = concert.minPrice, price > 0, let currency = concert.currency else { return nil }
        return "from " + price.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }

    @ViewBuilder
    private var statusBadge: some View {
        let label: String? = switch concert.status {
        case .cancelled: "Cancelled"
        case .postponed: "Postponed"
        case .rescheduled: "Rescheduled"
        case .scheduled: nil
        }
        if let label {
            Text(label).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: Song info

/// Everything about one song, as the Mac's Song Info: tags, format, MusicBrainz IDs, the file, extra details and
/// credits (names open Music DNA).
struct SongInfoSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var path = NavigationPath()

    var body: some View {
        let m = track.metadata
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        CoverImage(url: model.library.flatMap { track.coverURL(root: $0.root) }, size: 90)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(.headline)
                            Text(m.artist)
                            Text(m.album).foregroundStyle(.secondary)
                            if !model.isPresent(track) {
                                Label("Not on this iPhone", systemImage: "icloud").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                            }
                        }
                    }
                }
                Section {
                    row("Album Artist", m.albumArtist)
                    if !m.composer.isEmpty { people("Composer", CollaborationGraph.splitNames(m.composer)) }
                    row("Year", m.year.map(String.init) ?? "")
                    row("Track", numberPair(m.trackNo, m.trackTotal))
                    row("Disc", numberPair(m.discNo, m.discTotal))
                    row("Genre", m.genre)
                    row("Format", track.format.uppercased())
                    row("Codec", track.audioFormat?.codecLabel ?? "")
                    row("Sample Rate", track.audioFormat?.sampleRate.map { "\(AudioFormat.kHzString(Double($0))) kHz" } ?? "")
                    row("Bit Depth", track.audioFormat?.bitDepth.map { "\($0)-bit" } ?? "")
                    row("Bitrate", track.audioFormat?.bitrate.map { "\(($0 + 500) / 1000) kbps" } ?? "")
                    row("Channels", track.audioFormat?.channels.map(String.init) ?? "")
                    row("Duration", Format.time(track.duration))
                    row("Plays", model.playTotals[track.id].map { "\($0.plays) · \(formatListened($0.listened)) listened" } ?? "")
                    row("MusicBrainz Recording ID", m.mbRecordingId ?? "")
                    row("MusicBrainz Release ID", m.mbReleaseId ?? "")
                    row("File", track.path)
                }
                let fields = m.extended.displayFields
                if !fields.isEmpty {
                    Section("Details") {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                            if Self.peopleFields.contains(field.label) {
                                people(field.label, CollaborationGraph.splitNames(field.value).map(CollaborationGraph.stripParenthetical))
                            } else {
                                row(field.label, field.value)
                            }
                        }
                    }
                }
                let credits = CreditFormatter.grouped(m.extended.credits)
                if !credits.isEmpty {
                    Section("Credits") {
                        ForEach(Array(credits.enumerated()), id: \.offset) { _, p in
                            NavigationLink(value: DNARoute(name: p.name)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                    Text(p.roles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .libraryDestinations(djButton: false)
        }
        .environment(\.openRoute, OpenRouteAction { value in path.append(value) })
    }

    /// Fields whose values are people's names.
    static let peopleFields: Set<String> = ["Lyricist", "Writer", "Arranger", "Conductor", "Producer", "Engineer", "Mixer", "Remixer", "Performers"]

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
        }
    }

    private func people(_ label: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            PersonLinks(names: names)
        }
    }

    private func numberPair(_ n: Int?, _ total: Int?) -> String {
        guard let n else { return "" }
        return total.map { "\(n) of \($0)" } ?? "\(n)"
    }
}
