import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Collection pane of Insights (`CollectionStats`): everything you own, CDs, records and downloads, with or
/// without music in the library: how much of it is digitized, your label series, what you paid and how much you
/// play it. Rows open the item; drill-downs open the Shelf with a collection query, never a song search.
struct CollectionContent: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats

    var body: some View {
        if stats.itemCount == 0 {
            VStack(spacing: 14) {
                ContentUnavailableView("Nothing Owned Yet", systemImage: "books.vertical",
                                       description: Text("Add the CDs, records and downloads you own: by barcode or by name, from an album page, or when you rip a CD. Add when you bought them and what you paid, and this page fills in."))
                HStack {
                    Button("Add to Physical Collection…") { model.addToCollection() }
                    Button("Add Albums You Own from Your Digital Collection…") { model.collectionSheet = .addLibraryAlbums }
                        .disabled(model.albums.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CollectionTiles(stats: stats)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        ShelvesCard(stats: stats)
                        HowYouOwnItCard(stats: stats)
                    }
                    if !stats.timeline.isEmpty { CollectionSpendingCard(stats: stats) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        CollectionListsCard(stats: stats)
                        CollectionArtistsCard(stats: stats)
                        CollectionBreakdownCard(stats: stats)
                    }
                    CollectionFactsCard(stats: stats)
                }
                .padding(20)
            }
        }
    }
}

func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }

private func dayLabel(_ d: PurchaseDay) -> String { d.date().formatted(date: .abbreviated, time: .omitted) }

/// The colours of the media, from the quality tiers' ordinal ramp.
private extension AppColor {
    static func color(_ medium: CollectionMedium) -> Color {
        switch medium {
        case .cd: tier(.hiRes)
        case .vinyl: tier(.cd)
        case .download: tier(.lossyHigh)
        case .other: tier(.lossy)
        }
    }
}

private extension CollectionMedium {
    /// "CDs", "Vinyl", "Downloads".
    var plural: String {
        switch self {
        case .cd: "CDs"
        case .vinyl: "Vinyl"
        case .download: "Downloads"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .cd: "opticaldisc"
        case .vinyl: "record.circle"
        case .download: "arrow.down.circle"
        case .other: "shippingbox"
        }
    }

    /// The Shelf query of this medium.
    var query: String { "own:\(rawValue)" }
}

// MARK: Tiles

struct CollectionTiles: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats

    var body: some View {
        let year = Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))
        TileGrid {
            tile(.all) {
                InsightTile(value: stats.itemCount.formatted(), label: stats.itemCount == 1 ? "Item" : "Items", icon: "books.vertical",
                            detail: mediaLine)
            }
            DigitizedTile(stats: stats)
            tile(.toDigitize) {
                InsightTile(value: stats.toDigitizeCount.formatted(), label: "To digitize", icon: "waveform.slash",
                            detail: digitizeLine)
            }
            InsightTile(value: stats.pricedCount > 0 ? formatMoney(stats.totalSpent) : "—", label: "Spent", icon: "creditcard",
                        detail: stats.pricedCount > 0 ? "on \(stats.pricedCount.formatted()) of \(itemCount(stats.itemCount))" : "add prices on item pages")
            InsightTile(value: formatMoney(stats.spentThisYear), label: "This year", icon: "calendar",
                        detail: "\(itemCount(stats.boughtThisYear)) bought in \(year)")
            if let perPlay = stats.costPerPlay {
                InsightTile(value: formatMoney(perPlay), label: "Per play", icon: "play.circle",
                            detail: stats.costPerHour.map { "\(formatMoney($0)) an hour" })
            }
        }
    }

    /// A tile that opens the Shelf (or one of its scopes).
    private func tile<Content: View>(_ scope: CollectionScope, @ViewBuilder content: () -> Content) -> some View {
        Button { model.showShelf(scope: scope) } label: { content().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help("Open \(scope.title)")
    }

    /// "312 CDs · 48 vinyl · 97 downloads".
    private var mediaLine: String {
        var parts: [String] = []
        if stats.cdCount > 0 { parts.append("\(stats.cdCount.formatted()) CD\(stats.cdCount == 1 ? "" : "s")") }
        if stats.vinylCount > 0 { parts.append("\(stats.vinylCount.formatted()) vinyl") }
        if stats.downloadCount > 0 { parts.append("\(stats.downloadCount.formatted()) download\(stats.downloadCount == 1 ? "" : "s")") }
        if stats.otherCount > 0 { parts.append("\(stats.otherCount.formatted()) other") }
        return parts.joined(separator: " · ")
    }

    private var digitizeLine: String? {
        var parts: [String] = []
        if stats.toRipCount > 0 { parts.append("\(stats.toRipCount.formatted()) CD\(stats.toRipCount == 1 ? "" : "s") to rip") }
        if stats.vinylToDigitizeCount > 0 { parts.append("\(stats.vinylToDigitizeCount.formatted()) record\(stats.vinylToDigitizeCount == 1 ? "" : "s")") }
        return parts.isEmpty ? (stats.physicalCount > 0 ? "all digitized" : nil) : parts.joined(separator: " · ")
    }
}

