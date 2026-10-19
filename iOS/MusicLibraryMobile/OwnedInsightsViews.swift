import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Collection pane of Insights (saved as "Owned"): everything you own (CDs, records, downloads, ripped or not),
/// how much of it is digitized, your label series, what it cost and what it's been worth. A port of the Mac's pane;
/// rows open items, and drill-downs open the collection, never a song search.
struct CollectionInsightsPane: View {
    let stats: CollectionStats

    var body: some View {
        if stats.itemCount == 0 {
            ContentUnavailableView("Nothing in Your Collection Yet", systemImage: "books.vertical",
                                   description: Text("Add the CDs, records and downloads you own in Music Library on your Mac, with when you bought them and what you paid, and this page fills in."))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                CollectionInsightTiles(stats: stats)
                if stats.series.contains(where: { $0.labeled + $0.unlabeled > 0 }) { CollectionShelvesCard(stats: stats) }
                CollectionMediaCard(stats: stats)
                if !stats.timeline.isEmpty { CollectionSpendingCard(stats: stats) }
                CollectionListsCard(stats: stats)
                if !stats.artists.isEmpty {
                    CollectionBreakdownCard(title: "Artists", subtitle: "By items you own, and what you spent", items: stats.artists) {
                        SearchFilterKey.token("artist", $0.name)
                    }
                }
                if !stats.genres.isEmpty {
                    CollectionBreakdownCard(title: "Genres", subtitle: "Items can carry several", items: stats.genres) {
                        SearchFilterKey.token("genre", $0.name)
                    }
                }
                if !stats.decades.isEmpty {
                    CollectionBreakdownCard(title: "Release Eras", subtitle: "When the music you own came out", items: stats.decades,
                                            sortByCount: false) { "decade:\($0.name)" }
                }
                if !stats.recordLabels.isEmpty {
                    CollectionBreakdownCard(title: "Record Labels", subtitle: "Who released what you own", items: stats.recordLabels) {
                        SearchFilterKey.token("label", $0.name)
                    }
                }
                CollectionFactsCard(stats: stats)
            }
        }
    }
}

/// Labels and counts for the Collection pane.
enum InsightCollection {
    static func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }
    static func albumCount(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }
    /// "8 of 12 albums" when only some of them count, else "12 albums".
    static func albumCount(_ n: Int, of total: Int) -> String {
        n < total ? "\(n.formatted()) of \(albumCount(total))" : albumCount(total)
    }
    static func dayLabel(_ d: PurchaseDay) -> String { d.date().formatted(date: .abbreviated, time: .omitted) }

    static func mediumName(_ m: CollectionMedium, count: Int) -> String {
        switch m {
        case .cd: count == 1 ? "CD" : "CDs"
        case .vinyl: count == 1 ? "Record" : "Records"
        case .download: count == 1 ? "Download" : "Downloads"
        case .other(let raw): raw.capitalized
        }
    }

    static func icon(_ m: CollectionMedium) -> String {
        switch m {
        case .cd: "opticaldisc"
        case .vinyl: "record.circle"
        case .download: "arrow.down.circle"
        case .other: "shippingbox"
        }
    }

    /// The pane's color per medium (the chart series, then lighter shades of it).
    static func color(_ m: CollectionMedium) -> Color {
        switch m {
        case .cd: InsightColor.series
        case .vinyl: InsightColor.dynamic(light: 0x104281, dark: 0xcde2fb)
        case .download: InsightColor.dynamic(light: 0x86b6ef, dark: 0x1c5cab)
        case .other: InsightColor.neutral
        }
    }
}

// MARK: Tiles

struct CollectionInsightTiles: View {
    let stats: CollectionStats

