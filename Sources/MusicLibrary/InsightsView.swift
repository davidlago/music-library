import AppKit
import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Palette

extension Color {
    /// A color with separate sRGB values for light and dark appearances.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

/// Chart colors, validated for contrast and color-vision deficiency against the card surface in both appearances.
enum VizColor {
    /// Single-series marks.
    static let series = Color(light: 0x2a78d6, dark: 0x3987e5)

    /// Ordinal blue ramp for quality tiers, best quality most prominent; "unknown" is neutral gray.
    static func tier(_ t: LibraryStats.QualityTier) -> Color {
        switch t {
        case .hiRes: Color(light: 0x104281, dark: 0xcde2fb)
        case .cd: Color(light: 0x256abf, dark: 0x86b6ef)
        case .lossyHigh: Color(light: 0x5598e7, dark: 0x3987e5)
        case .lossy: Color(light: 0x86b6ef, dark: 0x1c5cab)
        case .unknown: Color(light: 0xb5b4ae, dark: 0x5f5e5a)
        }
    }

    static let card = Color(nsColor: .controlBackgroundColor)
    static let track = Color.primary.opacity(0.07)
}

// MARK: Page

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("insightsPane") private var pane = Pane.library
    @AppStorage("listeningPeriod") private var period = ListeningStats.Period.month

    enum Pane: String, CaseIterable, Identifiable {
        case library = "Library", listening = "Listening", owned = "Owned"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if model.totalTracks == 0 {
                ContentUnavailableView("No Insights Yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Import some music and this page fills in with stats about your collection."))
            } else {
                switch pane {
                case .library:
                    if let stats = model.stats {
                        InsightsContent(stats: stats)
                    } else {
                        ProgressView("Crunching the numbers…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .listening:
                    if let stats = model.listening, stats.period == period || !stats.hasHistory {
                        ListeningContent(stats: stats, period: $period)
                    } else {
                        ProgressView("Crunching the numbers…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .owned:
                    if let stats = model.ownershipStats {
                        OwnedContent(stats: stats)
                    } else {
                        ProgressView("Crunching the numbers…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Insights", selection: $pane) { ForEach(Pane.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Your collection, what you listen to, or the albums you own and what you paid")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.libraryVersion) { load() }
        .onChange(of: model.historyVersion) { load() }
        .onChange(of: model.purchasesVersion) { load() }
        .onChange(of: pane) { load() }
        .onChange(of: period) { load() }
    }

    private func load() {
        switch pane {
        case .library: model.loadStatsIfNeeded()
        case .listening: model.loadListeningIfNeeded(period)
        case .owned: model.loadOwnershipIfNeeded()
        }
    }
}

struct InsightsContent: View {
    let stats: LibraryStats

    var body: some View {
        ScrollView { InsightsStack(stats: stats) }
    }
}

struct InsightsStack: View {
    let stats: LibraryStats

    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HeroTiles(stats: stats)
                if !stats.years.isEmpty { TimelineCard(stats: stats) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    if !stats.genres.isEmpty { GenresCard(stats: stats) }
                    ArtistsCard(stats: stats)
                    QualityCard(stats: stats)
                    GrowthCard(stats: stats)
                    LengthCard(stats: stats)
                    if !stats.people.isEmpty { PeopleCard(stats: stats) }
                    if !stats.labels.isEmpty || !stats.countries.isEmpty { LabelsCard(stats: stats) }
                    HealthCard(stats: stats)
                }
                FunFactsCard(stats: stats)
            }
            .padding(20)
    }
}

// MARK: Building blocks

struct InsightCard<Content: View, Accessory: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.subtext) }
                }
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension InsightCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

struct RankedItem: Identifiable {
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

/// A clickable ranked list with proportional bars; shows the top few and expands to the rest.
struct RankedBars: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let items: [RankedItem]
    var initialCount = 8
    var maxCount = 50
    @State private var expanded = false
    @State private var hovered: String?

    var body: some View {
        let shown = Array(items.prefix(expanded ? maxCount : initialCount))
        let top = max(items.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { item in
                Button {
                    if let person = item.person { model.showMusicDNA(person) } else if let q = item.query { model.search(q) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).lineLimit(1)
                            if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.subtext).lineLimit(1) }
                        }
                        .frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.track)
                                Capsule().fill(theme.series)
                                    .frame(width: max(4, geo.size.width * item.value / top))
                            }
                        }
                        .frame(height: 8)
                        Text(item.detail).monospacedDigit().foregroundStyle(.subtext)
                            .lineLimit(1).frame(minWidth: 70, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hovered == item.id && (item.query != nil || item.person != nil) ? theme.fill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .help(item.person.map { "Show \($0)'s Music DNA" } ?? item.query.map { "Search \($0)" } ?? "")
            }
            if items.count > initialCount {
                Button(expanded ? "Show less" : "Show all \(min(items.count, maxCount))\(items.count > maxCount ? " of \(items.count)" : "")") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.link).font(.caption).padding(.top, 4).padding(.leading, 6)
            }
        }
    }
}