/// The share of your CDs and records with a digital copy, as a ring.
struct DigitizedTile: View {
    let stats: CollectionStats

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(AppColor.track, lineWidth: 7)
                Circle().trim(from: 0, to: stats.digitizedShare)
                    .stroke(AppColor.series, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(stats.digitizedShare.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text("Digitized").font(.caption).foregroundStyle(.secondary)
                Text("of \(stats.physicalCount.formatted()) CDs and records").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColor.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shelves

/// Your label series: the range used, how many are labeled, the next number, free numbers and duplicates, with Label
/// Check and a field to find a label.
struct ShelvesCard: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats
    @State private var find = ""

    var body: some View {
        InsightCard(title: "Your Shelves", subtitle: "CDs and records each have their own label numbers") {
            Button("Label Check") { model.collectionSheet = .labelCheck }
                .buttonStyle(.link).font(.caption)
                .help("Free numbers and numbers used twice, in each series")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(stats.series) { s in row(s) }
                HStack(spacing: 6) {
                    Image(systemName: "number.square").foregroundStyle(.secondary)
                    TextField("Find a label", text: $find, prompt: Text("Find a label: cd 12, vinyl 7"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(go)
                }
                .font(.callout)
            }
        }
    }

    private func row(_ s: CollectionStats.SeriesStats) -> some View {
        let duplicates = s.duplicates.count
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(s.series.name).font(.callout.weight(.semibold)).frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.highest.map { "\(s.series.name) #1–#\($0) · \(s.labeled.formatted()) labeled" } ?? "No labels yet")
                    .monospacedDigit()
                Text(detail(s, duplicates: duplicates)).font(.caption).foregroundStyle(duplicates > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            Button("Next \(s.series.name) #\(s.next)") { model.addToCollection(medium: s.series.medium) }
                .buttonStyle(.link).font(.caption).monospacedDigit()
                .help("Add a \(s.series == .cd ? "CD" : "record") with the next label")
        }
        .font(.callout)
    }

    private func detail(_ s: CollectionStats.SeriesStats, duplicates: Int) -> String {
        var parts: [String] = []
        if s.gapCount > 0 { parts.append("\(s.gapCount.formatted()) free") }
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 duplicate" : "\(duplicates) duplicates") }
        if s.unlabeled > 0 { parts.append("\(s.unlabeled.formatted()) without a label") }
        return parts.isEmpty ? "No gaps" : parts.joined(separator: " · ")
    }

    /// Opens the item at the label typed (a bare number in either series, CDs first, as the search does), else Find
    /// by Label on that label, which says it's free and shows its neighbors.
    private func go() {
        guard let form = Sticker.parse(find), let sticker = Sticker(series: form.series ?? .cd, number: form.number) else { return }
        let items = form.series == nil ? model.collection.items(number: form.number) : model.collection.items(at: sticker)
        if let item = items.first {
            model.showItem(id: item.id)
        } else {
            model.findByLabel(sticker)
        }
        find = ""
    }
}

// MARK: How you own it

/// A bar per medium, split by digital state (digitized, partly, from another copy, waiting), plus the library
/// albums not in your collection.
struct HowYouOwnItCard: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats

    private struct Part: Identifiable {
        var id: String { name }
        var name: String
        var count: Int
        var color: Color
        var query: String
    }

    var body: some View {
        InsightCard(title: "How You Own It", subtitle: "Each medium, and how much of it is in your digital collection") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(stats.media) { share in
                    Button { model.showShelf(query: share.medium.query) } label: { mediumRow(share) }
                        .buttonStyle(.plain)
                        .help(share.medium.isPhysical ? "Show your \(share.medium.plural.lowercased()) on the Shelf" : "Show your downloads")
                }
                legend
                if stats.notInCollection > 0 {
                    Button { showNotInCollection() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "arrow.left.arrow.right").foregroundStyle(AppColor.neutral).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Not owned")
                                Text("Albums in your digital collection with no copy you own: borrowed, or not added yet").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(stats.notInCollection == 1 ? "1 album" : "\(stats.notInCollection.formatted()) albums").monospacedDigit()
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show these albums")
                }
            }
        }
    }

    private func parts(_ s: CollectionStats.MediumShare) -> [Part] {
        // Each segment opens exactly the items it counts.
        func part(_ name: String, _ p: CollectionStats.MediumShare.Part, _ color: Color) -> Part {
            Part(name: name, count: s.count(p), color: color, query: s.query(p))
        }
        return [
            part("Digitized", .digitized, AppColor.tier(.hiRes)),
            part("Partly", .partial, AppColor.tier(.cd)),
            part("From another copy", .otherCopy, AppColor.tier(.lossyHigh)),
            part("To digitize", .toDigitize, AppColor.neutral),
        ].filter { $0.count > 0 }
    }

    /// A segment's share of a bar `width` wide that holds `segments` of them 2 points apart, at least 3 points.
    private static func segmentWidth(_ count: Int, of total: Int, segments: Int, in width: CGFloat) -> CGFloat {
        let available = width - CGFloat(segments - 1) * 2
        return max(3, available * CGFloat(count) / CGFloat(total))
    }

    private func mediumRow(_ share: CollectionStats.MediumShare) -> some View {
        let segments = parts(share)
        let total = max(segments.reduce(0) { $0 + $1.count }, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: share.medium.symbol).foregroundStyle(AppColor.color(share.medium)).frame(width: 18)
                Text(share.medium.plural)
                Spacer(minLength: 8)
                Text(itemCount(share.items)).monospacedDigit()
                if share.spent > 0 { Text(formatMoney(share.spent, whole: true)).foregroundStyle(.secondary).monospacedDigit() }
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments) { p in
                        Rectangle().fill(p.color)
                            .frame(width: Self.segmentWidth(p.count, of: total, segments: segments.count, in: geo.size.width))
                            .help("\(p.name): \(itemCount(p.count))")
                            .onTapGesture { model.showShelf(query: p.query) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)
            .padding(.leading, 28)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([("Digitized", AppColor.tier(.hiRes)), ("Partly", AppColor.tier(.cd)), ("From another copy", AppColor.tier(.lossyHigh)),
                     ("To digitize", AppColor.neutral)], id: \.0) { name, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(name)
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.leading, 28)
    }

    /// The Albums page, showing the albums not in your collection.
    private func showNotInCollection() {
        UserDefaults.standard.set(AlbumsCollectionFilter.notInCollection.rawValue, forKey: "albumsCollectionFilter")
        model.sidebar = .albums
    }
}

