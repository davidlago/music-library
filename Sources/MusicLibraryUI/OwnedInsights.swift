import Charts
import MusicLibraryCore
import SwiftUI

// The Owned pane of Insights (`CollectionStats`): everything you own, CDs, records and downloads, with or without
// music in the library. The cards are shared by the Mac and iPhone apps; each app keeps the pane that lays them out,
// sets `collectionInsightActions` to open what a card links to, and draws the tiles in its own tile grid and the
// facts (`CollectionFacts`) in its own facts grid, like its other panes. Rows open the item; drill-downs open the
// collection with a query in its search language, never a song search.

// MARK: Links

/// What a card in the Owned pane opens.
public enum CollectionInsightLink: Hashable, Sendable {
    /// A collection item's page.
    case item(id: String)
    /// The items matching a collection query, under a title.
    case query(String, title: String)
    /// The Shelf, or one of its scopes.
    case scope(CollectionScope)
    /// Free and duplicate label numbers.
    case labelCheck(StickerSeries)
    /// A label no item has (Find by Label shows where it would go).
    case freeLabel(Sticker)
    /// Add a copy with the next label in a series (where the collection can be edited).
    case addNext(StickerSeries)
    /// The digital collection's albums you don't own a copy of.
    case notOwnedAlbums
}

/// How the cards open their links, and which ones this app has.
public struct CollectionInsightActions {
    public var open: (CollectionInsightLink) -> Void
    /// Whether the collection is edited here (the Mac): the shelves card offers the next label.
    public var canEdit: Bool
    /// Whether `.notOwnedAlbums` opens anything.
    public var canShowNotOwned: Bool

    public init(canEdit: Bool = false, canShowNotOwned: Bool = false, open: @escaping (CollectionInsightLink) -> Void) {
        self.open = open
        self.canEdit = canEdit
        self.canShowNotOwned = canShowNotOwned
    }
}

private struct CollectionInsightActionsKey: EnvironmentKey {
    static var defaultValue: CollectionInsightActions { CollectionInsightActions { _ in } }
}

extension EnvironmentValues {
    /// Set on the Owned pane (written out rather than with `@Entry`: the Command Line Tools lack SwiftUI's macros).
    public var collectionInsightActions: CollectionInsightActions {
        get { self[CollectionInsightActionsKey.self] }
        set { self[CollectionInsightActionsKey.self] = newValue }
    }
}

// MARK: Words

