import Charts
import MusicLibraryCore
import SwiftUI
import UIKit

// MARK: Palette

/// Chart colors (the Mac's, validated for contrast against the card surface in both appearances).
nonisolated enum InsightColor {
    /// A color with separate sRGB values for light and dark appearances.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    /// Single-series marks.
    static let series = dynamic(light: 0x2a78d6, dark: 0x3987e5)

    /// Ordinal blue ramp for quality tiers, best quality most prominent; "unknown" is neutral gray.
    static func tier(_ t: LibraryStats.QualityTier) -> Color {
        switch t {
        case .hiRes: dynamic(light: 0x104281, dark: 0xcde2fb)
        case .cd: dynamic(light: 0x256abf, dark: 0x86b6ef)
        case .lossyHigh: dynamic(light: 0x5598e7, dark: 0x3987e5)
        case .lossy: dynamic(light: 0x86b6ef, dark: 0x1c5cab)
        case .unknown: neutral
        }
    }

    /// Secondary series (the library next to your listening).
    static let neutral = dynamic(light: 0xb5b4ae, dark: 0x5f5e5a)

    /// The empty part of a bar.
    static let track = Color.primary.opacity(0.07)
}

// MARK: Tab

/// The panes, Owned first. The raw values are saved (`insightsPane`), so they keep their old names.
enum InsightsPane: String, CaseIterable, Identifiable {
    case owned = "Owned", library = "Library", listening = "Listening"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .owned: "Owned"
        case .library: "Digital"
        case .listening: "Listening"
        }
    }
}

/// Insights: what you own (CDs, records, downloads), your digital collection, and what you listen to, plus Explore
/// (Music DNA), which spans both collections.
struct InsightsTab: View {
    @Environment(PhoneModel.self) private var model
    @AppStorage("insightsPane") private var pane = InsightsPane.owned
    @AppStorage("listeningPeriod") private var period = ListeningStats.Period.month

