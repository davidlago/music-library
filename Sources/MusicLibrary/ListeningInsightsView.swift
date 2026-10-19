import AppKit
import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Listening pane of Insights, laid out like a listening report: a banner with the period's plays against the
/// span before, your top artists, albums and songs with their pictures, what was new to you, when and what eras you
/// play, and quick facts.
struct ListeningContent: View {
    let stats: ListeningStats
    @Binding var period: ListeningStats.Period
    @AppStorage("listeningMeasure") private var measure = ListeningMeasure.plays

    var body: some View {
        if !stats.hasHistory {
            ContentUnavailableView("No Listening History Yet", systemImage: "headphones",
                                   description: Text("Play some music and this page fills in with what, when and how much you listen."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if stats.listens == 0 {
                        InsightCard(title: "Nothing played in the last \(stats.period.rawValue.lowercased())") {
                            Text("Your listening history goes back to \(stats.firstListen!.formatted(date: .long, time: .omitted)). Pick a longer period above, or press play.")
                                .font(.callout).foregroundStyle(.subtext)
                        }
                    } else {
                        ListeningHero(stats: stats)
                        ListeningSection(title: "Top Charts") {
                            Picker("Rank by", selection: $measure) { ForEach(ListeningMeasure.allCases) { Text($0.rawValue).tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                .help("Rank by plays or by time spent listening")
                        }
                        EvenRow(count: stats.albums.byTime.isEmpty ? 2 : 3) {
                            SpotlightCard(kind: .artist, ranking: stats.artists, previous: stats.previous?.artists, measure: measure)
                            if !stats.albums.byTime.isEmpty {
                                SpotlightCard(kind: .album, ranking: stats.albums, previous: stats.previous?.albums, measure: measure)
                            }
                            SpotlightCard(kind: .song, ranking: stats.songs, previous: stats.previous?.songs, measure: measure)
                        }
                        if stats.showsDiscoveries {
                            EvenRow(count: stats.albums.total > 0 ? 3 : 2) {
                                DiscoveryTile(kind: .artist, new: stats.newArtists, all: stats.artists.total)
                                if stats.albums.total > 0 { DiscoveryTile(kind: .album, new: stats.newAlbums, all: stats.albums.total) }
                                DiscoveryTile(kind: .song, new: stats.newSongs, all: stats.songs.total)
                            }
                        }
                        ListeningSection(title: "Patterns")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                            ListeningClockCard(stats: stats)
                            if !stats.eras.isEmpty { DecadesCard(stats: stats) }
                            if !stats.genres.byPlays.isEmpty { ListenedGenresCard(stats: stats) }
                            if !stats.mostSkipped.isEmpty { SkippedCard(stats: stats) }
                            if !stats.forgotten.isEmpty { RediscoverCard(stats: stats) }
                        }
                        ListeningSection(title: "Quick Facts")
                        QuickFacts(stats: stats)
                        InsightCard(title: "Fun Facts") { FactsGrid(facts: ListeningFacts.facts(stats)) }
                    }
                    if stats.listens == 0, !stats.forgotten.isEmpty { RediscoverCard(stats: stats) }
                }
                .padding(20)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(range).font(.callout.weight(.medium)).foregroundStyle(.subtext)
            Spacer()
            Picker("Period", selection: $period) { ForEach(ListeningStats.Period.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var range: String {
        if stats.period == .all { return "Since \(stats.firstListen!.formatted(date: .long, time: .omitted))" }
        return "\(stats.start!.formatted(.dateTime.month(.abbreviated).day().year())) – \(stats.now.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

enum ListeningMeasure: String, CaseIterable, Identifiable {
    case plays = "Plays", time = "Time"
    var id: String { rawValue }
}

/// What a ranked item is, for its picture and where clicking it goes.
enum ListeningKind {
    case artist, album, song

    var plural: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        case .song: "Songs"
        }
    }

    var top: String {
        switch self {
        case .artist: "Top Artist"
        case .album: "Top Album"
        case .song: "Top Song"
        }
    }

    func count(_ n: Int) -> String {
        switch self {
        case .artist: n == 1 ? "1 artist" : "\(n.formatted()) artists"
        case .album: n == 1 ? "1 album" : "\(n.formatted()) albums"
        case .song: n == 1 ? "1 song" : "\(n.formatted()) songs"
        }
    }
}

func playCount(_ n: Int) -> String { n == 1 ? "1 play" : "\(n.formatted()) plays" }

private func songQuery(_ item: ListeningStats.Item) -> String {
    SearchFilterKey.token("title", item.name) + (item.subtitle.isEmpty ? "" : " " + SearchFilterKey.token("artist", item.subtitle))
}

private func albumQuery(_ item: ListeningStats.Item) -> String {
    SearchFilterKey.token("album", item.name) + " " + SearchFilterKey.token("albumartist", item.subtitle)
}

/// "Night owl", "Early bird"… for the hour most listening happens in.
private func daypart(_ hour: Int) -> (name: String, title: String, icon: String) {
    switch hour {
    case 5..<12: ("mornings", "Early bird", "sunrise")
    case 12..<17: ("afternoons", "Afternoon listener", "sun.max")
    case 17..<22: ("evenings", "Evening listener", "sunset")
    default: ("late at night", "Night owl", "moon.stars")
    }
}

private func hourLabel(_ hour: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    return date.formatted(.dateTime.hour())
}

/// Full weekday name for an index in `ListeningStats.clock` order.
private func weekdayName(_ index: Int) -> String {
    let c = Calendar.current
    return c.weekdaySymbols[(index + c.firstWeekday - 1) % 7]
}

/// The span before the period, as the comparisons name it.
private func priorSpan(_ period: ListeningStats.Period) -> String {
    switch period {
    case .week: "the 7 days before"
    case .month: "the 30 days before"
    case .year: "the 12 months before"
    case .all: ""
    }
}

/// The change from `previous` to `current` as a fraction; nil when there's nothing to compare with.
private func change(_ current: Double, _ previous: Double?) -> Double? {
    guard let previous, previous > 0 else { return nil }
    return current / previous - 1
}

// MARK: Pictures

/// Opens what a ranked item is: an artist's page, an album, or a search for a song.
@MainActor
private func open(_ item: ListeningStats.Item, _ kind: ListeningKind, _ model: AppModel) {
    switch kind {
    case .artist:
        if item.name != "Unknown Artist" { model.showArtist(named: item.name) }
    case .album:
        if let album = model.album(forKey: String(item.id.dropFirst(3))) {
            model.navigationPath.append(album)
        } else {
            model.search(albumQuery(item))
        }
    case .song:
        model.search(songQuery(item))
    }
}

/// The artist's photo (or a cover of theirs), or the cover of the album or song.
private struct ListeningArt: View {
    @Environment(AppModel.self) private var model
    let item: ListeningStats.Item
    let kind: ListeningKind
    /// Called with the picture once it's loaded (nil when there's none), e.g. to take a color from it.
    var onLoad: ((NSImage?) -> Void)?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                // Filled, the picture reaches past the frame: clipping hides that but it would still take clicks.
                Image(nsImage: image).resizable().scaledToFill().allowsHitTesting(false)
            } else {
                Rectangle().fill(.quaternary)
                GeometryReader { geo in
                    Image(systemName: kind == .artist ? "music.mic" : "music.note")
                        .font(.system(size: max(10, min(geo.size.width, geo.size.height) / 3)))
                        .foregroundStyle(.subtext)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .clipped()
        .task(id: "\(item.id)|\(kind == .artist ? model.artistInfo.imageFile(for: item.name) ?? "" : "")|\(model.coverRevision)") {
            let loaded = await load()
            image = loaded
            onLoad?(loaded)
        }
    }

    private func load() async -> NSImage? {
        if kind == .artist, let photo = await model.artistInfo.image(for: item.name) { return photo }
        guard let id = item.trackId, let track = model.trackByID[id], let url = model.coverURL(for: track) else { return nil }
        return await ListeningCovers.image(url)
    }
}

/// Covers, decoded off the main thread and kept while the app runs (the pane shows the same few many times).
@MainActor
private enum ListeningCovers {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

/// A panel color taken from a picture, dark enough for white text.
private func panelTint(_ image: NSImage?) -> RGB? {
    guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let average = ArtworkTint.average(of: cg) else { return nil }
    return ArtworkTint.panel(from: average)
}

private extension ThemeColors {
    /// The panel color when there's no picture to take one from.
    var defaultPanel: RGB { ArtworkTint.panel(from: palette?.series ?? RGB(0x2a78d6)) }
}

/// One ranked item: rank, picture, name and the measure; clicking opens it.
private struct ListeningRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var rank: Int?
    let item: ListeningStats.Item
    let kind: ListeningKind
    let detail: String
    var size: CGFloat = 32
    @State private var hovered = false

    var body: some View {
        Button { open(item, kind, model) } label: {
            HStack(spacing: 10) {
                if let rank {
                    Text("#\(rank)").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.subtext)
                        .frame(minWidth: 28, alignment: .leading)
                }
                ListeningArt(item: item, kind: kind)
                    .frame(width: size, height: size)
                    .clipShape(kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).lineLimit(1)
                    if kind != .artist, !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(detail).monospacedDigit().foregroundStyle(.subtext).lineLimit(1)
            }
            .font(.callout)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu { ListeningItemMenu(item: item, kind: kind) }
        .help(kind == .song ? "Search for this song" : "Open \(item.name)")
    }
}

private struct ListeningItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: ListeningStats.Item
    let kind: ListeningKind

    var body: some View {
        let track = item.trackId.flatMap { model.trackByID[$0] }
        let album = track.flatMap { model.album(forKey: SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist)) }
        switch kind {
        case .song:
            if let track { Button("Play") { model.player.play(queue: [track], startAt: 0, source: "Insights") } }
            if let album { Button("Open Album") { model.navigationPath.append(album) } }
            if let track, !track.effectiveAlbumArtist.isEmpty {
                Button("Show Artist") { model.showArtist(named: track.effectiveAlbumArtist) }
            }
        case .album:
            if let album {
                Button("Play") { model.player.play(queue: model.tracks(of: album), startAt: 0, source: album.album) }
                Button("Open Album") { model.navigationPath.append(album) }
                Button("Show Artist") { model.showArtist(named: album.artist) }
            }
        case .artist:
            if item.name != "Unknown Artist" {
                Button("Show Artist") { model.showArtist(named: item.name) }
                Button("Show Music DNA") { model.showMusicDNA(item.name) }
                    .disabled(model.collaborations.person(named: item.name) == nil)
            }
        }
    }
}

// MARK: Building blocks

/// `count` cards side by side in equal columns, wrapping into even rows (6 as 3 + 3, not 5 + 1) when they don't fit at
/// `minWidth` each; an adaptive grid would leave an empty column on a wide window.
private struct EvenRow<Content: View>: View {
    let count: Int
    var minWidth: CGFloat = 250
    @ViewBuilder var content: () -> Content
    @State private var width: CGFloat = 0

    var body: some View {
        let fit = min(max(count, 1), max(1, Int((width + 14) / (minWidth + 14))))
        let columns = (1...fit).last { count % $0 == 0 && $0 > 1 } ?? fit
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns),
                  alignment: .leading, spacing: 14, content: content)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A bold section title with a short rule under it.
private struct ListeningSection<Accessory: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                Capsule().fill(theme.series).frame(width: 34, height: 3)
            }
            Spacer()
            accessory()
        }
        .padding(.top, 6)
    }
}