struct ColumnDatum: Identifiable {
    var id: String { label }
    var label: String
    var value: Int
    var query: String?
}

/// A single-series column chart with hover readout; clicking a column searches for its songs.
struct ColumnChart: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let data: [ColumnDatum]
    var axisLabels: [String]?
    var unit = "songs"
    var height: CGFloat = 170
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let h = hovered, let d = data.first(where: { $0.label == h }) {
                    Text("\(d.label) · \(d.value.formatted()) \(d.value == 1 ? String(unit.dropLast()) : unit)").foregroundStyle(.primary)
                } else {
                    Text("Hover for details, click a column to see its songs").foregroundStyle(.subtext)
                }
            }
            .font(.caption).monospacedDigit()
            Chart(data) { d in
                BarMark(x: .value("Bucket", d.label), y: .value("Songs", d.value), width: .ratio(0.82))
                    .foregroundStyle(theme.series.opacity(hovered == nil || hovered == d.label ? 1 : 0.35))
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
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): hovered = label(at: p, proxy, geo)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { p in
                            if let l = label(at: p, proxy, geo), let q = data.first(where: { $0.label == l })?.query { model.search(q) }
                        }
                }
            }
            .frame(height: height)
        }
    }

    private func label(at p: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> String? {
        guard let frame = proxy.plotFrame else { return nil }
        let origin = geo[frame].origin
        return proxy.value(atX: p.x - origin.x, as: String.self)
    }
}

/// Evenly spaced axis labels so dense category axes stay readable.
func sparseLabels(_ labels: [String], maxCount: Int) -> [String] {
    guard labels.count > maxCount else { return labels }
    let step = Int((Double(labels.count) / Double(maxCount)).rounded(.up))
    return labels.enumerated().filter { $0.offset % step == 0 }.map(\.element)
}

/// Lays children out left to right, wrapping onto new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > maxWidth {
                rows.append((current, y, x - spacing, height))
                y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(i)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}

struct Chip: View {
    @Environment(\.theme) private var theme
    let text: String
    var query: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { if let query { model.search(query) } } label: {
            Text(text).font(.caption).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(theme.fill))
        }
        .buttonStyle(.plain)
        .help(query.map { "Search \($0)" } ?? "")
    }
}

// MARK: Hero

struct HeroTiles: View {
    let stats: LibraryStats

    var body: some View {
        let lossless = stats.trackCount == 0 ? 0 : Double(stats.losslessCount) / Double(stats.trackCount)
        TileGrid {
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

struct TileGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12, content: content)
    }
}

/// A big number with a label, and optionally a line of context under it.
struct InsightTile: View {
    @Environment(\.theme) private var theme
    let value: String
    let label: String
    let icon: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.callout).foregroundStyle(.subtext)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.subtext)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.subtext).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: Cards

struct TimelineCard: View {
    let stats: LibraryStats
    enum Scale: String, CaseIterable { case auto = "Auto", years = "Years", decades = "Decades" }
    @State private var scale = Scale.auto

