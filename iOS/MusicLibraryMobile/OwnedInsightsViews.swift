import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Owned pane of Insights: the albums you own, what you paid for them and how much you play them.
struct OwnedInsightsPane: View {
    let stats: OwnershipStats

    var body: some View {
        if stats.ownedCount == 0 {
            ContentUnavailableView("No Owned Albums Yet", systemImage: "bag",
                                   description: Text("Open an album and switch on “I own this album” under Your Copy, or answer “Do you own this CD?” when you rip one on the Mac. Add when you bought it and what you paid, and this page fills in."))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                InsightsOwnedTiles(stats: stats)
                InsightsOwnedFormatsCard(stats: stats)
                if !stats.timeline.isEmpty { InsightsSpendingCard(stats: stats) }
                InsightsOwnedAlbumsCard(stats: stats)
                InsightsOwnedArtistsCard(stats: stats)
                if !stats.genres.isEmpty {
                    InsightsOwnedBreakdownCard(title: "Genres", subtitle: "Albums can carry several", items: stats.genres) { SearchFilterKey.token("genre", $0.name) }
                }
                if !stats.decades.isEmpty {
                    InsightsOwnedBreakdownCard(title: "Release Eras", subtitle: "When the music you own came out", items: stats.decades, sortByCount: false) { "decade:\($0.name)" }
                }
                InsightsOwnedFactsCard(stats: stats)
            }
        }
    }
}

/// Searches and labels for owned albums.
enum InsightOwned {
    static func albumQuery(_ a: OwnershipStats.OwnedAlbum) -> String {
        SearchFilterKey.token("album", a.album) + " " + SearchFilterKey.token("albumartist", a.artist)
    }

    static func albumCount(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }

    static func dayLabel(_ d: PurchaseDay) -> String { d.date().formatted(date: .abbreviated, time: .omitted) }
}

// MARK: Tiles

struct InsightsOwnedTiles: View {
    let stats: OwnershipStats

    var body: some View {
        let hasPrices = stats.pricedCount > 0
        InsightTileGrid {
            InsightTile(value: stats.ownedCount.formatted(), label: stats.ownedCount == 1 ? "Album owned" : "Albums owned", icon: "bag",
                        detail: "\(stats.ownedFraction.formatted(.percent.precision(.fractionLength(0)))) of your \(InsightOwned.albumCount(stats.libraryAlbumCount))")
            InsightTile(value: hasPrices ? formatMoney(stats.totalSpent) : "—", label: "Spent", icon: "creditcard",
                        detail: hasPrices ? "on \(stats.pricedCount.formatted()) of \(InsightOwned.albumCount(stats.ownedCount))" : "add prices on album pages")
            InsightTile(value: stats.averagePrice.map { formatMoney($0) } ?? "—", label: "Average price", icon: "tag",
                        detail: stats.medianPrice.map { "median \(formatMoney($0))" })
            InsightTile(value: formatMoney(stats.spentThisYear), label: "Spent this year", icon: "calendar",
                        detail: "\(InsightOwned.albumCount(stats.boughtThisYear)) bought in \(Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never)))")
            InsightTile(value: stats.costPerHour.map { formatMoney($0) } ?? "—", label: "Per hour of music", icon: "clock",
                        detail: stats.pricedDuration > 0 ? "\(formatLongDuration(stats.pricedDuration)) paid for" : nil)
            InsightTile(value: stats.costPerPlay.map { formatMoney($0) } ?? "—", label: "Per play", icon: "play.circle",
                        detail: hasPrices ? "\(playCount(stats.pricedPlays)) of albums you paid for" : nil)
        }
    }
}

// MARK: Spending over time

struct InsightsSpendingCard: View {
    let stats: OwnershipStats
    enum Measure: String, CaseIterable { case spent = "Spent", albums = "Albums", total = "Running Total" }
    @State private var measure = Measure.spent
    @State private var selected: OwnershipStats.Period?