extension ListeningSection where Accessory == EmptyView {
    init(title: String) { self.init(title: title, accessory: { EmptyView() }) }
}

/// "↑ 13%" or "↓ 4%"; on a dark panel it's white, elsewhere the arrow is green or red.
private struct DeltaLabel: View {
    let delta: Double
    var onPanel = false

    var body: some View {
        let up = delta >= 0
        HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up" : "arrow.down").fontWeight(.bold)
                .foregroundStyle(onPanel ? AnyShapeStyle(.white) : AnyShapeStyle(up ? Color.green : Color.red))
            Text(abs(delta).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(onPanel ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.subtext))
        }
        .font(.caption.weight(.semibold)).monospacedDigit()
    }
}

// MARK: Banner

/// The period's plays, big, over a blurred photo of your top artist, with each day (week, month) against the
/// same span before.
private struct ListeningHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let stats: ListeningStats
    @State private var backdrop: NSImage?
    @State private var hovered: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let delta = change(Double(stats.plays), stats.previous.map { Double($0.plays) }) {
                        DeltaLabel(delta: delta, onPanel: true)
                        Text("vs \(priorSpan(stats.period))").font(.caption).foregroundStyle(.white.opacity(0.75))
                    } else {
                        Text(stats.period == .all ? "All time" : "Last \(stats.period.rawValue.lowercased())")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stats.plays.formatted()).font(.system(size: 60, weight: .heavy, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text(stats.plays == 1 ? "play" : "plays").font(.system(size: 26, weight: .bold, design: .rounded))
                }
                Text(summary).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                if let top = stats.artists.byPlays.first {
                    Button { open(top, .artist, model) } label: {
                        HStack(spacing: 8) {
                            ListeningArt(item: top, kind: .artist).frame(width: 26, height: 26).clipShape(Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                            Text("Top artist: ").foregroundStyle(.white.opacity(0.75)) + Text(top.name).fontWeight(.semibold)
                        }
                        .font(.callout)
                        .padding(.top, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            HeroChart(stats: stats, hovered: $hovered)
                .frame(minWidth: 260, maxWidth: 460)
                .frame(height: 150)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 210)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: stats.artists.byPlays.first?.id) { backdrop = await loadBackdrop() }
    }

    private var summary: String {
        var parts = ["\(formatLongDuration(stats.listened)) of music"]
        parts.append(ListeningKind.song.count(stats.songs.total))
        parts.append(ListeningKind.artist.count(stats.artists.total))
        if stats.skipped > 0 { parts.append("\(stats.skipped.formatted()) skipped") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var background: some View {
        let base = Color(theme.defaultPanel)
        ZStack {
            base
            if let backdrop {
                Image(nsImage: backdrop).resizable().scaledToFill()
                    .blur(radius: 36, opaque: true).saturation(1.25)
                    .opacity(0.9)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.45)], startPoint: .leading, endPoint: .trailing)
        }
        .animation(.easeInOut(duration: 0.4), value: backdrop != nil)
        // The filled photo reaches past the banner, over the period picker; it must not take its clicks.
        .allowsHitTesting(false)
    }

    private func loadBackdrop() async -> NSImage? {
        guard let top = stats.artists.byPlays.first else { return nil }
        if let photo = await model.artistInfo.image(for: top.name) { return photo }
        guard let album = stats.albums.byPlays.first ?? stats.songs.byPlays.first, let id = album.trackId,
              let track = model.trackByID[id], let url = model.coverURL(for: track) else { return nil }
        return await ListeningCovers.image(url)
    }
}

/// Plays per day, week or month, white bars over the faded ones of the span before.
private struct HeroChart: View {
    let stats: ListeningStats
    @Binding var hovered: Int?

    var body: some View {
        let current = stats.activity, previous = stats.previousActivity
        VStack(alignment: .trailing, spacing: 6) {
            Group {
                if let h = hovered, h < current.count {
                    Text(readout(h))
                } else if !previous.isEmpty {
                    HStack(spacing: 12) {
                        legend("Last \(stats.period.rawValue.lowercased())", .white)
                        legend(priorSpan(stats.period).capitalizedFirst, .white.opacity(0.35))
                    }
                } else {
                    Text("Plays by \(stats.granularity.rawValue)")
                }
            }
            .font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            Chart {
                ForEach(Array(current.enumerated()), id: \.offset) { i, p in
                    if i < previous.count {
                        BarMark(x: .value("When", String(i)), y: .value("Plays", previous[i].plays))
                            .foregroundStyle(.white.opacity(hovered == nil || hovered == i ? 0.35 : 0.18))
                            .position(by: .value("Span", "before"))
                            .cornerRadius(2)
                    }
                    BarMark(x: .value("When", String(i)), y: .value("Plays", p.plays))
                        .foregroundStyle(.white.opacity(hovered == nil || hovered == i ? 1 : 0.45))
                        .position(by: .value("Span", "now"))
                        .cornerRadius(2)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis {
                // Every bucket is a category; only every `step`th one is labeled.
                let step = labelStep(current.count)
                AxisMarks { v in
                    if let s = v.as(String.self), let i = Int(s), i < current.count, i % step == 0 {
                        AxisValueLabel(collisionResolution: .disabled) {
                            Text(label(current[i].date)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard case .active(let p) = phase, let frame = proxy.plotFrame,
                                  let s = proxy.value(atX: p.x - geo[frame].origin.x, as: String.self) else { hovered = nil; return }
                            hovered = Int(s)
                        }
                }
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text)
        }
    }

    private func labelStep(_ count: Int) -> Int {
        let wanted = stats.granularity == .day && count <= 7 ? count : 6
        return max(1, Int((Double(count) / Double(max(wanted, 1))).rounded(.up)))
    }

    private func label(_ d: Date) -> String {
        switch stats.granularity {
        case .day: stats.activity.count <= 7 ? d.formatted(.dateTime.weekday(.abbreviated)) : d.formatted(.dateTime.month(.abbreviated).day())
        case .week: d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    private func readout(_ i: Int) -> String {
        let p = stats.activity[i]
        let when: String
        switch stats.granularity {
        case .day: when = p.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week: when = "Week of " + p.date.formatted(.dateTime.month(.abbreviated).day())
        case .month: when = p.date.formatted(.dateTime.month(.wide).year())
        }
        var s = "\(when) · \(playCount(p.plays)) · \(formatListened(p.listened))"
        if i < stats.previousActivity.count { s += " (before: \(stats.previousActivity[i].plays.formatted()))" }
        return s
    }
}

// MARK: Top charts

/// Your top artist, album or song: a colored panel with how many you played, the #1 with its picture, then the next.
private struct SpotlightCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let kind: ListeningKind
    let ranking: ListeningStats.Ranking
    let previous: Int?
    let measure: ListeningMeasure
    @State private var tint: RGB?
    @State private var expanded = false

    var body: some View {
        let list = measure == .plays ? ranking.byPlays : ranking.byTime
        let panel = Color(tint ?? theme.defaultPanel)
        VStack(alignment: .leading, spacing: 0) {
            header(list, panel: panel)
            if let first = list.first {
                hero(first, panel: panel)
                VStack(spacing: 1) {
                    ForEach(Array(list.dropFirst().prefix(expanded ? 24 : 4).enumerated()), id: \.element.id) { i, item in
                        ListeningRow(rank: i + 2, item: item, kind: kind, detail: detail(item))
                    }
                    if list.count > 5 {
                        Button(expanded ? "Show less" : "Show top \(min(list.count, 25))") { withAnimation(.snappy) { expanded.toggle() } }
                            .buttonStyle(.link).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8).padding(.top, 4)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.35), value: tint)
    }

    private func header(_ list: [ListeningStats.Item], panel: Color) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.plural).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ranking.total.formatted()).font(.system(size: 30, weight: .bold, design: .rounded))
                    if let delta = change(Double(ranking.total), previous.map(Double.init)) { DeltaLabel(delta: delta, onPanel: true) }
                }
            }
            Spacer()
            MiniBars(values: list.prefix(8).map { measure == .plays ? Double($0.plays) : $0.listened })
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(panel)
        .help(kind.count(ranking.total) + " played" + (previous.map { ", vs \($0.formatted()) in the span before" } ?? ""))
    }

    private func hero(_ item: ListeningStats.Item, panel: Color) -> some View {
        Button { open(item, kind, model) } label: {
            Color.clear
                .aspectRatio(1.15, contentMode: .fit)
                .overlay { ListeningArt(item: item, kind: kind) { tint = panelTint($0) } }
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.top).font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(panel))
                        Text("#1 \(item.name)").font(.title3.weight(.bold)).lineLimit(2)
                        HStack(alignment: .firstTextBaseline) {
                            if kind != .artist, !item.subtitle.isEmpty { Text(item.subtitle).lineLimit(1) }
                            Spacer()
                            Text(detail(item)).monospacedDigit()
                        }
                        .font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ListeningItemMenu(item: item, kind: kind) }
        .help(kind == .song ? "Search for this song" : "Open \(item.name)")
    }

    private func detail(_ item: ListeningStats.Item) -> String {
        measure == .plays ? playCount(item.plays) : formatListened(item.listened)
    }
}