    var body: some View {
        let span = (stats.years.last?.year ?? 0) - (stats.years.first?.year ?? 0)
        let useYears = scale == .years || (scale == .auto && span <= 40)
        let data = useYears ? yearData : decadeData
        InsightCard(title: "Through the Years", subtitle: subtitle) {
            Picker("", selection: $scale) { ForEach(Scale.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            ColumnChart(data: data, axisLabels: sparseLabels(data.map(\.label), maxCount: useYears ? 12 : 16), height: 190)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.years.first?.year, let last = stats.years.last?.year { parts.append(first == last ? "All from \(first)" : "\(first)–\(last)") }
        if let m = stats.medianYear { parts.append("half your music is from \(m) or earlier") }
        return parts.joined(separator: " · ")
    }

    /// Every year in range, including empty ones, so gaps in the collection show as gaps.
    private var yearData: [ColumnDatum] {
        guard let first = stats.years.first?.year, let last = stats.years.last?.year else { return [] }
        let counts = Dictionary(uniqueKeysWithValues: stats.years.map { ($0.year, $0.count) })
        return (first...last).map { ColumnDatum(label: String($0), value: counts[$0] ?? 0, query: "year:\($0)") }
    }

    private var decadeData: [ColumnDatum] {
        guard let first = stats.decades.first?.year, let last = stats.decades.last?.year else { return [] }
        let counts = Dictionary(uniqueKeysWithValues: stats.decades.map { ($0.year, $0.count) })
        return stride(from: first, through: last, by: 10).map { ColumnDatum(label: "\($0)s", value: counts[$0] ?? 0, query: "decade:\($0)s") }
    }
}

struct GenresCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Genres", subtitle: "\(stats.genres.count) genre\(stats.genres.count == 1 ? "" : "s") · songs can carry several") {
            RankedBars(items: stats.genres.map {
                RankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: SearchFilterKey.token("genre", $0.name))
            })
        }
    }
}

struct ArtistsCard: View {
    let stats: LibraryStats
    enum Measure: String, CaseIterable { case songs = "Songs", time = "Time", albums = "Albums" }
    @State private var measure = Measure.songs

    var body: some View {
        InsightCard(title: "Top Artists", subtitle: "\(stats.artistCount.formatted()) album artist\(stats.artistCount == 1 ? "" : "s")") {
            Picker("", selection: $measure) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            RankedBars(items: items).id(measure)
        }
    }

    private var items: [RankedItem] {
        func query(_ name: String) -> String? { name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", name) }
        switch measure {
        case .songs:
            return stats.artistsByTracks.map { RankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: query($0.name)) }
        case .time:
            return stats.artistsByDuration.map { RankedItem(name: $0.name, value: $0.duration, detail: formatLongDuration($0.duration), query: query($0.name)) }
        case .albums:
            return stats.artistsByAlbums.map { RankedItem(name: $0.name, value: Double($0.count), detail: "\($0.count) album\($0.count == 1 ? "" : "s")", query: query($0.name)) }
        }
    }
}