    var body: some View {
        LibraryStack {
            content
                .navigationTitle("Insights")
                .onAppear(perform: load)
                .onChange(of: model.libraryVersion) { load() }
                .onChange(of: model.historyVersion) { load() }
                .onChange(of: model.collectionVersion) { load() }
                .onChange(of: pane) { load() }
                .onChange(of: period) { load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let library = model.library {
            if library.isEmpty {
                ContentUnavailableView("No Insights Yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Add music or the CDs and records you own in Music Library on your Mac and sync, and this page fills in with stats about them."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        InsightsExplore()
                        Picker("Insights", selection: $pane) { ForEach(InsightsPane.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden()
                        paneContent
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
        } else {
            LibraryStatusView()
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .library where model.library?.tracks.isEmpty == true, .listening where model.library?.tracks.isEmpty == true:
            // A collection without songs yet.
            ContentUnavailableView("No Music Yet", systemImage: "music.note",
                                   description: Text("Rip a CD or add music on your Mac and sync, and this pane fills in."))
                .padding(.top, 40)
        case .library:
            if let stats = model.libraryStats {
                InsightsLibraryPane(stats: stats)
            } else {
                InsightsLoading()
            }
        case .listening:
            // The period stays put while a new one is computed; there's none to pick without any history.
            if model.listeningStats?.hasHistory ?? true {
                Picker("Period", selection: $period) { ForEach(ListeningStats.Period.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            if let stats = model.listeningStats, stats.period == period || !stats.hasHistory {
                ListeningInsightsPane(stats: stats)
            } else {
                InsightsLoading()
            }
        case .owned:
            if let stats = model.collectionStats {
                CollectionInsightsPane(stats: stats)
            } else {
                InsightsLoading()
            }
        }
    }

    private func load() {
        switch pane {
        case .library: model.loadLibraryStats()
        case .listening: model.loadListening(period)
        case .owned: model.loadCollectionStats()
        }
    }
}

/// Explore: pages about your music that belong to neither collection alone. Music DNA covers the people of both;
/// concerts are on artist pages (the phone has no Concerts page).
private struct InsightsExplore: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Explore")
            NavigationLink(value: DNARoute(name: nil)) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Music DNA")
                        Text("Who played, wrote and produced with whom").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    InsightChevron()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .card()
            .accessibilityElement(children: .combine)
        }
    }
}

struct InsightsLoading: View {
    var body: some View {
        ProgressView("Crunching the numbers…")
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
    }
}

/// The Digital pane: stats about the whole digital collection.
struct InsightsLibraryPane: View {
    let stats: LibraryStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            InsightsHeroTiles(stats: stats)
            if !stats.years.isEmpty { InsightsTimelineCard(stats: stats) }
            if !stats.genres.isEmpty { InsightsGenresCard(stats: stats) }
            InsightsArtistsCard(stats: stats)
            InsightsQualityCard(stats: stats)
            InsightsGrowthCard(stats: stats)
            InsightsLengthCard(stats: stats)
            if !stats.people.isEmpty { InsightsPeopleCard(stats: stats) }
            if !stats.labels.isEmpty || !stats.countries.isEmpty { InsightsLabelsCard(stats: stats) }
            InsightsHealthCard(stats: stats)
            InsightsFunFactsCard(stats: stats)
        }
    }
}

// MARK: Building blocks

/// A titled card; the accessory (a picker) goes under the title.
struct InsightCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            accessory()
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

extension InsightCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A card's segmented picker over all of an enum's cases.
struct InsightSegments<Value: Hashable & RawRepresentable & CaseIterable>: View where Value.RawValue == String, Value.AllCases: RandomAccessCollection {
    @Binding var selection: Value

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

/// A proportional bar on a faint track.
struct InsightBar: View {
    var fraction: Double
    var color = InsightColor.series
    var height: CGFloat = 6
    var minWidth: CGFloat = 4
    /// A zero value draws no bar (otherwise it's a stub, like the ranked lists).
    var hidesZero = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(InsightColor.track)
                Capsule().fill(color)
                    .frame(width: hidesZero && fraction <= 0 ? 0 : max(minWidth, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// A trailing chevron for rows that open something.
struct InsightChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

struct InsightRankedItem: Identifiable {
    var id: String { key ?? name }
    var name: String
    var value: Double
    var detail: String
    var query: String?
    /// Opens this person's Music DNA instead of searching.
    var person: String?
    /// A second line under the name, e.g. the artist of a song.
    var subtitle: String?
    /// Identity when names can repeat (songs with the same title).
    var key: String?
}

/// A ranked list with proportional bars; rows open their search (or Music DNA). Shows the top few and expands to
/// the rest.
struct InsightRankedBars: View {
    let items: [InsightRankedItem]
    var initialCount = 8
    var maxCount = 50
    @State private var expanded = false

    var body: some View {
        let shown = Array(items.prefix(expanded ? maxCount : initialCount))
        let top = max(items.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { item in
                if let person = item.person {
                    NavigationLink(value: DNARoute(name: person)) { row(item, top: top, link: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows \(person)'s Music DNA")
                } else if let q = item.query {
                    NavigationLink(value: QueryRoute(query: q, title: item.name)) { row(item, top: top, link: true) }
                        .buttonStyle(.plain)
                } else {
                    row(item, top: top, link: false)
                }
            }
            if items.count > initialCount {
                Button(expanded ? "Show Less" : "Show All \(min(items.count, maxCount))\(items.count > maxCount ? " of \(items.count)" : "")") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.footnote.weight(.medium))
                .padding(.top, 6)
            }
        }
    }

    private func row(_ item: InsightRankedItem, top: Double, link: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(item.detail).font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
                if link { InsightChevron() }
            }
            InsightBar(fraction: item.value / top)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct InsightColumnDatum: Identifiable {
    var id: String { label }
    var label: String
    var value: Int
    var query: String?
    /// The search page's title (the label when nil).
    var title: String?
}

extension View {
    /// Tap or drag sideways across a chart to pick a point (`x` in plot coordinates); vertical drags still scroll the
    /// page. `tap` defaults to picking.
    func insightScrub(tap: ((ChartProxy, CGFloat) -> Void)? = nil, pick: @escaping (ChartProxy, CGFloat) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { p in
                        guard let frame = proxy.plotFrame else { return }
                        (tap ?? pick)(proxy, p.x - geo[frame].origin.x)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height), let frame = proxy.plotFrame else { return }
                        pick(proxy, v.location.x - geo[frame].origin.x)
                    })
            }
        }
    }
}

/// The line above a chart: what's selected, or how to select.
struct InsightReadout<Trailing: View>: View {
    let text: String?
    let hint: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let text {
                Text(text).foregroundStyle(.primary)
                Spacer(minLength: 8)
                trailing()
            } else {
                Text(hint).foregroundStyle(.secondary)
            }
        }
        .font(.caption).monospacedDigit()
        .frame(minHeight: 16, alignment: .leading)
    }
}

extension InsightReadout where Trailing == EmptyView {
    init(text: String?, hint: String) {
        self.init(text: text, hint: hint, trailing: { EmptyView() })
    }
}

/// A single-series column chart. Dragging across it reads out a column (with a link to its songs); tapping a column
/// opens its songs.
struct InsightColumnChart: View {
    @Environment(\.openRoute) private var openRoute
    let data: [InsightColumnDatum]
    var axisLabels: [String]?
    var unit = "songs"
    var height: CGFloat = 170
    @State private var selected: String?

    var body: some View {
        let current = selected.flatMap { s in data.first { $0.label == s } }
        VStack(alignment: .leading, spacing: 12) {
            InsightReadout(text: current.map { d in "\(d.label) · \(d.value.formatted()) \(d.value == 1 ? String(unit.dropLast()) : unit)" },
                           hint: "Drag across for details, tap a column to see its songs") {
                if let d = current, let q = d.query {
                    NavigationLink(value: QueryRoute(query: q, title: d.title ?? d.label)) {
                        HStack(spacing: 2) { Text("Show Songs"); Image(systemName: "chevron.right") }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            Chart(data) { d in
                BarMark(x: .value("Bucket", d.label), y: .value("Songs", d.value), width: .ratio(0.82))
                    .foregroundStyle(InsightColor.series.opacity(current == nil || current?.label == d.label ? 1 : 0.35))
                    .cornerRadius(2)
            }
            .chartXAxis {
                if let axisLabels {
                    AxisMarks(values: axisLabels) { _ in AxisValueLabel() }
                } else {
                    AxisMarks { _ in AxisValueLabel() }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .insightScrub(tap: { proxy, x in
                guard let l = proxy.value(atX: x, as: String.self), let d = data.first(where: { $0.label == l }) else { return }
                selected = l
                if let q = d.query { openRoute(QueryRoute(query: q, title: d.title ?? d.label)) }
            }, pick: { proxy, x in
                if let l = proxy.value(atX: x, as: String.self) { selected = l }
            })
            .frame(height: height)
        }
    }
}

/// Evenly spaced axis labels so dense category axes stay readable.
func insightSparseLabels(_ labels: [String], maxCount: Int) -> [String] {
    guard labels.count > maxCount else { return labels }
    let step = Int((Double(labels.count) / Double(maxCount)).rounded(.up))
    return labels.enumerated().filter { $0.offset % step == 0 }.map(\.element)
}

/// A capsule with a count; opens its search when it has one.
struct InsightChip: View {
    let text: String
    var query: String?
    /// The search page's title.
    var title: String?

    var body: some View {
        if let query {
            NavigationLink(value: QueryRoute(query: query, title: title ?? text)) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        Text(text).font(.caption).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
    }
}

/// A caption over a wrapping row of chips.
struct InsightChipRow: View {
    let title: String
    /// Text, query, search title.
    let chips: [(text: String, query: String?, title: String?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(chips, id: \.text) { InsightChip(text: $0.text, query: $0.query, title: $0.title) }
            }
        }
    }
}

/// Two columns of tiles; the tiles in a row are as tall as the tallest.
struct InsightTileGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        InsightPairLayout(spacing: 10) { content() }
    }
}

/// Lays children out two to a row, each row as tall as its tallest child.
struct InsightPairLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = rowHeights(width, subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width)
        var y = bounds.minY
        for (row, height) in rowHeights(bounds.width, subviews).enumerated() {
            for i in (row * 2)..<min(row * 2 + 2, subviews.count) {
                let x = bounds.minX + (i % 2 == 0 ? 0 : column + spacing)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: column, height: height))
            }
            y += height + spacing
        }
    }

    private func columnWidth(_ width: CGFloat) -> CGFloat { max(0, (width - spacing) / 2) }

    private func rowHeights(_ width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let column = columnWidth(width)
        return stride(from: 0, to: subviews.count, by: 2).map { start in
            subviews[start..<min(start + 2, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
    }
}

/// A big number with a label, and optionally a line of context under it.
struct InsightTile: View {
    let value: String
    let label: String
    let icon: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(height: 20)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct InsightFact: Identifiable {
    var id: String { title }
    var icon: String
    var title: String
    var value: String
    var detail: String
    var query: String?
    /// The search page's title (the value when nil).
    var queryTitle: String?
    /// Opens this collection item instead of searching.
    var itemID: String?
}

/// Fun facts two to a row; facts with a query open its search.
struct InsightFactsGrid: View {
    let facts: [InsightFact]

    var body: some View {
        let rows = stride(from: 0, to: facts.count, by: 2).map { Array(facts[$0..<min($0 + 2, facts.count)]) }
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r]) { f in
                        fact(f).gridCellColumns(rows[r].count == 1 ? 2 : 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fact(_ f: InsightFact) -> some View {
        if let id = f.itemID {
            NavigationLink(value: CollectionItemRoute(id: id)) { cell(f, link: true) }
                .buttonStyle(.plain)
        } else if let q = f.query {
            NavigationLink(value: QueryRoute(query: q, title: f.queryTitle ?? f.value)) { cell(f, link: true) }
                .buttonStyle(.plain)
        } else {
            cell(f, link: false)
        }
    }

    private func cell(_ f: InsightFact, link: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: f.icon).font(.title3).foregroundStyle(InsightColor.series).frame(height: 26)
                Spacer(minLength: 0)
                if link { InsightChevron() }
            }
            .padding(.bottom, 2)
            Text(f.title).font(.caption).foregroundStyle(.secondary)
            Text(f.value).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
            Text(f.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Fun facts in a card.
struct InsightFactsCard: View {
    let facts: [InsightFact]

    var body: some View {
        InsightCard(title: "Fun Facts") { InsightFactsGrid(facts: facts) }
    }
}

// MARK: Hero

struct InsightsHeroTiles: View {
    let stats: LibraryStats

    var body: some View {
        let lossless = stats.trackCount == 0 ? 0 : Double(stats.losslessCount) / Double(stats.trackCount)
        InsightTileGrid {
            InsightTile(value: stats.trackCount.formatted(), label: stats.trackCount == 1 ? "Song" : "Songs", icon: "music.note")
            InsightTile(value: stats.albumCount.formatted(), label: stats.albumCount == 1 ? "Album" : "Albums", icon: "square.stack")
            InsightTile(value: stats.artistCount.formatted(), label: stats.artistCount == 1 ? "Artist" : "Artists", icon: "music.mic")
            InsightTile(value: formatLongDuration(stats.totalDuration), label: "Of music", icon: "clock")
            InsightTile(value: (stats.bytesAreEstimated ? "≈ " : "") + ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file),
                        label: "On disk", icon: "internaldrive")
            InsightTile(value: lossless.formatted(.percent.precision(.fractionLength(0))), label: "Lossless", icon: "waveform")
        }
    }
}

// MARK: Cards

struct InsightsTimelineCard: View {
    let stats: LibraryStats
    enum Scale: String, CaseIterable { case auto = "Auto", years = "Years", decades = "Decades" }
    @State private var scale = Scale.auto

    var body: some View {
        let span = (stats.years.last?.year ?? 0) - (stats.years.first?.year ?? 0)
        let useYears = scale == .years || (scale == .auto && span <= 40)
        let data = useYears ? yearData : decadeData
        InsightCard(title: "Through the Years", subtitle: subtitle) {
            InsightSegments(selection: $scale)
        } content: {
            InsightColumnChart(data: data, axisLabels: insightSparseLabels(data.map(\.label), maxCount: useYears ? 6 : 8), height: 190)
                .id(useYears)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.years.first?.year, let last = stats.years.last?.year { parts.append(first == last ? "All from \(first)" : "\(first)–\(last)") }
        if let m = stats.medianYear { parts.append("half your music is from \(m) or earlier") }
        return parts.joined(separator: " · ")
    }

    /// Every year in range, including empty ones, so gaps in the collection show as gaps.
    private var yearData: [InsightColumnDatum] {
        guard let first = stats.years.first?.year, let last = stats.years.last?.year else { return [] }
        let counts = Dictionary(uniqueKeysWithValues: stats.years.map { ($0.year, $0.count) })
        return (first...last).map { InsightColumnDatum(label: String($0), value: counts[$0] ?? 0, query: "year:\($0)") }
    }

    private var decadeData: [InsightColumnDatum] {
        guard let first = stats.decades.first?.year, let last = stats.decades.last?.year else { return [] }
        let counts = Dictionary(uniqueKeysWithValues: stats.decades.map { ($0.year, $0.count) })
        return stride(from: first, through: last, by: 10).map {
            InsightColumnDatum(label: "\($0)s", value: counts[$0] ?? 0, query: "decade:\($0)s")
        }
    }
}

struct InsightsGenresCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Genres", subtitle: "\(stats.genres.count) genre\(stats.genres.count == 1 ? "" : "s") · songs can carry several") {
            InsightRankedBars(items: stats.genres.map {
                InsightRankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: SearchFilterKey.token("genre", $0.name))
            })
        }
    }
}

struct InsightsArtistsCard: View {
    let stats: LibraryStats
    enum Measure: String, CaseIterable { case songs = "Songs", time = "Time", albums = "Albums" }
    @State private var measure = Measure.songs

    var body: some View {
        InsightCard(title: "Top Artists", subtitle: "\(stats.artistCount.formatted()) album artist\(stats.artistCount == 1 ? "" : "s")") {
            InsightSegments(selection: $measure)
        } content: {
            InsightRankedBars(items: items).id(measure)
        }
    }

    private var items: [InsightRankedItem] {
        func query(_ name: String) -> String? { name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", name) }
        switch measure {
        case .songs:
            return stats.artistsByTracks.map { InsightRankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: query($0.name)) }
        case .time:
            return stats.artistsByDuration.map { InsightRankedItem(name: $0.name, value: $0.duration, detail: formatLongDuration($0.duration), query: query($0.name)) }
        case .albums:
            return stats.artistsByAlbums.map {
                InsightRankedItem(name: $0.name, value: Double($0.count), detail: "\($0.count) album\($0.count == 1 ? "" : "s")", query: query($0.name))
            }
        }
    }
}

struct InsightsQualityCard: View {
    let stats: LibraryStats

    var body: some View {
        let total = max(stats.trackCount, 1)
        InsightCard(title: "Audio Quality", subtitle: "How your files are encoded") {
            Chart(stats.qualityTiers) { t in
                SectorMark(angle: .value("Songs", t.count), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(InsightColor.tier(t.tier))
                    .cornerRadius(2)
            }
            .chartLegend(.hidden)
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text((Double(stats.losslessCount) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    Text("lossless").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stats.qualityTiers) { t in
                    if let q = t.tier.query {
                        NavigationLink(value: QueryRoute(query: q, title: t.tier.rawValue)) { tierRow(t, total: total, link: true) }
                            .buttonStyle(.plain)
                    } else {
                        tierRow(t, total: total, link: false)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                InsightChipRow(title: "Formats", chips: stats.codecs.map {
                    ("\($0.name) \($0.count.formatted())", SearchFilterKey.token("format", $0.name.lowercased()), $0.name)
                })
                if !stats.sampleRates.isEmpty {
                    InsightChipRow(title: "Sample rates", chips: stats.sampleRates.map {
                        ("\($0.name) \($0.count.formatted())", "rate:" + $0.name.replacingOccurrences(of: " kHz", with: ""), $0.name)
                    })
                }
                if !stats.bitDepths.isEmpty {
                    InsightChipRow(title: "Bit depths", chips: stats.bitDepths.map {
                        ("\($0.name) \($0.count.formatted())", "bits:" + $0.name.replacingOccurrences(of: "-bit", with: ""), $0.name)
                    })
                }
            }
        }
    }

    private func tierRow(_ t: LibraryStats.TierCount, total: Int, link: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(InsightColor.tier(t.tier)).frame(width: 12, height: 12)
            Text(t.tier.rawValue).lineLimit(1)
            Spacer(minLength: 6)
            Text(songCount(t.count)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Text((Double(t.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit().frame(width: 40, alignment: .trailing)
            InsightChevron().opacity(link ? 1 : 0)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct InsightsGrowthCard: View {
    let stats: LibraryStats
    @State private var selected: LibraryStats.GrowthPoint?

    var body: some View {
        InsightCard(title: "Digital Collection Growth", subtitle: subtitle) {
            if stats.growth.count >= 2 {
                VStack(alignment: .leading, spacing: 12) {
                    InsightReadout(text: selected.map { "\(period($0.date)) · +\($0.added.formatted()) → \(songCount($0.total))" },
                                   hint: "Songs in your digital collection over time · drag for details")
                    Chart {
                        ForEach(stats.growth) { p in
                            AreaMark(x: .value("Date", p.date), y: .value("Songs", p.total))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(LinearGradient(colors: [InsightColor.series.opacity(0.28), InsightColor.series.opacity(0.03)],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Date", p.date), y: .value("Songs", p.total))
                                .interpolationMethod(.stepEnd)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .foregroundStyle(InsightColor.series)
                        }
                        if let h = selected {
                            RuleMark(x: .value("Date", h.date)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.6))
                            PointMark(x: .value("Date", h.date), y: .value("Songs", h.total))
                                .symbolSize(70).foregroundStyle(InsightColor.series)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel()
                        }
                    }
                    .insightScrub { proxy, x in
                        guard let date = proxy.value(atX: x, as: Date.self) else { return }
                        selected = stats.growth.last { $0.date <= date } ?? stats.growth.first
                    }
                    .frame(height: 170)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(.secondary)
                    Text("All \(songCount(stats.trackCount)) arrived \(stats.firstAdded.map { "on " + $0.formatted(date: .long, time: .omitted) } ?? "together").")
                    Text("Your growth curve starts with your next import.").foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            }
        }
    }

    private var subtitle: String {
        guard let first = stats.firstAdded else { return "" }
        var s = "Since \(first.formatted(date: .abbreviated, time: .omitted))"
        if stats.growth.count >= 2 { s += " · by \(stats.growthGranularity.rawValue)" }
        if stats.addedLast30Days > 0 { s += " · +\(stats.addedLast30Days.formatted()) in the last 30 days" }
        return s
    }

    private func period(_ d: Date) -> String {
        switch stats.growthGranularity {
        case .day: d.formatted(date: .abbreviated, time: .omitted)
        case .week: "Week of " + d.formatted(.dateTime.month(.abbreviated).day())
        case .month: d.formatted(.dateTime.month(.wide).year())
        }
    }
}

struct InsightsLengthCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Track Lengths", subtitle: "Minutes · average \(Format.time(stats.averageTrackLength))") {
            InsightColumnChart(data: stats.lengthBuckets.map {
                InsightColumnDatum(label: $0.label, value: $0.count, query: $0.query, title: "\($0.label) min")
            }, axisLabels: insightSparseLabels(stats.lengthBuckets.map(\.label), maxCount: 7))
        }
    }
}

struct InsightsPeopleCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Most Credited", subtitle: "Players, producers and engineers across your music") {
            InsightRankedBars(items: stats.people.map {
                InsightRankedItem(name: $0.name, value: Double($0.trackCount),
                                  detail: songCount($0.trackCount), person: $0.name, subtitle: $0.roles.first)
            }, initialCount: 6)
        }
    }
}

struct InsightsLabelsCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Record Labels & Countries", subtitle: "From MusicBrainz release data") {
            if !stats.labels.isEmpty {
                InsightRankedBars(items: stats.labels.map {
                    InsightRankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: SearchFilterKey.token("label", $0.name))
                }, initialCount: 6)
            }
            if !stats.countries.isEmpty {
                InsightChipRow(title: "Released in", chips: stats.countries.map { c in
                    ("\(countryName(c.name)) \(c.count.formatted())", SearchFilterKey.token("country", c.name), countryName(c.name))
                })
            }
        }
    }
}

struct InsightsHealthCard: View {
    let stats: LibraryStats

    var body: some View {
        let total = max(stats.trackCount, 1)
        InsightCard(title: "Metadata Health", subtitle: "How complete your tags are · tap to find gaps") {
            VStack(spacing: 12) {
                ForEach(stats.coverage) { c in
                    let fraction = Double(c.present) / Double(total)
                    let missing = stats.trackCount - c.present
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.label).font(.subheadline)
                            Spacer(minLength: 8)
                            if missing > 0 {
                                NavigationLink(value: QueryRoute(query: "missing:\(c.field.rawValue)", title: "Missing: \(c.label)")) {
                                    HStack(spacing: 2) { Text("\(missing.formatted()) missing"); Image(systemName: "chevron.right") }
                                }
                                .font(.caption.weight(.medium))
                            } else {
                                Label("Complete", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline).monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        InsightBar(fraction: fraction, hidesZero: true)
                    }
                }
            }
        }
    }
}

struct InsightsFunFactsCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightFactsCard(facts: facts)
    }

    private func albumQuery(_ a: LibraryStats.AlbumRef) -> String {
        SearchFilterKey.token("album", a.album) + " " + SearchFilterKey.token("albumartist", a.artist)
    }

    private func songQuery(_ t: LibraryStats.TrackRef) -> String {
        SearchFilterKey.token("title", t.title) + " " + SearchFilterKey.token("artist", t.artist)
    }

    private var facts: [InsightFact] {
        var out: [InsightFact] = []
        let finish = Date().addingTimeInterval(stats.totalDuration)
        out.append(InsightFact(icon: "infinity", title: "Back to back", value: formatLongDuration(stats.totalDuration),
                               detail: "Press play now and you'd finish \(finish.formatted(.relative(presentation: .named))), \(finish.formatted(date: .abbreviated, time: .shortened))"))
        if let a = stats.oldestAlbum, let y = a.year {
            out.append(InsightFact(icon: "clock.arrow.circlepath", title: "Oldest release", value: String(y), detail: "\(a.album) — \(a.artist)", query: albumQuery(a), queryTitle: a.album))
        }
        if let a = stats.newestAlbum, let y = a.year {
            out.append(InsightFact(icon: "sparkles", title: "Newest release", value: String(y), detail: "\(a.album) — \(a.artist)", query: albumQuery(a), queryTitle: a.album))
        }
        if let t = stats.longestTrack {
            out.append(InsightFact(icon: "ruler", title: "Longest track", value: Format.time(t.duration), detail: "\(t.title) — \(t.artist)", query: songQuery(t), queryTitle: t.title))
        }
        if let t = stats.shortestTrack, stats.trackCount > 1 {
            out.append(InsightFact(icon: "bolt", title: "Shortest track", value: Format.time(t.duration), detail: "\(t.title) — \(t.artist)", query: songQuery(t), queryTitle: t.title))
        }
        if let a = stats.longestAlbum, stats.albumCount > 1 {
            out.append(InsightFact(icon: "opticaldisc", title: "Longest album", value: formatLongDuration(a.duration),
                                   detail: "\(a.album) — \(a.artist) · \(songCount(a.trackCount))", query: albumQuery(a), queryTitle: a.album))
        }
        if let y = stats.busiestYear, stats.years.count > 1 {
            out.append(InsightFact(icon: "flame", title: "Busiest year", value: String(y.year), detail: "\(songCount(y.count)) released that year", query: "year:\(y.year)"))
        }
        if let a = stats.artistsByAlbums.first, a.count > 1 {
            out.append(InsightFact(icon: "person.2", title: "Most albums", value: a.name, detail: "\(a.count) albums in your digital collection",
                                   query: SearchFilterKey.token("albumartist", a.name)))
        }
        if let w = stats.titleWords.first {
            out.append(InsightFact(icon: "text.quote", title: "Favorite word in titles", value: "“\(w.name.capitalized)”",
                                   detail: "Appears in \(w.count.formatted()) song titles", query: SearchFilterKey.token("title", w.name), queryTitle: w.name.capitalized))
        }
        if stats.addedLast30Days > 0, stats.addedLast30Days < stats.trackCount {
            out.append(InsightFact(icon: "tray.and.arrow.down", title: "Fresh arrivals", value: stats.addedLast30Days.formatted(),
                                   detail: "songs added in the last 30 days", query: "added:30d", queryTitle: "Added in the Last 30 Days"))
        }
        out.append(InsightFact(icon: "metronome", title: "Average song", value: Format.time(stats.averageTrackLength),
                               detail: "across \(songCount(stats.trackCount))"))
        return out
    }
}