/// A row of small bars, the shape of a ranking at a glance.
private struct MiniBars: View {
    let values: [Double]

    var body: some View {
        let top = max(values.max() ?? 1, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.9))
                    .frame(width: 4, height: max(2, 26 * v / top))
            }
        }
        .frame(height: 26, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The share of artists, albums or songs played for the first time during the period, and the top one.
private struct DiscoveryTile: View {
    @Environment(\.theme) private var theme
    let kind: ListeningKind
    let new: ListeningStats.Ranking
    let all: Int

    var body: some View {
        let share = all == 0 ? 0 : Double(new.total) / Double(all)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New \(kind.plural)").font(.callout.weight(.semibold)).foregroundStyle(.subtext)
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("\(new.total.formatted()) of \(kind.count(all)) first heard").font(.caption).foregroundStyle(.subtext)
                }
                Spacer()
                ZStack {
                    Circle().stroke(theme.track, lineWidth: 7)
                    Circle().trim(from: 0, to: share).stroke(theme.series, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 48, height: 48)
            }
            if let top = new.byPlays.first {
                Divider()
                ListeningRow(rank: 1, item: top, kind: kind, detail: playCount(top.plays), size: 36)
                    .padding(.horizontal, -8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: Patterns

/// Listening by hour on a 24-hour dial, with the busiest hour and day.
private struct ListeningClockCard: View {
    @Environment(\.theme) private var theme
    let stats: ListeningStats
    @State private var hovered: Int?

    var body: some View {
        let hours = stats.hourTotals
        InsightCard(title: "Listening Clock", subtitle: subtitle) {
            HStack(alignment: .center, spacing: 24) {
                VStack(spacing: 6) {
                    Group {
                        if let h = hovered {
                            Text("\(hourLabel(h)) · \(formatListened(hours[h])) · \(playCount(stats.hourPlays[h]))")
                        } else {
                            Text("Hover an hour for details").foregroundStyle(.subtext)
                        }
                    }
                    .font(.caption).monospacedDigit().lineLimit(1)
                    RadialClock(values: hours, hovered: $hovered).frame(width: 190, height: 190)
                }
                VStack(alignment: .leading, spacing: 14) {
                    if let h = stats.peakHour {
                        stat("Busiest hour", hourLabel(h), detail: "\(playCount(stats.hourPlays[h])) in that hour")
                    }
                    if let d = stats.peakWeekday {
                        stat("Busiest day", weekdayName(d), detail: nil)
                        WeekdayBars(stats: stats)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stat(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.subtext)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            if let detail { Text(detail).font(.caption).foregroundStyle(.subtext) }
        }
    }

    private var subtitle: String {
        guard let hour = stats.peakHour else { return "" }
        return "Mostly \(daypart(hour).name)"
    }
}

/// 24 wedges, midnight at the top, each as long as the listening in that hour.
private struct RadialClock: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    @Binding var hovered: Int?

    private static let inner = 0.32

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        ZStack {
            ForEach(0..<24, id: \.self) { h in
                let reach = values[h] == 0 ? 0 : Self.inner + (1 - Self.inner) * max(0.08, (values[h] / peak).squareRoot())
                ZStack {
                    Wedge(hour: h, inner: Self.inner, outer: 1).fill(theme.track)
                    if reach > 0 {
                        Wedge(hour: h, inner: Self.inner, outer: reach)
                            .fill(theme.series.opacity(hovered == nil || hovered == h ? 1 : 0.45))
                    }
                }
                .contentShape(Wedge(hour: h, inner: Self.inner, outer: 1))
                .onHover { hovered = $0 ? h : (hovered == h ? nil : hovered) }
            }
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2 * Self.inner * 0.62
                let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    let angle = Double(h) / 24 * 2 * .pi - .pi / 2
                    Text(String(format: "%02d", h)).font(.system(size: 9, weight: .medium)).foregroundStyle(.subtext)
                        .position(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct Wedge: Shape {
    let hour: Int
    let inner: Double
    let outer: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = 1.2
        let start = Angle.degrees(Double(hour) * 15 - 90 + gap / 2), end = Angle.degrees(Double(hour + 1) * 15 - 90 - gap / 2)
        var p = Path()
        p.addArc(center: center, radius: radius * outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: center, radius: radius * inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct WeekdayBars: View {
    @Environment(\.theme) private var theme
    let stats: ListeningStats

    var body: some View {
        let totals = stats.weekdayTotals
        let top = max(totals.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d == stats.peakWeekday ? theme.series : theme.series.opacity(0.4))
                        .frame(width: 14, height: max(2, 44 * totals[d] / top))
                    Text(stats.weekdaySymbols[d].prefix(1)).font(.caption2).foregroundStyle(.subtext)
                }
                .help("\(weekdayName(d)): \(formatListened(totals[d]))")
            }
        }
        .frame(height: 60, alignment: .bottom)
    }
}

/// Listening by release decade, with where the digital collection stands, and the top album of your top decade.
private struct DecadesCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let stats: ListeningStats
    @State private var hovered: Int?

    var body: some View {
        let top = max(stats.eras.map { max($0.listening, $0.library) }.max() ?? 1, 0.0001)
        let favorite = stats.eras.max { $0.listening < $1.listening }
        InsightCard(title: "Music by Decade", subtitle: subtitle) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule().fill(theme.series).frame(width: 14, height: 7)
                    Text("Your listening")
                }
                HStack(spacing: 5) {
                    Capsule().fill(theme.primaryText).frame(width: 2, height: 11)
                    Text("Your digital collection")
                }
            }
            .font(.caption).foregroundStyle(.subtext)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(stats.eras) { e in
                    Button { model.search("decade:\(e.decade)s") } label: {
                        HStack(spacing: 10) {
                            Text("\(String(e.decade))s").font(.callout).monospacedDigit().frame(width: 52, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.track)
                                    Capsule().fill(theme.series.opacity(e.decade == favorite?.decade ? 1 : 0.7))
                                        .frame(width: e.listening == 0 ? 0 : max(6, geo.size.width * e.listening / top))
                                    if e.library > 0 {
                                        Capsule().fill(theme.primaryText).frame(width: 2, height: 16)
                                            .offset(x: geo.size.width * e.library / top - 1)
                                    }
                                }
                                .frame(height: 12)
                                .frame(maxHeight: .infinity)
                            }
                            .frame(height: 18)
                            Text(e.listening.formatted(.percent.precision(.fractionLength(0)))).font(.callout).monospacedDigit()
                                .foregroundStyle(.subtext).frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hovered == e.decade ? theme.fill : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? e.decade : (hovered == e.decade ? nil : hovered) }
                    .help("\(e.listening.formatted(.percent.precision(.fractionLength(0)))) of your listening, \(e.library.formatted(.percent.precision(.fractionLength(0)))) of your digital collection · click to search")
                }
            }
            if let favorite, let album = favorite.topAlbum {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top album · \(String(favorite.decade))s").font(.caption).foregroundStyle(.subtext).padding(.leading, 8)
                    ListeningRow(item: album, kind: .album, detail: formatListened(album.listened), size: 40)
                }
                .padding(.horizontal, -8)
            }
        }
    }

    /// Calls out the decade played most out of proportion to the library.
    private var subtitle: String {
        let favored = stats.eras.filter { $0.listening >= 0.05 && $0.library > 0 }.max { $0.listening / $0.library < $1.listening / $1.library }
        if let f = favored, f.listening / f.library >= 1.5 {
            return "You play the \(String(f.decade))s \((f.listening / f.library).formatted(.number.precision(.fractionLength(1))))× more than your digital collection would suggest"
        }
        return "Listening time by release decade, next to your digital collection"
    }
}

private struct ListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Top Genres", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            RankedBars(items: stats.genres.byPlays.map {
                RankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 7)
        }
    }
}