struct QualityCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let stats: LibraryStats

    var body: some View {
        let total = max(stats.trackCount, 1)
        InsightCard(title: "Audio Quality", subtitle: "How your files are encoded") {
            HStack(alignment: .center, spacing: 20) {
                Chart(stats.qualityTiers) { t in
                    SectorMark(angle: .value("Songs", t.count), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(theme.tier(t.tier))
                        .cornerRadius(2)
                }
                .chartLegend(.hidden)
                .chartBackground { _ in
                    VStack(spacing: 0) {
                        Text((Double(stats.losslessCount) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Text("lossless").font(.caption2).foregroundStyle(.subtext)
                    }
                }
                .frame(width: 130, height: 130)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(stats.qualityTiers) { t in
                        Button { if let q = t.tier.query { model.search(q) } } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(theme.tier(t.tier)).frame(width: 12, height: 12)
                                Text(t.tier.rawValue)
                                Spacer()
                                Text(songCount(t.count)).foregroundStyle(.subtext).monospacedDigit()
                                Text((Double(t.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                            .font(.callout).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                chipRow("Formats", stats.codecs.map { ("\($0.name) \($0.count.formatted())", SearchFilterKey.token("format", $0.name.lowercased())) })
                if !stats.sampleRates.isEmpty {
                    chipRow("Sample rates", stats.sampleRates.map { ("\($0.name) \($0.count.formatted())", "rate:" + $0.name.replacingOccurrences(of: " kHz", with: "")) })
                }
                if !stats.bitDepths.isEmpty {
                    chipRow("Bit depths", stats.bitDepths.map { ("\($0.name) \($0.count.formatted())", "bits:" + $0.name.replacingOccurrences(of: "-bit", with: "")) })
                }
            }
        }
    }

    private func chipRow(_ title: String, _ chips: [(String, String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.subtext).frame(width: 84, alignment: .leading)
            FlowLayout { ForEach(chips, id: \.0) { Chip(text: $0.0, query: $0.1) } }
        }
    }
}

struct GrowthCard: View {
    @Environment(\.theme) private var theme
    let stats: LibraryStats
    @State private var hovered: LibraryStats.GrowthPoint?

    var body: some View {
        InsightCard(title: "Library Growth", subtitle: subtitle) {
            if stats.growth.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if let h = hovered {
                            Text("\(period(h.date)) · +\(h.added.formatted()) → \(songCount(h.total))").foregroundStyle(.primary)
                        } else {
                            Text("Songs in your library over time").foregroundStyle(.subtext)
                        }
                    }
                    .font(.caption).monospacedDigit()
                    Chart {
                        ForEach(stats.growth) { p in
                            AreaMark(x: .value("Date", p.date), y: .value("Songs", p.total))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(LinearGradient(colors: [theme.series.opacity(0.28), theme.series.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Date", p.date), y: .value("Songs", p.total))
                                .interpolationMethod(.stepEnd)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .foregroundStyle(theme.series)
                        }
                        if let h = hovered {
                            RuleMark(x: .value("Date", h.date)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.6))
                            PointMark(x: .value("Date", h.date), y: .value("Songs", h.total))
                                .symbolSize(70).foregroundStyle(theme.series)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel()
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    guard case .active(let p) = phase, let frame = proxy.plotFrame,
                                          let date = proxy.value(atX: p.x - geo[frame].origin.x, as: Date.self) else { hovered = nil; return }
                                    hovered = stats.growth.last { $0.date <= date } ?? stats.growth.first
                                }
                        }
                    }
                    .frame(height: 170)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(.subtext)
                    Text("All \(songCount(stats.trackCount)) arrived \(stats.firstAdded.map { "on " + $0.formatted(date: .long, time: .omitted) } ?? "together").")
                    Text("Your growth curve starts with your next import.").foregroundStyle(.subtext)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
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

struct LengthCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Track Lengths", subtitle: "Minutes · average \(formatTime(stats.averageTrackLength))") {
            ColumnChart(data: stats.lengthBuckets.map { ColumnDatum(label: $0.label, value: $0.count, query: $0.query) },
                        axisLabels: sparseLabels(stats.lengthBuckets.map(\.label), maxCount: 11))
        }
    }
}

struct PeopleCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Most Credited", subtitle: "Players, producers and engineers across your music") {
            RankedBars(items: stats.people.map {
                RankedItem(name: $0.name, value: Double($0.trackCount),
                           detail: ($0.roles.first.map { "\($0) · " } ?? "") + songCount($0.trackCount),
                           person: $0.name)
            }, initialCount: 6)
        }
    }
}

struct LabelsCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Labels & Countries", subtitle: "From MusicBrainz release data") {
            if !stats.labels.isEmpty {
                RankedBars(items: stats.labels.map {
                    RankedItem(name: $0.name, value: Double($0.count), detail: songCount($0.count), query: SearchFilterKey.token("label", $0.name))
                }, initialCount: 6)
            }
            if !stats.countries.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Released in").font(.caption).foregroundStyle(.subtext)
                    FlowLayout {
                        ForEach(stats.countries) { c in
                            Chip(text: "\(Self.countryName(c.name)) \(c.count.formatted())", query: SearchFilterKey.token("country", c.name))
                        }
                    }
                }
            }
        }
    }

    static func countryName(_ code: String) -> String {
        if code.uppercased() == "XW" { return "Worldwide" }
        if code.uppercased() == "XE" { return "Europe" }
        return Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

struct HealthCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let stats: LibraryStats

    var body: some View {
        let total = max(stats.trackCount, 1)
        InsightCard(title: "Metadata Health", subtitle: "How complete your tags are · click to find gaps") {
            VStack(spacing: 8) {
                ForEach(stats.coverage) { c in
                    let fraction = Double(c.present) / Double(total)
                    let missing = stats.trackCount - c.present
                    HStack(spacing: 10) {
                        Text(c.label).font(.callout).frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.track)
                                Capsule().fill(theme.series).frame(width: c.present == 0 ? 0 : max(4, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 8)
                        Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.callout).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Group {
                            if missing > 0 {
                                Button("\(missing.formatted()) missing") { model.search("missing:\(c.field.rawValue)") }
                                    .buttonStyle(.link)
                            } else {
                                Label("Complete", systemImage: "checkmark").foregroundStyle(.subtext)
                            }
                        }
                        .font(.caption).frame(width: 90, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct FunFact: Identifiable {
    var id: String { title }
    var icon: String
    var title: String
    var value: String
    var detail: String
    var query: String?
}

/// A grid of fun facts; facts with a query search for it when clicked.
struct FactsGrid: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let facts: [FunFact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(facts) { f in
                Button { if let q = f.query { model.search(q) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: f.icon).font(.title3).foregroundStyle(theme.series).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.caption).foregroundStyle(.subtext)
                            Text(f.value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(f.detail).font(.caption).foregroundStyle(.subtext).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill.opacity(0.7)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(f.query.map { "Search \($0)" } ?? "")
            }
        }
    }
}

struct FunFactsCard: View {
    let stats: LibraryStats

    var body: some View {
        InsightCard(title: "Fun Facts") { FactsGrid(facts: facts) }
    }

    private func albumQuery(_ a: LibraryStats.AlbumRef) -> String {
        SearchFilterKey.token("album", a.album) + " " + SearchFilterKey.token("albumartist", a.artist)
    }

    private var facts: [FunFact] {
        var out: [FunFact] = []
        let finish = Date().addingTimeInterval(stats.totalDuration)
        out.append(FunFact(icon: "infinity", title: "Back to back", value: formatLongDuration(stats.totalDuration),
                           detail: "Press play now and you'd finish \(finish.formatted(.relative(presentation: .named))), \(finish.formatted(date: .abbreviated, time: .shortened))"))
        if let a = stats.oldestAlbum, let y = a.year {
            out.append(FunFact(icon: "clock.arrow.circlepath", title: "Oldest release", value: String(y), detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if let a = stats.newestAlbum, let y = a.year {
            out.append(FunFact(icon: "sparkles", title: "Newest release", value: String(y), detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if let t = stats.longestTrack {
            out.append(FunFact(icon: "ruler", title: "Longest track", value: formatTime(t.duration), detail: "\(t.title) — \(t.artist)",
                               query: SearchFilterKey.token("title", t.title) + " " + SearchFilterKey.token("artist", t.artist)))
        }
        if let t = stats.shortestTrack, stats.trackCount > 1 {
            out.append(FunFact(icon: "bolt", title: "Shortest track", value: formatTime(t.duration), detail: "\(t.title) — \(t.artist)",
                               query: SearchFilterKey.token("title", t.title) + " " + SearchFilterKey.token("artist", t.artist)))
        }
        if let a = stats.longestAlbum, stats.albumCount > 1 {
            out.append(FunFact(icon: "opticaldisc", title: "Longest album", value: formatLongDuration(a.duration),
                               detail: "\(a.album) — \(a.artist) · \(songCount(a.trackCount))", query: albumQuery(a)))
        }
        if let y = stats.busiestYear, stats.years.count > 1 {
            out.append(FunFact(icon: "flame", title: "Busiest year", value: String(y.year), detail: "\(songCount(y.count)) released that year", query: "year:\(y.year)"))
        }
        if let a = stats.artistsByAlbums.first, a.count > 1 {
            out.append(FunFact(icon: "person.2", title: "Most albums", value: a.name, detail: "\(a.count) albums in your library",
                               query: SearchFilterKey.token("albumartist", a.name)))
        }
        if let w = stats.titleWords.first {
            out.append(FunFact(icon: "text.quote", title: "Favorite word in titles", value: "“\(w.name.capitalized)”",
                               detail: "Appears in \(w.count.formatted()) song titles", query: SearchFilterKey.token("title", w.name)))
        }
        if stats.addedLast30Days > 0, stats.addedLast30Days < stats.trackCount {
            out.append(FunFact(icon: "tray.and.arrow.down", title: "Fresh arrivals", value: stats.addedLast30Days.formatted(),
                               detail: "songs added in the last 30 days", query: "added:30d"))
        }
        out.append(FunFact(icon: "metronome", title: "Average song", value: formatTime(stats.averageTrackLength),
                           detail: "across \(songCount(stats.trackCount))"))
        return out
    }
}