/// Counts, names, prices and colours for the Owned pane.
public enum CollectionInsightText {
    public static func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }
    public static func albumCount(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }
    /// "8 of 12 albums" when only some of them count, else "12 albums".
    public static func albumCount(_ n: Int, of total: Int) -> String {
        n < total ? "\(n.formatted()) of \(albumCount(total))" : albumCount(total)
    }
    public static func playCount(_ n: Int) -> String { n == 1 ? "1 play" : "\(n.formatted()) plays" }
    public static func dayLabel(_ d: PurchaseDay) -> String { d.date().formatted(date: .abbreviated, time: .omitted) }

    /// A price in the locale's currency (prices are entered and stored in it).
    public static func money(_ amount: Decimal, whole: Bool = false) -> String {
        let code = Locale.current.currency?.identifier ?? "USD"
        return amount.formatted(.currency(code: code).precision(.fractionLength(whole ? 0 : 2)))
    }

    /// "3 hr, 12 min", "2 days, 4 hr".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else {
            let s = seconds.isFinite ? max(Int(seconds.rounded()), 0) : 0
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? ""
    }

    /// "CDs", "Vinyl", "Downloads", or a newer version's medium by its name.
    public static func plural(_ m: CollectionMedium) -> String {
        switch m {
        case .cd: "CDs"
        case .vinyl: "Vinyl"
        case .download: "Downloads"
        case .other(let raw): raw.capitalized
        }
    }

    public static func icon(_ m: CollectionMedium) -> String {
        switch m {
        case .cd: "opticaldisc"
        case .vinyl: "record.circle"
        case .download: "arrow.down.circle"
        case .other: "shippingbox"
        }
    }

    /// The pane's colour per medium, from the quality tiers' ordinal ramp.
    public static func color(_ m: CollectionMedium) -> Color {
        switch m {
        case .cd: VizColor.tier(.hiRes)
        case .vinyl: VizColor.tier(.cd)
        case .download: VizColor.tier(.lossyHigh)
        case .other: VizColor.tier(.lossy)
        }
    }

    /// "312 CDs · 48 vinyl · 97 downloads".
    public static func mediaLine(_ stats: CollectionStats) -> String {
        var parts: [String] = []
        if stats.cdCount > 0 { parts.append("\(stats.cdCount.formatted()) CD\(stats.cdCount == 1 ? "" : "s")") }
        if stats.vinylCount > 0 { parts.append("\(stats.vinylCount.formatted()) vinyl") }
        if stats.downloadCount > 0 { parts.append("\(stats.downloadCount.formatted()) download\(stats.downloadCount == 1 ? "" : "s")") }
        if stats.otherCount > 0 { parts.append("\(stats.otherCount.formatted()) other") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Tiles

/// The pane's tiles: items, digitized, to digitize, spent, this year and per play. They're siblings in a group, so
/// put them in the app's tile grid; the items and to-digitize tiles open the Shelf.
public struct CollectionTiles: View {
    let stats: CollectionStats
    @Environment(\.collectionInsightActions) private var actions

    public init(stats: CollectionStats) { self.stats = stats }

    public var body: some View {
        let T = CollectionInsightText.self
        let year = Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))
        Group {
            link(.scope(.all), help: "Open the Shelf") {
                InsightTile(value: stats.itemCount.formatted(), label: stats.itemCount == 1 ? "Item" : "Items", icon: "books.vertical",
                            detail: T.mediaLine(stats))
            }
            DigitizedTile(stats: stats)
            link(.scope(.toDigitize), help: "Open To Digitize") {
                InsightTile(value: stats.toDigitizeCount.formatted(), label: "To digitize", icon: "waveform.slash", detail: digitizeLine)
            }
            InsightTile(value: stats.pricedCount > 0 ? T.money(stats.totalSpent) : "—", label: "Spent", icon: "creditcard",
                        detail: stats.pricedCount > 0 ? "on \(stats.pricedCount.formatted()) of \(T.itemCount(stats.itemCount))" : addPrices)
            InsightTile(value: T.money(stats.spentThisYear), label: "This year", icon: "calendar",
                        detail: "\(T.itemCount(stats.boughtThisYear)) bought in \(year)")
            InsightTile(value: stats.costPerPlay.map { T.money($0) } ?? "—", label: "Per play", icon: "play.circle",
                        detail: stats.costPerHour.map { "\(T.money($0)) an hour listened" })
        }
    }

    private var addPrices: String {
        actions.canEdit ? "add prices on item pages" : "add prices on the Mac"
    }

    private func link<Content: View>(_ link: CollectionInsightLink, help: String, @ViewBuilder content: () -> Content) -> some View {
        Button { actions.open(link) } label: { content().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(help)
    }

    /// "12 CDs to rip · 3 records".
    private var digitizeLine: String? {
        var parts: [String] = []
        if stats.toRipCount > 0 { parts.append("\(stats.toRipCount.formatted()) CD\(stats.toRipCount == 1 ? "" : "s") to rip") }
        if stats.vinylToDigitizeCount > 0 { parts.append("\(stats.vinylToDigitizeCount.formatted()) record\(stats.vinylToDigitizeCount == 1 ? "" : "s")") }
        return parts.isEmpty ? (stats.physicalCount > 0 ? "All digitized" : nil) : parts.joined(separator: " · ")
    }
}

/// The share of your CDs and records with a digital copy: an `InsightTile` whose icon is a ring.
public struct DigitizedTile: View {
    let stats: CollectionStats

    public init(stats: CollectionStats) { self.stats = stats }

    #if os(macOS)
    static let valueSize: CGFloat = 26, spacing: CGFloat = 4, padding: CGFloat = 14
    #else
    static let valueSize: CGFloat = 22, spacing: CGFloat = 3, padding: CGFloat = 12
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ZStack {
                Circle().stroke(VizColor.track, lineWidth: 4)
                Circle().trim(from: 0, to: stats.digitizedShare)
                    .stroke(VizColor.series, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            Text(stats.digitizedShare.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: Self.valueSize, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text("Digitized").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("of \(stats.physicalCount.formatted()) CDs and records").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shelves

/// Each label series: the numbers used, the next one, free numbers and duplicates; a row opens Label Check. The find
/// field shows what has a label as it's typed ("142" in both series, "v12" in one); Return opens it. Draws nothing
/// while no CD or record is in the collection.
public struct CollectionShelvesCard: View {
    let stats: CollectionStats
    let collection: MusicCollection
    @Environment(\.collectionInsightActions) private var actions
    @State private var find = ""

    public init(stats: CollectionStats, collection: MusicCollection) {
        self.stats = stats
        self.collection = collection
    }

    public var body: some View {
        let shown = stats.series.filter { $0.labeled + $0.unlabeled > 0 }
        if !shown.isEmpty {
            InsightCard(title: "Your Shelves", subtitle: "CDs and records each have their own label numbers") {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider() }
                        row(s)
                    }
                    Divider()
                    findField
                }
            }
        }
    }

    private func row(_ s: CollectionStats.SeriesStats) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { actions.open(.labelCheck(s.series)) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: s.series == .cd ? "opticaldisc" : "record.circle")
                        .foregroundStyle(CollectionInsightText.color(s.series.medium)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(s.series == .cd ? "CDs" : "Vinyl").font(.subheadline.weight(.semibold))
                            if let high = s.highest { Text("#1–#\(high)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                        Text(details(s)).font(.caption)
                            .foregroundStyle(s.duplicates.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        if let next = Sticker(series: s.series, number: s.next) { StickerPill(sticker: next, size: 11) }
                        Text("next").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Free numbers and numbers used twice")
            .accessibilityElement(children: .combine)
            if actions.canEdit {
                Button { actions.open(.addNext(s.series)) } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Add a \(s.series == .cd ? "CD" : "record") with the next label")
                    .accessibilityLabel("Add a \(s.series == .cd ? "CD" : "record") with the next label")
            } else {
                OwnedChevron()
            }
        }
        .padding(.vertical, 8)
    }

    private func details(_ s: CollectionStats.SeriesStats) -> String {
        var parts = ["\(s.labeled.formatted()) labeled"]
        if s.unlabeled > 0 { parts.append("\(s.unlabeled.formatted()) without a label") }
        if s.gapCount > 0 { parts.append("\(s.gapCount.formatted()) free number\(s.gapCount == 1 ? "" : "s")") }
        if !s.duplicates.isEmpty { parts.append("\(s.duplicates.count) duplicate\(s.duplicates.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var findField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(.secondary)
                TextField("Find a label, like 142 or v12", text: $find)
                    .textFieldStyle(.plain)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(go)
                if !find.isEmpty {
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppColor.fill))
            if let parsed = Sticker.parse(find) { results(parsed) }
        }
        .padding(.top, 10)
    }

    private func stickers(_ parsed: (series: StickerSeries?, number: Int)) -> [Sticker] {
        (parsed.series.map { [$0] } ?? StickerSeries.allCases).compactMap { Sticker(series: $0, number: parsed.number) }
    }

    /// The items with the label typed, in either series when it didn't say which.
    @ViewBuilder
    private func results(_ parsed: (series: StickerSeries?, number: Int)) -> some View {
        let stickers = stickers(parsed)
        let hits = stickers.flatMap { collection.items(at: $0) }
        if hits.isEmpty {
            Text(stickers.count == 1 ? "\(stickers[0].text) is free" : "No CD or record has #\(parsed.number)")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(hits) { item in
                Button { actions.open(.item(id: item.id)) } label: {
                    HStack(spacing: 10) {
                        if let sticker = item.sticker { StickerPill(sticker: sticker, size: 11) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.subheadline).lineLimit(1)
                            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        OwnedChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Opens the item at the label typed (CDs first when it didn't say which), else Find by Label on that label.
    private func go() {
        guard let parsed = Sticker.parse(find) else { return }
        let stickers = stickers(parsed)
        if let item = stickers.lazy.flatMap({ collection.items(at: $0) }).first {
            actions.open(.item(id: item.id))
        } else if let first = stickers.first {
            actions.open(.freeLabel(first))
        }
        find = ""
    }
}

// MARK: How you own it

/// A bar per medium split by digital state (digitized, partly, from another copy, to digitize), and the albums of the
/// digital collection you don't own a copy of.
public struct CollectionMediaCard: View {
    let stats: CollectionStats
    @Environment(\.collectionInsightActions) private var actions

    public init(stats: CollectionStats) { self.stats = stats }

    private static let parts: [(part: CollectionStats.MediumShare.Part, name: String, color: Color)] = [
        (.digitized, "Digitized", VizColor.tier(.hiRes)), (.partial, "Partly", VizColor.tier(.cd)),
        (.otherCopy, "From another copy", VizColor.tier(.lossyHigh)), (.toDigitize, "To digitize", VizColor.neutral),
    ]

    public var body: some View {
        InsightCard(title: "How You Own It", subtitle: "Each medium, and how much of it is in your digital collection") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(stats.media) { share in
                    let plural = CollectionInsightText.plural(share.medium)
                    Button { actions.open(.query(SearchFilterKey.token("own", share.medium.rawValue), title: plural)) } label: {
                        mediumRow(share)
                    }
                    .buttonStyle(.plain)
                    .help("Show your \(plural.lowercased())")
                }
                legend
                if stats.notInCollection > 0 {
                    if actions.canShowNotOwned {
                        Button { actions.open(.notOwnedAlbums) } label: { notOwned(link: true) }
                            .buttonStyle(.plain)
                            .help("Show these albums")
                    } else {
                        notOwned(link: false)
                    }
                }
            }
        }
    }

    private func notOwned(link: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(VizColor.neutral).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not owned")
                Text("Albums in your digital collection with no copy you own: borrowed, or not added yet")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(CollectionInsightText.albumCount(stats.notInCollection)).monospacedDigit()
            if link { OwnedChevron() }
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A segment's share of a bar `width` wide that holds `segments` of them 1.5 points apart, at least 3 points.
    private static func segmentWidth(_ count: Int, of total: Int, segments: Int, in width: CGFloat) -> CGFloat {
        let available = width - CGFloat(segments - 1) * 1.5
        return max(3, available * CGFloat(count) / CGFloat(total))
    }

    private func mediumRow(_ share: CollectionStats.MediumShare) -> some View {
        let segments = Self.parts.filter { share.count($0.part) > 0 }
        let total = max(segments.reduce(0) { $0 + share.count($1.part) }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: CollectionInsightText.icon(share.medium))
                    .foregroundStyle(CollectionInsightText.color(share.medium)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CollectionInsightText.plural(share.medium))
                    if let detail = detail(share) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Text(CollectionInsightText.itemCount(share.items)).monospacedDigit()
                OwnedChevron()
            }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(segments, id: \.name) { p in
                        Rectangle().fill(p.color)
                            .frame(width: Self.segmentWidth(share.count(p.part), of: total, segments: segments.count, in: geo.size.width))
                            #if os(macOS)
                            .help("\(p.name): \(CollectionInsightText.itemCount(share.count(p.part)))")
                            .onTapGesture {
                                actions.open(.query(share.query(p.part), title: "\(CollectionInsightText.plural(share.medium)): \(p.name)"))
                            }
                            #endif
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
            .padding(.leading, 30)
            .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "40 digitized · 12 to go · $480 spent".
    private func detail(_ s: CollectionStats.MediumShare) -> String? {
        var bits: [String] = []
        let digital = s.digitized + s.partial + s.otherCopy
        let toGo = s.count(.toDigitize)
        if s.medium.isPhysical {
            bits.append(toGo == 0 ? "all digitized" : "\(digital.formatted()) digitized · \(toGo.formatted()) to go")
        } else if s.partial > 0 {
            bits.append("\(s.partial.formatted()) only partly")
        }
        if s.spent > 0 { bits.append("\(CollectionInsightText.money(s.spent, whole: true)) spent") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var legend: some View {
        FlowLayout(spacing: 12) {
            ForEach(Self.parts, id: \.name) { p in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 10, height: 10)
                    Text(p.name)
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.leading, 30)
    }
}

// MARK: Spending over time

/// What was spent each month or year (by medium), how many items were bought, or the running total. Hover (Mac) or
/// drag across (iPhone) for a period's numbers.
public struct CollectionSpendingCard: View {
    let stats: CollectionStats
    public enum Measure: String, CaseIterable { case spent = "Spent", items = "Items", total = "Running Total" }
    @State private var measure = Measure.spent
    @State private var selected: CollectionStats.Period?

    public init(stats: CollectionStats) { self.stats = stats }

    #if os(macOS)
    private static let gesture = "hover"
    #else
    private static let gesture = "drag"
    #endif

    public var body: some View {
        InsightCard(title: "Spending Over Time", subtitle: subtitle) {
            OwnedSegments(selection: $measure, cases: Measure.allCases) { $0.rawValue }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let p = selected {
                        Text("\(label(p.start)) · \(CollectionInsightText.money(p.spent)) on \(CollectionInsightText.itemCount(p.items)) · \(CollectionInsightText.money(p.cumulative)) in all")
                            .foregroundStyle(.primary)
                    } else {
                        Text("Items with a purchase date, by \(stats.granularity.rawValue) · \(Self.gesture) for details").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).monospacedDigit()
                .frame(minHeight: 16, alignment: .leading)
                chart.frame(height: 190)
            }
        }
    }

    private var unit: Calendar.Component { stats.granularity == .month ? .month : .year }

    /// The media that have spending, in the usual order.
    private var media: [CollectionMedium] {
        let keys = Set(stats.timeline.flatMap(\.spentByMedium.keys))
        return keys.compactMap(CollectionMedium.init(rawValue:)).sorted()
    }

    private var chart: some View {
        let media = self.media
        return Chart {
            ForEach(stats.timeline) { p in
                let faded = selected != nil && selected != p
                switch measure {
                case .spent:
                    ForEach(media, id: \.self) { m in
                        BarMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Spent", (p.spentByMedium[m.rawValue] ?? 0).doubleValue))
                            .foregroundStyle(by: .value("Medium", CollectionInsightText.plural(m)))
                            .opacity(faded ? 0.35 : 1)
                    }
                case .items:
                    BarMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Items", p.items))
                        .foregroundStyle(VizColor.series.opacity(faded ? 0.35 : 1))
                        .cornerRadius(2)
                case .total:
                    AreaMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [VizColor.series.opacity(0.28), VizColor.series.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(VizColor.series)
                }
            }
            if measure == .total, let p = selected {
                RuleMark(x: .value("Period", p.start.date(), unit: unit))
                    .lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartForegroundStyleScale(domain: media.map(CollectionInsightText.plural), range: media.map(CollectionInsightText.color))
        .chartLegend(measure == .spent && media.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if measure == .items {
                        if let v = value.as(Int.self) { Text(v.formatted()) }
                    } else if let v = value.as(Double.self) {
                        Text(CollectionInsightText.money(Decimal(v), whole: true))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                #if os(macOS)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase, let frame = proxy.plotFrame else { selected = nil; return }
                        pick(proxy, x: point.x - geo[frame].origin.x)
                    }
                #else
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { point in
                        guard let frame = proxy.plotFrame else { return }
                        pick(proxy, x: point.x - geo[frame].origin.x)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height), let frame = proxy.plotFrame else { return }
                        pick(proxy, x: v.location.x - geo[frame].origin.x)
                    })
                #endif
            }
        }
    }

    private func pick(_ proxy: ChartProxy, x: CGFloat) {
        guard let date = proxy.value(atX: x, as: Date.self) else { selected = nil; return }
        selected = stats.timeline.last { $0.start.date() <= date } ?? stats.timeline.first
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.timeline.first?.start { parts.append("Since \(label(first))") }
        if let busiest = stats.timeline.max(by: { $0.spent < $1.spent }), busiest.spent > 0 {
            parts.append("biggest \(stats.granularity.rawValue): \(label(busiest.start)), \(CollectionInsightText.money(busiest.spent))")
        }
        return parts.joined(separator: " · ")
    }

    private func label(_ d: PurchaseDay) -> String {
        stats.granularity == .month ? d.date().formatted(.dateTime.month(.wide).year()) : d.date().formatted(.dateTime.year())
    }
}

// MARK: Lists

/// Shelves of items: recently added, to digitize, priciest, best value, still in the wrapper, needing details, and by
/// label (CDs or records; rows always name the series). Rows open the item; `art` draws an item's cover.
public struct CollectionListsCard<Art: View>: View {
    let stats: CollectionStats
    let art: (CollectionItem) -> Art
    @Environment(\.collectionInsightActions) private var actions
    public enum Shelf: String, CaseIterable {
        case recent = "Recently Added", toDigitize = "To Digitize", priciest = "Priciest", value = "Best Value"
        case wrapper = "Still in the Wrapper", details = "Needs Details", label = "By Label"
    }
    @State private var list = Shelf.recent
    @State private var series = StickerSeries.cd
    @State private var expanded = false
    @State private var hovered: String?

    public init(stats: CollectionStats, @ViewBuilder art: @escaping (CollectionItem) -> Art) {
        self.stats = stats
        self.art = art
    }

    public var body: some View {
        let available = Shelf.allCases.filter { !rows($0).isEmpty || ($0 == .label && !stats.byLabel.isEmpty) }
        let current = available.contains(list) ? list : (available.first ?? .recent)
        let shown = rows(current)
        InsightCard(title: "Your Shelves, Sorted", subtitle: subtitle(current)) {
            HStack(spacing: 8) {
                Picker("List", selection: Binding(get: { current }, set: { list = $0 })) {
                    ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                if current == .label {
                    Picker("Series", selection: $series) {
                        ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if shown.isEmpty {
                    Text(current == .label ? "No \(series.name) labels yet." : "Nothing here.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(shown.prefix(expanded ? 50 : 8)) { r in row(r, current) }
                if shown.count > 8 {
                    OwnedShowAll(expanded: $expanded, count: shown.count, max: 50)
                }
            }
        }
        .onChange(of: list) { expanded = false }
        .onChange(of: series) { expanded = false }
    }

    private func rows(_ list: Shelf) -> [CollectionStats.ItemRow] {
        switch list {
        case .recent: stats.recentlyAdded
        case .toDigitize: stats.toDigitize
        case .priciest: stats.priciestList
        case .value: stats.bestValue
        case .wrapper: stats.stillInWrapper
        case .details: stats.needsDetails
        case .label: stats.byLabel[series] ?? []
        }
    }

    private func subtitle(_ list: Shelf) -> String {
        switch list {
        case .recent: "Newest first, by when you bought them"
        case .toDigitize: "CDs and records with no digital copy, oldest bought first"
        case .priciest: "What you paid most for"
        case .value: "Lowest cost per play"
        case .wrapper: "In your digital collection, never played"
        case .details: "Without a purchase date, a price or a label"
        case .label: "In the order of their labels"
        }
    }

    private func row(_ r: CollectionStats.ItemRow, _ list: Shelf) -> some View {
        let item = r.item
        return Button { actions.open(.item(id: item.id)) } label: {
            HStack(spacing: 10) {
                art(item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                    Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    primary(r, list)
                    if let s = secondary(r, list), !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                .lineLimit(1)
                .layoutPriority(1)
                OwnedChevron()
            }
            .font(.subheadline)
            .padding(.vertical, 3).padding(.horizontal, OwnedRow.inset)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered == item.id ? AppColor.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        #endif
        .help("Open \(item.album)")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func primary(_ r: CollectionStats.ItemRow, _ list: Shelf) -> some View {
        let item = r.item
        switch list {
        case .label:
            if let s = item.sticker { StickerPill(sticker: s, size: 10) }
        case .value:
            Text(r.pricePerPlay.map { "\(CollectionInsightText.money($0)) a play" } ?? "").monospacedDigit()
        case .details:
            Text(missing(item))
        case .toDigitize:
            DigitalStatusLabel(state: r.state, medium: item.medium, compact: true)
        default:
            Text(item.price.map { CollectionInsightText.money($0) } ?? "—").monospacedDigit()
        }
    }

    private func secondary(_ r: CollectionStats.ItemRow, _ list: Shelf) -> String? {
        let item = r.item
        let label = item.sticker?.text ?? (item.medium.isPhysical ? item.medium.name : "Download")
        switch list {
        case .value:
            return "\(CollectionInsightText.playCount(r.plays)) · \(item.price.map { CollectionInsightText.money($0) } ?? "")"
        case .label:
            return [item.price.map { CollectionInsightText.money($0) }, item.purchasedOn.map(CollectionInsightText.dayLabel)]
                .compactMap { $0 }.joined(separator: " · ")
        default:
            return [label, item.purchasedOn.map(CollectionInsightText.dayLabel)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "No date or price", "No label".
    private func missing(_ item: CollectionItem) -> String {
        var parts: [String] = []
        if item.purchasedOn == nil { parts.append("date") }
        if item.price == nil { parts.append("price") }
        if item.medium.series != nil, item.stickerNumber == nil { parts.append("label") }
        guard let first = parts.first, let last = parts.last else { return "" }
        return "No " + (parts.count == 1 ? first : parts.dropLast().joined(separator: ", ") + " or " + last)
    }
}

// MARK: Breakdowns

/// Artists by what you've spent on them, or by items owned; rows open their items.
public struct CollectionArtistsCard: View {
    let stats: CollectionStats
    public enum Measure: String, CaseIterable { case spent = "Spent", items = "Items" }
    @State private var measure: Measure?

    public init(stats: CollectionStats) { self.stats = stats }

    public var body: some View {
        if !stats.artists.isEmpty {
            let m = measure ?? (stats.pricedCount > 0 ? .spent : .items)
            InsightCard(title: "Artists", subtitle: "By what you've spent on them, or items owned") {
                OwnedSegments(selection: Binding(get: { m }, set: { measure = $0 }), cases: Measure.allCases) { $0.rawValue }
            } content: {
                OwnedRankedRows(rows: CollectionBreakdownCard.ranked(stats.artists, bySpent: m == .spent, key: "artist"), initialCount: 6)
                    .id(m)
            }
        }
    }
}

/// Genres, release eras or record labels of what you own, with what they cost; rows open their items.
public struct CollectionBreakdownCard: View {
    let stats: CollectionStats
    public enum Kind: String, CaseIterable { case genres = "Genres", decades = "Release Eras", labels = "Record Labels" }
    @State private var kind = Kind.genres

    public init(stats: CollectionStats) { self.stats = stats }

    public var body: some View {
        let available = Kind.allCases.filter { !breakdowns($0).isEmpty }
        if let first = available.first {
            let current = available.contains(kind) ? kind : first
            InsightCard(title: current.rawValue, subtitle: subtitle(current)) {
                OwnedSegments(selection: Binding(get: { current }, set: { kind = $0 }), cases: available) { $0.rawValue }
            } content: {
                OwnedRankedRows(rows: Self.ranked(breakdowns(current), bySpent: false,
                                                  key: current == .decades ? "decade" : current == .labels ? "label" : "genre"),
                                initialCount: 6)
                    .id(current)
            }
        }
    }

    private func breakdowns(_ kind: Kind) -> [CollectionStats.Breakdown] {
        switch kind {
        case .genres: stats.genres
        case .decades: stats.decades
        case .labels: stats.recordLabels
        }
    }

    private func subtitle(_ kind: Kind) -> String {
        switch kind {
        case .genres: "An item can carry several"
        case .decades: "When the music you own came out"
        case .labels: "Who put out what you own"
        }
    }

    /// Rows that open the collection filtered by `key` (`artist:`, `genre:`, `decade:`, `label:`). Decades stay in
    /// order; the rest go by items (or spending), most first.
    static func ranked(_ list: [CollectionStats.Breakdown], bySpent spent: Bool, key: String) -> [OwnedRankedRow] {
        let sorted = spent || key == "decade" ? list : list.sorted { $0.items != $1.items ? $0.items > $1.items : $0.spent > $1.spent }
        let T = CollectionInsightText.self
        return sorted.map { b in
            OwnedRankedRow(name: b.name, value: spent ? b.spent.doubleValue : Double(b.items),
                           detail: spent ? T.money(b.spent) : T.itemCount(b.items) + (b.spent > 0 ? " · \(T.money(b.spent, whole: true))" : ""),
                           subtitle: spent ? T.itemCount(b.items) : nil,
                           query: key == "decade" ? "decade:\(b.name)" : SearchFilterKey.token(key, b.name))
        }
    }
}

// MARK: Facts

/// One of the pane's fun facts; the app draws them in its facts grid.
public struct CollectionFact: Identifiable, Hashable, Sendable {
    public var id: String { title }
    public var icon: String
    public var title: String
    public var value: String
    public var detail: String
    /// The item it's about.
    public var itemID: String?
    /// The items it's about, as a collection query (where the app can list them).
    public var shelfQuery: String?
}

/// The Owned pane's fun facts.
public enum CollectionFacts {
    /// In days for the last two weeks ("9 days ago": the named relative style counts calendar weeks and says "2 weeks
    /// ago"), then relative.
    public static func whenAdded(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        default: return date.formatted(.relative(presentation: .named))
        }
    }

    public static func list(_ stats: CollectionStats) -> [CollectionFact] {
        let T = CollectionInsightText.self
        func describe(_ item: CollectionItem) -> String {
            [item.sticker?.text, "\(item.album) — \(item.artist)"].compactMap { $0 }.joined(separator: " · ")
        }
        var out: [CollectionFact] = []
        if let item = stats.oldestRelease, let year = item.year {
            out.append(CollectionFact(icon: "clock.arrow.circlepath", title: "Oldest release you own", value: String(year),
                                      detail: describe(item), itemID: item.id))
        }
        if let item = stats.newestAddition {
            out.append(CollectionFact(icon: "sparkles", title: "Newest addition", value: whenAdded(item.purchasedOn?.date() ?? item.createdAt),
                                      detail: describe(item), itemID: item.id))
        }
        if let most = stats.mostCopies {
            out.append(CollectionFact(icon: "square.on.square", title: "Most copies of one album", value: "\(most.copies) copies",
                                      detail: "\(most.item.album) — \(most.item.artist)", itemID: most.item.id,
                                      shelfQuery: SearchFilterKey.token("album", most.item.album) + " copies:>1"))
        }
        if let box = stats.biggestBox, let discs = box.discCount {
            out.append(CollectionFact(icon: "shippingbox", title: "Biggest box", value: "\(discs) discs", detail: describe(box), itemID: box.id))
        }
        if let r = stats.priciest, let price = r.item.price {
            out.append(CollectionFact(icon: "crown", title: "Priciest", value: T.money(price), detail: describe(r.item), itemID: r.item.id))
        }
        if let r = stats.cheapest, let price = r.item.price {
            out.append(CollectionFact(icon: "tag", title: price == 0 ? "Got it for free" : "Best bargain", value: T.money(price),
                                      detail: describe(r.item), itemID: r.item.id))
        }
        if stats.runtime > 0 {
            out.append(CollectionFact(icon: "infinity", title: "Everything you own, back to back", value: T.duration(stats.runtime),
                                      detail: "across \(T.albumCount(stats.runtimeAlbums, of: stats.albumsOwned)) you own"))
        }
        if stats.waitingForTurntable > 0 {
            out.append(CollectionFact(icon: "record.circle", title: "Waiting for a turntable", value: stats.waitingForTurntable.formatted(),
                                      detail: "record\(stats.waitingForTurntable == 1 ? "" : "s") not digitized yet",
                                      shelfQuery: "own:vinyl ripped:no"))
        }
        if !stats.stillInWrapper.isEmpty {
            out.append(CollectionFact(icon: "gift", title: "Still in the wrapper", value: stats.stillInWrapper.count.formatted(),
                                      detail: "item\(stats.stillInWrapper.count == 1 ? "" : "s") in your digital collection you haven't played yet"))
        }
        if !stats.needsDetails.isEmpty {
            out.append(CollectionFact(icon: "pencil", title: "Needs details", value: stats.needsDetails.count.formatted(),
                                      detail: "item\(stats.needsDetails.count == 1 ? " is" : "s are") missing a date, a price or a label"))
        }
        return out
    }
}

// MARK: Building blocks

/// Row metrics: the Mac highlights a row on hover, so its rows are inset; the iPhone's run to the card's edge.
private enum OwnedRow {
    #if os(macOS)
    static let inset: CGFloat = 6
    #else
    static let inset: CGFloat = 0
    #endif
}

/// A trailing chevron for rows that open something (iPhone; the Mac's rows highlight on hover instead).
private struct OwnedChevron: View {
    var body: some View {
        #if !os(macOS)
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        #endif
    }
}

/// A card's segmented picker: beside the title on the Mac, the card's width under it on the iPhone.
private struct OwnedSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let cases: [Value]
    let title: (Value) -> String

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(cases, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        #if os(macOS)
        .fixedSize()
        #endif
    }
}

/// "Show all 24" / "Show less" under a list.
private struct OwnedShowAll: View {
    @Binding var expanded: Bool
    let count: Int
    let max: Int

    var body: some View {
        let all = "\(Swift.min(count, max))\(count > max ? " of \(count)" : "")"
        #if os(macOS)
        Button(expanded ? "Show less" : "Show all \(all)") { withAnimation(.snappy) { expanded.toggle() } }
            .buttonStyle(.link).font(.caption).padding(.top, 4).padding(.leading, 6)
        #else
        Button(expanded ? "Show Less" : "Show All \(all)") { withAnimation(.snappy) { expanded.toggle() } }
            .font(.footnote.weight(.medium)).padding(.top, 6)
        #endif
    }
}

struct OwnedRankedRow: Identifiable {
    var id: String { name }
    var name: String
    var value: Double
    var detail: String
    var subtitle: String?
    /// The collection query the row opens.
    var query: String
}

/// A ranked list with proportional bars that open the collection; shows the top few and expands to the rest. On the
/// Mac the bar sits between the name and the number, on the iPhone under them, like the other panes' lists.
private struct OwnedRankedRows: View {
    let rows: [OwnedRankedRow]
    var initialCount = 8
    var maxCount = 50
    @Environment(\.collectionInsightActions) private var actions
    @State private var expanded = false
    @State private var hovered: String?

    var body: some View {
        let shown = Array(rows.prefix(expanded ? maxCount : initialCount))
        let top = Swift.max(rows.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { row in
                Button { actions.open(.query(row.query, title: row.name)) } label: { label(row, fraction: row.value / top) }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
                    #endif
                    .help("Show \(row.name)")
            }
            if rows.count > initialCount {
                OwnedShowAll(expanded: $expanded, count: rows.count, max: maxCount)
            }
        }
    }

    private func names(_ row: OwnedRankedRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name).lineLimit(1)
            if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func bar(_ fraction: Double, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VizColor.track)
                Capsule().fill(VizColor.series).frame(width: Swift.max(4, geo.size.width * Swift.min(Swift.max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }

    private func label(_ row: OwnedRankedRow, fraction: Double) -> some View {
        Group {
            #if os(macOS)
            HStack(spacing: 10) {
                names(row).frame(width: 150, alignment: .leading)
                bar(fraction, height: 8)
                Text(row.detail).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 70, alignment: .trailing)
            }
            .font(.callout)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered == row.id ? AppColor.fill : .clear))
            #else
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    names(row)
                    Spacer(minLength: 8)
                    Text(row.detail).font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                    OwnedChevron()
                }
                bar(fraction, height: 6)
            }
            .font(.subheadline)
            .padding(.vertical, 5)
            #endif
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