/// A card of songs with their covers, the first few and then the rest.
private struct SongListCard: View {
    let title: String
    let subtitle: String
    let items: [(item: ListeningStats.Item, detail: String)]
    @State private var expanded = false

    var body: some View {
        InsightCard(title: title, subtitle: subtitle) {
            VStack(spacing: 1) {
                ForEach(Array(items.prefix(expanded ? 25 : 5).enumerated()), id: \.element.item.id) { _, entry in
                    ListeningRow(item: entry.item, kind: .song, detail: entry.detail)
                }
                if items.count > 5 {
                    Button(expanded ? "Show less" : "Show all \(min(items.count, 25))") { withAnimation(.snappy) { expanded.toggle() } }
                        .buttonStyle(.link).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8).padding(.top, 4)
                }
            }
            .padding(.horizontal, -8)
        }
    }
}

private struct SkippedCard: View {
    let stats: ListeningStats

    var body: some View {
        SongListCard(title: "Most Skipped",
                     subtitle: "Started but stopped before they counted · \(stats.skipRate.formatted(.percent.precision(.fractionLength(0)))) of listens",
                     items: stats.mostSkipped.map { ($0, "\($0.skips) skips") })
    }
}

private struct RediscoverCard: View {
    let stats: ListeningStats

    var body: some View {
        SongListCard(title: "Rediscover", subtitle: "Songs you used to play that you haven't in over 3 months",
                     items: stats.forgotten.map { i in
                         (i, playCount(i.plays) + (i.lastPlayed.map { " · " + $0.formatted(.dateTime.month(.abbreviated).year()) } ?? ""))
                     })
    }
}