// MARK: Spending over time

struct CollectionSpendingCard: View {
    let stats: CollectionStats
    enum Measure: String, CaseIterable { case spent = "Spent", items = "Items" }
    @State private var measure = Measure.spent
    @State private var hovered: CollectionStats.Period?

    var body: some View {
        InsightCard(title: "Spending Over Time", subtitle: subtitle) {
            Picker("", selection: $measure) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let h = hovered {
                        Text("\(label(h.start.date())) · \(formatMoney(h.spent)) on \(itemCount(h.items)) · \(formatMoney(h.cumulative)) in all")
                            .foregroundStyle(.primary)
                    } else {
                        Text(measure == .spent
                             ? "Items with a purchase date, by \(stats.granularity.rawValue), by medium; the line is the running total (right axis) · hover for details"
                             : "Items with a purchase date, by \(stats.granularity.rawValue) · hover for details").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).monospacedDigit()
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

    /// The running total is drawn over the bars on their scale: the highest total meets the tallest bar, and the
    /// right axis reads it back in money.
    private var totalScale: Double {
        let tallest = stats.timeline.map(\.spent.doubleValue).max() ?? 0
        let total = stats.timeline.last?.cumulative.doubleValue ?? 0
        return tallest > 0 && total > 0 ? tallest / total : 0
    }

    @ViewBuilder
    private var chart: some View {
        let media = self.media
        let scale = totalScale
        Chart {
            ForEach(stats.timeline) { p in
                let faded = hovered != nil && hovered != p
                switch measure {
                case .spent:
                    ForEach(media, id: \.self) { m in
                        BarMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Spent", (p.spentByMedium[m.rawValue] ?? 0).doubleValue))
                            .foregroundStyle(by: .value("Medium", m.plural))
                            .opacity(faded ? 0.35 : 1)
                    }
                    if scale > 0 {
                        LineMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Running total", p.cumulative.doubleValue * scale),
                                 series: .value("Line", "Running total"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(AppColor.accent)
                    }
                case .items:
                    BarMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Items", p.items))
                        .foregroundStyle(AppColor.series.opacity(faded ? 0.35 : 1))
                        .cornerRadius(2)
                }
            }
        }
        .chartForegroundStyleScale(domain: media.map(\.plural), range: media.map { AppColor.color($0) })
        .chartLegend(measure == .spent && media.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if measure == .items {
                        if let v = value.as(Int.self) { Text(v.formatted()) }
                    } else if let v = value.as(Double.self) {
                        Text(formatMoney(Decimal(v), whole: true))
                    }
                }
            }
            if measure == .spent, scale > 0, let total = stats.timeline.last?.cumulative.doubleValue {
                AxisMarks(position: .trailing, values: [0, total / 2, total].map { $0 * scale }) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatMoney(Decimal(v / scale), whole: true)).foregroundStyle(AppColor.accent)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase, let frame = proxy.plotFrame,
                              let date = proxy.value(atX: p.x - geo[frame].origin.x, as: Date.self) else { hovered = nil; return }
                        hovered = stats.timeline.last { $0.start.date() <= date } ?? stats.timeline.first
                    }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.timeline.first?.start { parts.append("Since \(label(first.date()))") }
        if let busiest = stats.timeline.max(by: { $0.spent < $1.spent }), busiest.spent > 0 {
            parts.append("biggest \(stats.granularity.rawValue): \(label(busiest.start.date())), \(formatMoney(busiest.spent))")
        }
        return parts.joined(separator: " · ")
    }

    private func label(_ d: Date) -> String {
        stats.granularity == .month ? d.formatted(.dateTime.month(.wide).year()) : d.formatted(.dateTime.year())
    }
}

// MARK: Lists

/// Shelves of items: recently added, waiting to be digitized, priciest, best value, still in the wrapper, needing
/// details, and by label (CDs or records; rows always name the series).
struct CollectionListsCard: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats
    enum ShelfList: String, CaseIterable {
        case recent = "Recently Added", toDigitize = "To Digitize", priciest = "Priciest", value = "Best Value"
        case wrapper = "Still in the Wrapper", details = "Needs Details", label = "By Label"
    }
    @State private var list = ShelfList.recent
    @State private var series = StickerSeries.cd
    @State private var expanded = false
    @State private var hovered: String?