    var body: some View {
        let hasPrices = stats.pricedCount > 0
        let year = Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))
        InsightTileGrid {
            InsightTile(value: stats.itemCount.formatted(), label: stats.itemCount == 1 ? "Item" : "Items", icon: "books.vertical",
                        detail: "\(InsightCollection.albumCount(stats.albumsOwned)) · \(stats.notInCollection.formatted()) in the library you don't own")
            DigitizedTile(stats: stats)
            NavigationLink(value: CollectionRoute.scope(.toDigitize)) {
                InsightTile(value: stats.toDigitizeCount.formatted(), label: "To digitize", icon: "waveform.slash",
                            detail: toDigitizeDetail)
            }
            .buttonStyle(.plain)
            InsightTile(value: hasPrices ? formatMoney(stats.totalSpent) : "—", label: "Spent", icon: "creditcard",
                        detail: hasPrices ? "on \(stats.pricedCount.formatted()) of \(InsightCollection.itemCount(stats.itemCount))" : "add prices on the Mac")
            InsightTile(value: formatMoney(stats.spentThisYear), label: "This year", icon: "calendar",
                        detail: "\(InsightCollection.itemCount(stats.boughtThisYear)) bought in \(year)")
            InsightTile(value: stats.costPerPlay.map { formatMoney($0) } ?? "—", label: "Per play", icon: "play.circle",
                        detail: stats.costPerHour.map { "\(formatMoney($0)) an hour listened" })
        }
    }

    private var toDigitizeDetail: String {
        var parts: [String] = []
        if stats.toRipCount > 0 { parts.append("\(stats.toRipCount) CD\(stats.toRipCount == 1 ? "" : "s") to rip") }
        if stats.vinylToDigitizeCount > 0 { parts.append("\(stats.vinylToDigitizeCount) record\(stats.vinylToDigitizeCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Everything's digitized" : parts.joined(separator: " · ")
    }
}

/// The share of CDs and records with a digital copy, as a ring.
private struct DigitizedTile: View {
    let stats: CollectionStats

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Circle().stroke(InsightColor.track, lineWidth: 4)
                Circle().trim(from: 0, to: stats.digitizedShare)
                    .stroke(InsightColor.series, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            Text(stats.digitizedShare.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1)
            Text("Digitized").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("of \(stats.physicalCount.formatted()) CDs and records").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shelves

/// Each label series: the numbers used, the next one, free numbers and duplicates; opens Label Check. A find field
/// shows what has a label as it's typed ("142" in both series, "v12" in one).
struct CollectionShelvesCard: View {
    @Environment(PhoneModel.self) private var model
    let stats: CollectionStats
    @State private var find = ""

    var body: some View {
        InsightCard(title: "Your Shelves", subtitle: "CDs and records are numbered apart") {
            VStack(spacing: 0) {
                let shown = stats.series.filter { $0.labeled + $0.unlabeled > 0 }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider() }
                    NavigationLink(value: CollectionRoute.labelCheck(s.series)) { row(s) }
                        .buttonStyle(.plain)
                }
                Divider()
                findField
            }
        }
    }

    private var findField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "number").foregroundStyle(.secondary)
                TextField("Find a label, like 142 or v12", text: $find)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                if !find.isEmpty {
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
            if let parsed = Sticker.parse(find) { results(parsed) }
        }
        .padding(.top, 10)
    }

    /// The items with the label typed, in either series when it didn't say which.
    @ViewBuilder
    private func results(_ parsed: (series: StickerSeries?, number: Int)) -> some View {
        let c = model.collection
        let stickers = (parsed.series.map { [$0] } ?? StickerSeries.allCases).compactMap { Sticker(series: $0, number: parsed.number) }
        let hits = stickers.flatMap { c.items(at: $0) }
        if hits.isEmpty {
            Text(stickers.count == 1 ? "\(stickers[0].text) is free" : "No CD or record has #\(parsed.number)")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(hits) { item in
                NavigationLink(value: CollectionItemRoute(id: item.id)) {
                    HStack(spacing: 10) {
                        if let sticker = item.sticker { StickerPill(sticker: sticker, size: 11) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.subheadline).lineLimit(1)
                            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        InsightChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ s: CollectionStats.SeriesStats) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: s.series == .cd ? "opticaldisc" : "record.circle").foregroundStyle(InsightColor.series).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.series == .cd ? "CDs" : "Vinyl").font(.subheadline.weight(.semibold))
                    if let high = s.highest { Text("#1–#\(high)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(details(s)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let next = Sticker(series: s.series, number: s.next) { StickerPill(sticker: next, size: 11) }
                Text("next").font(.caption2).foregroundStyle(.secondary)
            }
            InsightChevron()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func details(_ s: CollectionStats.SeriesStats) -> String {
        var parts = ["\(s.labeled.formatted()) labeled"]
        if s.unlabeled > 0 { parts.append("\(s.unlabeled) without a label") }
        if s.gapCount > 0 { parts.append("\(s.gapCount) free number\(s.gapCount == 1 ? "" : "s")") }
        if !s.duplicates.isEmpty { parts.append("\(s.duplicates.count) duplicate\(s.duplicates.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: How you own it

/// A bar per medium split by digital state (digitized, partly, from another copy, to digitize), and the library albums
/// that aren't yours.
struct CollectionMediaCard: View {
    let stats: CollectionStats

    var body: some View {
        InsightCard(title: "How You Own It", subtitle: "Each medium by whether it's in your library, and the albums you have that aren't yours") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(stats.media) { share in
                    NavigationLink(value: CollectionRoute.query(SearchFilterKey.token("own", share.medium.rawValue),
                                                                title: InsightCollection.mediumName(share.medium, count: 2))) {
                        mediumRow(share)
                    }
                    .buttonStyle(.plain)
                }
                if stats.notInCollection > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Not in your collection")
                            Text("Library albums you don't own a copy of: borrowed, or from elsewhere").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(InsightCollection.albumCount(stats.notInCollection)).monospacedDigit()
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
                legend
            }
        }
    }

    private func mediumRow(_ s: CollectionStats.MediumShare) -> some View {
        let parts: [(value: Int, color: Color)] = [
            (s.digitized, InsightColor.series), (s.partial, InsightColor.series.opacity(0.6)),
            (s.otherCopy, InsightColor.series.opacity(0.35)), (s.toDigitize, InsightColor.neutral),
        ]
        let total = max(s.items, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: InsightCollection.icon(s.medium)).foregroundStyle(InsightColor.series).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(InsightCollection.mediumName(s.medium, count: s.items))
                    if let detail = detail(s) { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Text(InsightCollection.itemCount(s.items)).monospacedDigit()
                InsightChevron()
            }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        if p.value > 0 {
                            Rectangle().fill(p.color)
                                .frame(width: max(3, (geo.size.width - 6) * CGFloat(p.value) / CGFloat(total)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func detail(_ s: CollectionStats.MediumShare) -> String? {
        var bits: [String] = []
        let digital = s.digitized + s.partial + s.otherCopy
        if s.medium.isPhysical {
            bits.append(s.toDigitize == 0 ? "all digitized" : "\(digital) digitized · \(s.toDigitize) to go")
        } else if s.partial > 0 {
            bits.append("\(s.partial) only partly")
        }
        if s.spent > 0 { bits.append("\(formatMoney(s.spent, whole: true)) spent") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([("Digitized", InsightColor.series), ("Partly", InsightColor.series.opacity(0.6)),
                     ("Other copy", InsightColor.series.opacity(0.35)), ("To digitize", InsightColor.neutral)], id: \.0) { name, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    Text(name)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: Spending over time

struct CollectionSpendingCard: View {
    let stats: CollectionStats
    enum Measure: String, CaseIterable { case spent = "Spent", items = "Items", total = "Running Total" }
    @State private var measure = Measure.spent
    @State private var selected: CollectionStats.Period?

    var body: some View {
        InsightCard(title: "Spending Over Time", subtitle: subtitle) {
            InsightSegments(selection: $measure)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                InsightReadout(text: selected.map { "\(label($0.start)) · \(formatMoney($0.spent)) on \(InsightCollection.itemCount($0.items)) · \(formatMoney($0.cumulative)) in all" },
                               hint: "Items with a purchase date, by \(stats.granularity.rawValue) · drag for details")
                chart.frame(height: 190)
            }
        }
    }

    private var unit: Calendar.Component { stats.granularity == .month ? .month : .year }

    /// Media in the order they stack, with what each spent in each period.
    private var media: [CollectionMedium] { stats.media.map(\.medium) }

    private var chart: some View {
        Chart {
            ForEach(stats.timeline) { p in
                switch measure {
                case .spent:
                    ForEach(media, id: \.rawValue) { m in
                        BarMark(x: .value("Period", p.start.date(), unit: unit),
                                y: .value("Spent", (p.spentByMedium[m.rawValue] ?? 0).doubleValue))
                            .foregroundStyle(by: .value("Medium", InsightCollection.mediumName(m, count: 2)))
                            .opacity(selected == nil || selected == p ? 1 : 0.35)
                    }
                case .items:
                    BarMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Items", p.items))
                        .foregroundStyle(InsightColor.series.opacity(selected == nil || selected == p ? 1 : 0.35))
                        .cornerRadius(2)
                case .total:
                    AreaMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [InsightColor.series.opacity(0.28), InsightColor.series.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Period", p.start.date(), unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(InsightColor.series)
                }
            }
            if measure == .total, let h = selected {
                RuleMark(x: .value("Period", h.start.date(), unit: unit)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartForegroundStyleScale(domain: media.map { InsightCollection.mediumName($0, count: 2) },
                                   range: media.map(InsightCollection.color))
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
        }
        .insightScrub { proxy, x in
            guard let date = proxy.value(atX: x, as: Date.self) else { return }
            selected = stats.timeline.last { $0.start.date() <= date } ?? stats.timeline.first
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.timeline.first?.start { parts.append("Since \(label(first))") }
        if let b = stats.timeline.max(by: { $0.spent < $1.spent }), b.spent > 0 {
            parts.append("biggest \(stats.granularity.rawValue): \(label(b.start)), \(formatMoney(b.spent))")
        }
        return parts.joined(separator: " · ")
    }

    private func label(_ d: PurchaseDay) -> String {
        stats.granularity == .month ? d.date().formatted(.dateTime.month(.wide).year()) : d.date().formatted(.dateTime.year())
    }
}

// MARK: Lists

/// Shelves of items: recently added, to digitize, priciest, best value, still in the wrapper, needing details, and by
/// label (CDs or records). Rows open the item.
struct CollectionListsCard: View {
    @Environment(PhoneModel.self) private var model
    let stats: CollectionStats
    enum Shelf: String, CaseIterable {
        case recent = "Recently Added", toDigitize = "To Digitize", priciest = "Priciest", value = "Best Value"
        case wrapper = "Still in the Wrapper", details = "Needs Details", label = "By Label"
    }
    @State private var list = Shelf.recent
    @State private var series = StickerSeries.cd
    @State private var expanded = false

    var body: some View {
        let available = Shelf.allCases.filter { !rows($0).isEmpty || ($0 == .label && !stats.byLabel.isEmpty) }
        let current = available.contains(list) ? list : (available.first ?? .recent)
        let shown = rows(current)
        InsightCard(title: "Your Shelves, Sorted", subtitle: subtitle(current)) {
            HStack {
                Picker("List", selection: Binding(get: { current }, set: { list = $0 })) {
                    ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                if current == .label {
                    Picker("Series", selection: $series) {
                        ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if shown.isEmpty {
                    Text("Nothing here.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(shown.prefix(expanded ? 50 : 8)) { r in
                    NavigationLink(value: CollectionItemRoute(id: r.item.id)) { row(r, current) }
                        .buttonStyle(.plain)
                }
                if shown.count > 8 {
                    Button(expanded ? "Show Less" : "Show All \(min(shown.count, 50))\(shown.count > 50 ? " of \(shown.count)" : "")") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.top, 6)
                }
            }
        }
        .onChange(of: list) { expanded = false }
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
        case .wrapper: "In your library, never played"
        case .details: "Missing a purchase date, a price or a label"
        case .label: "In label order"
        }
    }

    private func row(_ r: CollectionStats.ItemRow, _ list: Shelf) -> some View {
        let item = r.item
        return HStack(spacing: 10) {
            CoverImage(url: model.library?.coverURL(item: item), size: 40, title: nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.album).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let sticker = item.sticker, list == .label || list == .toDigitize || list == .details {
                    StickerPill(sticker: sticker, size: 10)
                } else {
                    Text(primary(r, list)).monospacedDigit()
                }
                if let s = secondary(r, list) { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .lineLimit(1)
            .layoutPriority(1)
            InsightChevron()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func primary(_ r: CollectionStats.ItemRow, _ list: Shelf) -> String {
        let item = r.item
        switch list {
        case .value: return r.pricePerPlay.map { "\(formatMoney($0)) a play" } ?? ""
        case .details:
            var missing: [String] = []
            if item.purchasedOn == nil { missing.append("date") }
            if item.price == nil { missing.append("price") }
            if item.medium.series != nil && item.stickerNumber == nil { missing.append("label") }
            return missing.isEmpty ? "" : "No " + ListFormatter.localizedString(byJoining: missing)
        default:
            return item.price.map { formatMoney($0) } ?? item.sticker?.text ?? item.medium.name
        }
    }

    private func secondary(_ r: CollectionStats.ItemRow, _ list: Shelf) -> String? {
        let item = r.item
        switch list {
        case .value: return "\(playCount(r.plays)) · \(item.price.map { formatMoney($0) } ?? "")"
        case .details: return nil
        default:
            let parts = [item.sticker == nil || list == .label ? nil : item.sticker?.text, item.purchasedOn.map(InsightCollection.dayLabel)]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

// MARK: Breakdowns

/// Items by artist, genre, decade or record label, with what they cost; rows open those items.
struct CollectionBreakdownCard: View {
    let title: String
    let subtitle: String
    let items: [CollectionStats.Breakdown]
    var sortByCount = true
    let query: (CollectionStats.Breakdown) -> String

    var body: some View {
        let sorted = sortByCount ? items.sorted { $0.items != $1.items ? $0.items > $1.items : $0.spent > $1.spent } : items
        let top = max(sorted.map(\.items).max() ?? 1, 1)
        InsightCard(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sorted.prefix(8)) { b in
                    NavigationLink(value: CollectionRoute.query(query(b), title: b.name)) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(b.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(InsightCollection.itemCount(b.items) + (b.spent > 0 ? " · \(formatMoney(b.spent, whole: true))" : ""))
                                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                                InsightChevron()
                            }
                            InsightBar(fraction: Double(b.items) / Double(top))
                        }
                        .font(.subheadline)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Facts

struct CollectionFactsCard: View {
    let stats: CollectionStats

    /// In days for the last two weeks ("9 days ago": the named relative style counts calendar weeks and says "2 weeks
    /// ago"), then relative.
    static func whenAdded(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        default: return date.formatted(.relative(presentation: .named))
        }
    }

    var body: some View {
        let facts = facts
        if !facts.isEmpty { InsightFactsCard(facts: facts) }
    }

    private var facts: [InsightFact] {
        var out: [InsightFact] = []
        func describe(_ item: CollectionItem) -> String {
            [item.sticker?.text, "\(item.album) — \(item.artist)"].compactMap { $0 }.joined(separator: " · ")
        }
        if let item = stats.oldestRelease, let year = item.year {
            out.append(InsightFact(icon: "clock.arrow.circlepath", title: "Oldest release", value: String(year), detail: describe(item), itemID: item.id))
        }
        if let item = stats.newestAddition {
            let when = Self.whenAdded(item.purchasedOn?.date() ?? item.createdAt)
            out.append(InsightFact(icon: "sparkles", title: "Newest addition", value: when, detail: describe(item), itemID: item.id))
        }
        if let most = stats.mostCopies {
            out.append(InsightFact(icon: "square.on.square", title: "Most copies", value: "\(most.copies) copies",
                                   detail: "\(most.item.album) — \(most.item.artist)", itemID: most.item.id))
        }
        if let box = stats.biggestBox, let discs = box.discCount {
            out.append(InsightFact(icon: "shippingbox", title: "Biggest box", value: "\(discs) discs", detail: describe(box), itemID: box.id))
        }
        if let priciest = stats.priciest, let price = priciest.item.price {
            out.append(InsightFact(icon: "crown", title: "Priciest", value: formatMoney(price), detail: describe(priciest.item), itemID: priciest.item.id))
        }
        if let cheapest = stats.cheapest, let price = cheapest.item.price {
            out.append(InsightFact(icon: "tag", title: price == 0 ? "Got it for free" : "Best bargain", value: formatMoney(price),
                                   detail: describe(cheapest.item), itemID: cheapest.item.id))
        }
        if stats.waitingForTurntable > 0 {
            out.append(InsightFact(icon: "record.circle", title: "Waiting for a turntable", value: stats.waitingForTurntable.formatted(),
                                   detail: "record\(stats.waitingForTurntable == 1 ? "" : "s") with no digital copy yet"))
        }
        if !stats.stillInWrapper.isEmpty {
            out.append(InsightFact(icon: "gift", title: "Still in the wrapper", value: stats.stillInWrapper.count.formatted(),
                                   detail: "item\(stats.stillInWrapper.count == 1 ? "" : "s") in your library you haven't played yet"))
        }
        if stats.runtime > 0 {
            out.append(InsightFact(icon: "infinity", title: "Your collection, back to back", value: formatLongDuration(stats.runtime),
                                   detail: "across \(InsightCollection.albumCount(stats.runtimeAlbums, of: stats.albumsOwned))"))
        }
        if !stats.needsDetails.isEmpty {
            out.append(InsightFact(icon: "pencil", title: "Needs details", value: stats.needsDetails.count.formatted(),
                                   detail: "item\(stats.needsDetails.count == 1 ? " is" : "s are") missing a date, price or label"))
        }
        return out
    }
}