// MARK: Quick facts

/// The period's headline numbers against the span before.
private struct QuickFacts: View {
    @Environment(\.theme) private var theme
    let stats: ListeningStats

    var body: some View {
        let previous = stats.previous
        let days = Double(max(stats.dayCount, 1))
        EvenRow(count: stats.biggestDay == nil ? 5 : 6, minWidth: 170) {
            tile("Listening time", formatLongDuration(stats.listened), icon: "headphones",
                 delta: change(stats.listened, previous?.listened), vs: previous.map { formatLongDuration($0.listened) })
            tile("Plays a day", (Double(stats.plays) / days).formatted(.number.precision(.fractionLength(0...1))), icon: "play.circle",
                 delta: change(Double(stats.plays), previous.map { Double($0.plays) }),
                 vs: previous.map { (Double($0.plays) / days).formatted(.number.precision(.fractionLength(0...1))) })
            if let d = stats.biggestDay {
                tile("Most active day", formatLongDuration(d.listened), icon: "chart.bar.fill",
                     detail: d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     delta: change(d.listened, previous?.biggestDay?.listened), vs: previous?.biggestDay.map { formatLongDuration($0.listened) })
            }
            tile("Days with music", "\(stats.activeDays.formatted()) of \(stats.dayCount.formatted())", icon: "calendar",
                 delta: change(Double(stats.activeDays), previous.map { Double($0.activeDays) }), vs: previous.map { $0.activeDays.formatted() })
            tile("Day streak", stats.currentStreak.formatted(), icon: "flame",
                 detail: "Longest: \(stats.longestStreak.formatted()) day\(stats.longestStreak == 1 ? "" : "s")")
            tile("Songs played", stats.songs.total.formatted(), icon: "music.note",
                 detail: "\(stats.libraryPlayed.formatted(.percent.precision(.fractionLength(0...1)))) of your digital collection")
        }
    }