    var body: some View {
        let available = ShelfList.allCases.filter { !rows($0).isEmpty || ($0 == .label && !stats.byLabel.isEmpty) }
        let current = available.contains(list) ? list : (available.first ?? .recent)
        let shown = rows(current)
        InsightCard(title: "Your Shelves, Sorted", subtitle: subtitle(current)) {
            HStack(spacing: 6) {
                if current == .label {
                    Picker("", selection: $series) { ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Picker("", selection: $list) { ForEach(available, id: \.self) { Text($0.rawValue) } }
                    .labelsHidden().fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if shown.isEmpty {
                    Text(current == .label ? "No \(series.name) labels yet." : "Nothing here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(shown.prefix(expanded ? 50 : 8)) { r in row(r, current) }
                if shown.count > 8 {
                    Button(expanded ? "Show less" : "Show all \(min(shown.count, 50))\(shown.count > 50 ? " of \(shown.count)" : "")") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .buttonStyle(.link).font(.caption).padding(.top, 4).padding(.leading, 6)
                }
            }
        }
        .onChange(of: list) { expanded = false }
        .onChange(of: series) { expanded = false }
    }

    private func rows(_ list: ShelfList) -> [CollectionStats.ItemRow] {
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

    private func subtitle(_ list: ShelfList) -> String {
        switch list {
        case .recent: "Newest first"
        case .toDigitize: "CDs and records with no digital copy, longest waiting first"
        case .priciest: "What you paid most for"
        case .value: "Lowest cost per play"
        case .wrapper: "In your digital collection, never played here"
        case .details: "Without a purchase date, a price or a label"
        case .label: "In the order of their labels"
        }
    }

    private func row(_ r: CollectionStats.ItemRow, _ list: ShelfList) -> some View {
        let item = r.item
        return Button { model.showItem(id: item.id) } label: {
            HStack(spacing: 10) {
                CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 38, revision: model.coverRevision,
                        title: item.album)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.album.isEmpty ? "Unknown Album" : item.album).lineLimit(1)
                    Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    primary(r, list)
                    if let s = secondary(r, list) { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                .lineLimit(1)
            }
            .font(.callout)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered == item.id ? AppColor.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .help("Open \(item.album)")
    }

    @ViewBuilder
    private func primary(_ r: CollectionStats.ItemRow, _ list: ShelfList) -> some View {
        let item = r.item
        switch list {
        case .label:
            if let s = item.sticker { StickerPill(sticker: s, size: 10) }
        case .value:
            Text(r.pricePerPlay.map { "\(formatMoney($0)) a play" } ?? "").monospacedDigit()
        case .details:
            Text(missing(item))
        case .toDigitize:
            DigitalStatusLabel(state: r.state, medium: item.medium)
        default:
            Text(item.price.map { formatMoney($0) } ?? "—").monospacedDigit()
        }
    }

    private func secondary(_ r: CollectionStats.ItemRow, _ list: ShelfList) -> String? {
        let item = r.item
        let label = item.sticker?.text ?? (item.medium.isPhysical ? item.medium.name : "Download")
        switch list {
        case .value: return "\(playCount(r.plays)) · \(item.price.map { formatMoney($0) } ?? "")"
        case .label: return [item.price.map { formatMoney($0) }, item.purchasedOn.map(dayLabel)].compactMap { $0 }.joined(separator: " · ")
        case .wrapper, .toDigitize: return [label, item.purchasedOn.map(dayLabel)].compactMap { $0 }.joined(separator: " · ")
        default: return [label, item.purchasedOn.map(dayLabel)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "No date or price", "No label".
    private func missing(_ item: CollectionItem) -> String {
        var parts: [String] = []
        if item.purchasedOn == nil { parts.append("date") }
        if item.price == nil { parts.append("price") }
        if item.medium.series != nil, item.stickerNumber == nil { parts.append("label") }
        guard let first = parts.first else { return "" }
        return "No " + (parts.count == 1 ? first : parts.dropLast().joined(separator: ", ") + " or " + parts.last!)
    }
}

// MARK: Breakdowns

struct CollectionArtistsCard: View {
    let stats: CollectionStats
    enum Measure: String, CaseIterable { case spent = "Spent", items = "Items" }
    @State private var measure: Measure?

    var body: some View {
        let m = measure ?? (stats.pricedCount > 0 ? .spent : .items)
        InsightCard(title: "Artists", subtitle: "By what you've spent on them, or items owned") {
            Picker("", selection: Binding(get: { m }, set: { measure = $0 })) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            RankedBars(items: CollectionBreakdownCard.ranked(stats.artists, by: m == .spent, key: "artist"), initialCount: 6).id(m)
        }
    }
}

/// Genres, decades or record labels of what you own, with what they cost.
struct CollectionBreakdownCard: View {
    let stats: CollectionStats
    enum Kind: String, CaseIterable { case genres = "Genres", decades = "Decades", labels = "Record Labels" }
    @State private var kind = Kind.genres

    var body: some View {
        let available = Kind.allCases.filter { !breakdowns($0).isEmpty }
        let current = available.contains(kind) ? kind : (available.first ?? .genres)
        InsightCard(title: current.rawValue, subtitle: subtitle(current)) {
            Picker("", selection: $kind) { ForEach(available, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            let list = breakdowns(current)
            RankedBars(items: Self.ranked(list, by: false, key: current == .decades ? "decade" : current == .labels ? "label" : "genre"),
                       initialCount: 6)
                .id(current)
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

    /// Rows that open the Shelf filtered by `key` (`artist:`, `genre:`, `decade:`, `label:`).
    static func ranked(_ list: [CollectionStats.Breakdown], by spent: Bool, key: String) -> [RankedItem] {
        let sorted = spent ? list : (key == "decade" ? list : list.sorted { $0.items != $1.items ? $0.items > $1.items : $0.spent > $1.spent })
        return sorted.map { b in
            RankedItem(name: b.name, value: spent ? b.spent.doubleValue : Double(b.items),
                       detail: spent ? formatMoney(b.spent) : itemCount(b.items) + (b.spent > 0 ? " · \(formatMoney(b.spent, whole: true))" : ""),
                       subtitle: spent ? itemCount(b.items) : nil,
                       shelfQuery: key == "decade" ? "decade:\(b.name)" : SearchFilterKey.token(key, b.name))
        }
    }
}

// MARK: Facts

struct CollectionFactsCard: View {
    let stats: CollectionStats

    var body: some View {
        let facts = facts
        if !facts.isEmpty { InsightCard(title: "Fun Facts") { FactsGrid(facts: facts) } }
    }

    private func line(_ item: CollectionItem) -> String {
        [item.sticker?.text, item.album, item.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "8 of 12 albums" when only some have a known length, else "12 albums".
    private var runtimeAlbumsText: String {
        func albums(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }
        let n = stats.runtimeAlbums, total = stats.albumsOwned
        return n < total ? "\(n.formatted()) of \(albums(total))" : albums(total)
    }

    private var facts: [FunFact] {
        var out: [FunFact] = []
        if let item = stats.oldestRelease, let y = item.year {
            out.append(FunFact(icon: "clock.arrow.circlepath", title: "Oldest release you own", value: String(y), detail: line(item), itemID: item.id))
        }
        if let item = stats.newestAddition {
            out.append(FunFact(icon: "sparkles", title: "Newest addition", value: item.createdAt.formatted(.relative(presentation: .named)),
                               detail: line(item), itemID: item.id))
        }
        if let most = stats.mostCopies {
            out.append(FunFact(icon: "square.on.square", title: "Most copies of one album", value: "\(most.copies) copies",
                               detail: "\(most.item.album) — \(most.item.artist)",
                               shelfQuery: SearchFilterKey.token("album", most.item.album) + " copies:>1"))
        }
        if let box = stats.biggestBox, let discs = box.discCount {
            out.append(FunFact(icon: "shippingbox", title: "Biggest box", value: "\(discs) discs", detail: line(box), itemID: box.id))
        }
        if let r = stats.priciest, let p = r.item.price {
            out.append(FunFact(icon: "crown", title: "Priciest", value: formatMoney(p), detail: line(r.item), itemID: r.item.id))
        }
        if let r = stats.cheapest, let p = r.item.price {
            out.append(FunFact(icon: "tag", title: p == 0 ? "Got it for free" : "Best bargain", value: formatMoney(p), detail: line(r.item),
                               itemID: r.item.id))
        }
        if stats.runtime > 0 {
            out.append(FunFact(icon: "infinity", title: "Everything you own, back to back", value: formatLongDuration(stats.runtime),
                               detail: "across \(runtimeAlbumsText) you own"))
        }
        if stats.waitingForTurntable > 0 {
            out.append(FunFact(icon: "record.circle", title: "Waiting for a turntable", value: stats.waitingForTurntable.formatted(),
                               detail: "record\(stats.waitingForTurntable == 1 ? "" : "s") not digitized yet",
                               shelfQuery: "own:vinyl ripped:no"))
        }
        if !stats.stillInWrapper.isEmpty {
            out.append(FunFact(icon: "gift", title: "Still in the wrapper", value: stats.stillInWrapper.count.formatted(),
                               detail: "item\(stats.stillInWrapper.count == 1 ? "" : "s") in your digital collection you haven't played here yet"))
        }
        if !stats.needsDetails.isEmpty {
            out.append(FunFact(icon: "pencil", title: "Needs details", value: stats.needsDetails.count.formatted(),
                               detail: "item\(stats.needsDetails.count == 1 ? " is" : "s are") missing a date, a price or a label"))
        }
        return out
    }
}