    var body: some View {
        InsightCard(title: "Spending Over Time", subtitle: subtitle) {
            InsightSegments(selection: $measure)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                InsightReadout(text: selected.map { "\(label($0.start)) · \(formatMoney($0.spent)) on \(InsightOwned.albumCount($0.albums)) · \(formatMoney($0.cumulative)) in all" },
                               hint: "Albums with a purchase date, by \(stats.granularity.rawValue) · drag for details")
                chart.frame(height: 190)
            }
        }
    }

    private var unit: Calendar.Component { stats.granularity == .month ? .month : .year }

    private var chart: some View {
        Chart {
            ForEach(stats.timeline) { p in
                switch measure {
                case .spent:
                    BarMark(x: .value("Period", p.start, unit: unit), y: .value("Spent", p.spent.doubleValue))
                        .foregroundStyle(InsightColor.series.opacity(selected == nil || selected == p ? 1 : 0.35))
                        .cornerRadius(2)
                case .albums:
                    BarMark(x: .value("Period", p.start, unit: unit), y: .value("Albums", p.albums))
                        .foregroundStyle(InsightColor.series.opacity(selected == nil || selected == p ? 1 : 0.35))
                        .cornerRadius(2)
                case .total:
                    AreaMark(x: .value("Period", p.start, unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [InsightColor.series.opacity(0.28), InsightColor.series.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Period", p.start, unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(InsightColor.series)
                }
            }
            if measure == .total, let h = selected {
                RuleMark(x: .value("Period", h.start, unit: unit)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if measure == .albums {
                        if let v = value.as(Int.self) { Text(v.formatted()) }
                    } else if let v = value.as(Double.self) {
                        Text(formatMoney(Decimal(v), whole: true))
                    }
                }
            }
        }
        .insightScrub { proxy, x in
            guard let date = proxy.value(atX: x, as: Date.self) else { return }
            selected = stats.timeline.last { $0.start <= date } ?? stats.timeline.first
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let first = stats.timeline.first?.start { parts.append("Since \(label(first))") }
        if let b = stats.busiestPeriod, b.spent > 0 { parts.append("biggest \(stats.granularity.rawValue): \(label(b.start)), \(formatMoney(b.spent))") }
        return parts.joined(separator: " · ")
    }

    private func label(_ d: Date) -> String {
        stats.granularity == .month ? d.formatted(.dateTime.month(.wide).year()) : d.formatted(.dateTime.year())
    }
}

// MARK: Album lists

struct InsightsOwnedAlbumsCard: View {
    @Environment(PhoneModel.self) private var model
    let stats: OwnershipStats
    enum Shelf: String, CaseIterable { case recent = "Recent", priciest = "Priciest", value = "Best Value", unplayed = "Unplayed", missing = "Needs Details" }
    @State private var list = Shelf.recent
    @State private var expanded = false
    /// Library albums by `SearchIndex.albumKey`, to open them.
    @State private var albumsByKey: [String: AlbumSummary] = [:]

    var body: some View {
        let available = Shelf.allCases.filter { !albums($0).isEmpty }
        let current = available.contains(list) ? list : (available.first ?? .recent)
        let rows = albums(current)
        InsightCard(title: "Your Albums", subtitle: subtitle(current)) {
            Picker("List", selection: Binding(get: { current }, set: { list = $0 })) {
                ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows.prefix(expanded ? 50 : 8)) { a in row(a, current) }
                if rows.count > 8 {
                    Button(expanded ? "Show Less" : "Show All \(min(rows.count, 50))\(rows.count > 50 ? " of \(rows.count)" : "")") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.top, 6)
                }
            }
        }
        .onChange(of: list) { expanded = false }
        .task(id: model.libraryVersion) {
            guard let library = model.library else { albumsByKey = [:]; return }
            albumsByKey = Dictionary(library.albums.map { (SearchIndex.albumKey(album: $0.album, artist: $0.artist), $0) },
                                     uniquingKeysWith: { first, _ in first })
        }
    }

    private func albums(_ list: Shelf) -> [OwnershipStats.OwnedAlbum] {
        switch list {
        case .recent: stats.albums
        case .priciest: stats.albums.filter { $0.price != nil }.sorted { ($0.price ?? 0) > ($1.price ?? 0) }
        case .value: stats.bestValue
        case .unplayed: stats.unplayed
        case .missing: stats.missingDetails
        }
    }

    private func subtitle(_ list: Shelf) -> String {
        switch list {
        case .recent: "Newest purchases first"
        case .priciest: "What you paid most for"
        case .value: "Lowest cost per play"
        case .unplayed: "Owned but never played"
        case .missing: "Owned, without a purchase date or price"
        }
    }

    @ViewBuilder
    private func row(_ a: OwnershipStats.OwnedAlbum, _ list: Shelf) -> some View {
        if let summary = albumsByKey[a.id] {
            NavigationLink(value: summary) { rowLabel(a, list, cover: model.library?.coverURL(album: summary), link: true) }
                .buttonStyle(.plain)
        } else {
            rowLabel(a, list, cover: nil, link: false)
        }
    }

    private func rowLabel(_ a: OwnershipStats.OwnedAlbum, _ list: Shelf, cover: URL?, link: Bool) -> some View {
        HStack(spacing: 10) {
            CoverImage(url: cover, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.album).lineLimit(1)
                Text(a.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(primary(a, list)).monospacedDigit()
                if let s = secondary(a, list) { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .lineLimit(1)
            .layoutPriority(1)
            if link { InsightChevron() }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func primary(_ a: OwnershipStats.OwnedAlbum, _ list: Shelf) -> String {
        switch list {
        case .value: a.pricePerPlay.map { "\(formatMoney($0)) a play" } ?? ""
        case .missing:
            a.purchasedOn == nil && a.price == nil ? "No date or price" : (a.purchasedOn == nil ? "No date" : "No price")
        default: a.price.map { formatMoney($0) } ?? "—"
        }
    }

    private func secondary(_ a: OwnershipStats.OwnedAlbum, _ list: Shelf) -> String? {
        switch list {
        case .value: return "\(playCount(a.plays)) · \(a.price.map { formatMoney($0) } ?? "")"
        case .missing: return nil
        default:
            let parts = [a.format == .digital ? "Download" : nil, a.purchasedOn.map(InsightOwned.dayLabel)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

// MARK: Breakdowns

/// How you own your music: CDs, downloads, and the albums you borrowed, as a bar of the whole library and a row each.
struct InsightsOwnedFormatsCard: View {
    let stats: OwnershipStats

    private struct Part: Identifiable {
        var id: String { name }
        var name: String
        var icon: String
        var albums: Int
        var color: Color
        var detail: String
    }

    var body: some View {
        let parts = parts
        let total = max(parts.reduce(0) { $0 + $1.albums }, 1)
        InsightCard(title: "How You Own It", subtitle: "CDs, downloads and borrowed albums, of your \(InsightOwned.albumCount(stats.libraryAlbumCount))") {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts) { p in
                            Rectangle().fill(p.color)
                                .frame(width: max(3, (geo.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(p.albums) / CGFloat(total)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                ForEach(parts) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: p.icon).foregroundStyle(p.color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            if !p.detail.isEmpty { Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(InsightOwned.albumCount(p.albums)).monospacedDigit()
                            Text((Double(p.albums) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var parts: [Part] {
        var out: [Part] = []
        for f in stats.formats {
            var bits: [String] = []
            if f.spent > 0 { bits.append("\(formatMoney(f.spent)) spent") }
            if let avg = f.averagePrice, f.pricedAlbums > 1 { bits.append("\(formatMoney(avg)) on average") }
            switch f.format {
            case .cd:
                if f.labeled > 0 { bits.append(f.labeled == f.albums ? "all labeled" : "\(f.labeled) labeled") }
                out.append(Part(name: "CDs", icon: "opticaldisc", albums: f.albums, color: .accentColor, detail: bits.joined(separator: " · ")))
            case .digital:
                if f.partial > 0 { bits.append(f.partial == 1 ? "1 only partly" : "\(f.partial) only partly") }
                out.append(Part(name: "Downloads", icon: "dollarsign.circle", albums: f.albums, color: .accentColor.opacity(0.55),
                                detail: bits.joined(separator: " · ")))
            }
        }
        if stats.borrowedCount > 0 {
            out.append(Part(name: "Borrowed", icon: "arrow.left.arrow.right", albums: stats.borrowedCount, color: Color(.systemGray3),
                            detail: "From a library or a friend; not yours"))
        }
        return out
    }
}

struct InsightsOwnedArtistsCard: View {
    let stats: OwnershipStats
    enum Measure: String, CaseIterable { case spent = "Spent", albums = "Albums" }
    @State private var measure: Measure?

    var body: some View {
        let m = measure ?? (stats.pricedCount > 0 ? .spent : .albums)
        InsightCard(title: "Top Artists", subtitle: "By what you've spent on them, or albums owned") {
            InsightSegments(selection: Binding(get: { m }, set: { measure = $0 }))
        } content: {
            InsightRankedBars(items: items(m), initialCount: 6).id(m)
        }
    }

    private func items(_ m: Measure) -> [InsightRankedItem] {
        let sorted = m == .spent ? stats.artists : stats.artists.sorted { $0.albums != $1.albums ? $0.albums > $1.albums : $0.spent > $1.spent }
        return sorted.map { s in
            InsightRankedItem(name: s.name, value: m == .spent ? s.spent.doubleValue : Double(s.albums),
                              detail: m == .spent ? formatMoney(s.spent) : InsightOwned.albumCount(s.albums),
                              query: s.name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", s.name),
                              subtitle: m == .spent ? InsightOwned.albumCount(s.albums) : (s.spent > 0 ? formatMoney(s.spent) : nil))
        }
    }
}

/// Owned albums by genre or decade, with what they cost.
struct InsightsOwnedBreakdownCard: View {
    let title: String
    let subtitle: String
    let items: [OwnershipStats.Spend]
    var sortByCount = true
    let query: (OwnershipStats.Spend) -> String

    var body: some View {
        let sorted = sortByCount ? items.sorted { $0.albums != $1.albums ? $0.albums > $1.albums : $0.spent > $1.spent } : items
        InsightCard(title: title, subtitle: subtitle) {
            InsightRankedBars(items: sorted.map { s in
                InsightRankedItem(name: s.name, value: Double(s.albums),
                                  detail: InsightOwned.albumCount(s.albums) + (s.spent > 0 ? " · \(formatMoney(s.spent, whole: true))" : ""),
                                  query: query(s))
            }, initialCount: 6)
        }
    }
}

// MARK: Facts

struct InsightsOwnedFactsCard: View {
    let stats: OwnershipStats

    var body: some View {
        let facts = facts
        if !facts.isEmpty { InsightFactsCard(facts: facts) }
    }

    private var facts: [InsightFact] {
        var out: [InsightFact] = []
        func fact(_ icon: String, _ title: String, _ value: String, _ detail: String, _ a: OwnershipStats.OwnedAlbum) -> InsightFact {
            InsightFact(icon: icon, title: title, value: value, detail: detail, query: InsightOwned.albumQuery(a), queryTitle: a.album)
        }
        if let a = stats.mostExpensive, let p = a.price {
            out.append(fact("crown", "Priciest album", formatMoney(p), "\(a.album) — \(a.artist)", a))
        }
        if let a = stats.cheapest, let p = a.price {
            out.append(fact("tag", p == 0 ? "Got it for free" : "Best bargain", formatMoney(p), "\(a.album) — \(a.artist)", a))
        }
        if let a = stats.bestValue.first, let per = a.pricePerPlay {
            out.append(fact("star", "Best value", "\(formatMoney(per)) a play", "\(a.album) — \(playCount(a.plays)) for \(formatMoney(a.price ?? 0))", a))
        }
        if let a = stats.mostPlayed {
            out.append(fact("flame", "Most played album you own", playCount(a.plays), "\(a.album) — \(a.artist)", a))
        }
        if let a = stats.firstPurchase, let d = a.purchasedOn {
            out.append(fact("clock.arrow.circlepath", "Longest owned", d.date().formatted(.dateTime.year()), "\(a.album) — since \(InsightOwned.dayLabel(d))", a))
        }
        if let a = stats.latestPurchase, let d = a.purchasedOn {
            out.append(fact("sparkles", "Latest purchase", d.date().formatted(.relative(presentation: .named)), "\(a.album) — \(a.artist)", a))
        }
        if !stats.unplayed.isEmpty {
            out.append(InsightFact(icon: "shippingbox", title: "Still in the wrapper", value: stats.unplayed.count.formatted(),
                                   detail: "owned album\(stats.unplayed.count == 1 ? "" : "s") you haven't played yet"))
        }
        if stats.ownedDuration > 0 {
            out.append(InsightFact(icon: "infinity", title: "Your collection, back to back", value: formatLongDuration(stats.ownedDuration),
                                   detail: "across \(InsightOwned.albumCount(stats.ownedCount)) you own"))
        }
        if !stats.missingDetails.isEmpty {
            out.append(InsightFact(icon: "pencil", title: "Needs details", value: stats.missingDetails.count.formatted(),
                                   detail: "owned album\(stats.missingDetails.count == 1 ? " is" : "s are") missing a date or price"))
        }
        return out
    }
}