    private func tile(_ title: String, _ value: String, icon: String, detail: String? = nil, delta: Double? = nil, vs: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(theme.series)
                Text(title).foregroundStyle(.subtext)
            }
            .font(.callout)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                if let delta { DeltaLabel(delta: delta) }
            }
            Group {
                if let vs, stats.period != .all {
                    Text("vs \(vs) in \(priorSpan(stats.period))")
                } else if let detail {
                    Text(detail)
                } else {
                    Text(" ")
                }
            }
            .font(.caption).foregroundStyle(.subtext).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private enum ListeningFacts {
    static func facts(_ stats: ListeningStats) -> [FunFact] {
        var out: [FunFact] = []
        if let s = stats.longestSession, s.songs > 1 {
            out.append(FunFact(icon: "hourglass", title: "Longest session", value: formatLongDuration(s.listened),
                               detail: "\(s.songs) songs in a row, \(s.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
        }
        if let r = stats.onRepeat {
            out.append(FunFact(icon: "repeat", title: "On repeat", value: r.song.name,
                               detail: "\(r.plays) plays on \(r.date.formatted(.dateTime.month(.abbreviated).day()))\(r.song.subtitle.isEmpty ? "" : " · " + r.song.subtitle)",
                               query: songQuery(r.song)))
        }
        if let h = stats.peakHour {
            let part = daypart(h)
            out.append(FunFact(icon: part.icon, title: part.title, value: hourLabel(h), detail: "Your busiest hour of the day"))
        }
        if let a = stats.artists.byPlays.first, stats.plays > 0, stats.artists.total > 1 {
            let share = Double(a.plays) / Double(stats.plays)
            out.append(FunFact(icon: "heart", title: "Most played artist", value: a.name,
                               detail: "\(share.formatted(.percent.precision(.fractionLength(0)))) of your plays",
                               query: a.name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", a.name)))
        }
        if stats.skipped > 0 {
            out.append(FunFact(icon: "forward.end", title: "Skip rate", value: stats.skipRate.formatted(.percent.precision(.fractionLength(0))),
                               detail: "\(stats.skipped.formatted()) of \(stats.listens.formatted()) listens stopped early"))
        }
        if stats.neverPlayed > 0 {
            out.append(FunFact(icon: "sparkles", title: "Still unplayed", value: stats.neverPlayed.formatted(),
                               detail: "songs in your digital collection waiting for their first play"))
        }
        if stats.period == .all, let first = stats.firstListen, let song = stats.firstSong {
            out.append(FunFact(icon: "flag", title: "First listen", value: first.formatted(date: .abbreviated, time: .omitted),
                               detail: song.name + (song.subtitle.isEmpty ? "" : " — " + song.subtitle), query: songQuery(song)))
        }
        return out
    }
}

private extension ListeningStats {
    /// Only when there's history before the period: otherwise everything is new.
    var showsDiscoveries: Bool {
        guard period != .all, let first = firstListen, let start else { return false }
        return first < start && artists.total > 0
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
