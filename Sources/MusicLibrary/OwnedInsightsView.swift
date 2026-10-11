import Charts
import MusicLibraryCore
import SwiftUI

// MARK: Pane

/// The Owned pane of Insights: the albums you own, what you paid for them and how much you play them.
struct OwnedContent: View {
    let stats: OwnershipStats

    var body: some View {
        if stats.ownedCount == 0 {
            ContentUnavailableView("No Owned Albums Yet", systemImage: "bag",
                                   description: Text("Open an album and switch on “I own this album” under Your Copy, or answer “Do you own this CD?” when you rip one. Add when you bought it and what you paid, and this page fills in."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    OwnedTiles(stats: stats)
                    if !stats.timeline.isEmpty { SpendingCard(stats: stats) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        OwnedAlbumsCard(stats: stats)
                        OwnedArtistsCard(stats: stats)
                        if !stats.genres.isEmpty { OwnedBreakdownCard(title: "Genres", subtitle: "Albums can carry several", items: stats.genres, stats: stats) { SearchFilterKey.token("genre", $0.name) } }
                        if !stats.decades.isEmpty { OwnedBreakdownCard(title: "Release Eras", subtitle: "When the music you own came out", items: stats.decades, stats: stats, sortByCount: false) { "decade:\($0.name)" } }
                    }
                    OwnedFactsCard(stats: stats)
                }
                .padding(20)
            }
        }
    }
}

private func albumQuery(_ a: OwnershipStats.OwnedAlbum) -> String {
    SearchFilterKey.token("album", a.album) + " " + SearchFilterKey.token("albumartist", a.artist)
}

private func albumCount(_ n: Int) -> String { n == 1 ? "1 album" : "\(n.formatted()) albums" }

private func dayLabel(_ d: PurchaseDay) -> String { d.date().formatted(date: .abbreviated, time: .omitted) }

// MARK: Tiles

struct OwnedTiles: View {
    let stats: OwnershipStats

    var body: some View {
        let hasPrices = stats.pricedCount > 0
        TileGrid {
            InsightTile(value: stats.ownedCount.formatted(), label: stats.ownedCount == 1 ? "Album owned" : "Albums owned", icon: "bag",
                        detail: "\(stats.ownedFraction.formatted(.percent.precision(.fractionLength(0)))) of your \(albumCount(stats.libraryAlbumCount))")
            InsightTile(value: hasPrices ? formatMoney(stats.totalSpent) : "—", label: "Spent", icon: "creditcard",
                        detail: hasPrices ? "on \(stats.pricedCount.formatted()) of \(albumCount(stats.ownedCount))" : "add prices on album pages")
            InsightTile(value: stats.averagePrice.map { formatMoney($0) } ?? "—", label: "Average price", icon: "tag",
                        detail: stats.medianPrice.map { "median \(formatMoney($0))" })
            InsightTile(value: formatMoney(stats.spentThisYear), label: "Spent this year", icon: "calendar",
                        detail: "\(albumCount(stats.boughtThisYear)) bought in \(Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never)))")
            InsightTile(value: stats.costPerHour.map { formatMoney($0) } ?? "—", label: "Per hour of music", icon: "clock",
                        detail: stats.pricedDuration > 0 ? "\(formatLongDuration(stats.pricedDuration)) paid for" : nil)
            InsightTile(value: stats.costPerPlay.map { formatMoney($0) } ?? "—", label: "Per play", icon: "play.circle",
                        detail: hasPrices ? "\(playCount(stats.pricedPlays)) of albums you paid for" : nil)
        }
    }
}

// MARK: Spending over time

struct SpendingCard: View {
    @Environment(\.theme) private var theme
    let stats: OwnershipStats
    enum Measure: String, CaseIterable { case spent = "Spent", albums = "Albums", total = "Running Total" }
    @State private var measure = Measure.spent
    @State private var hovered: OwnershipStats.Period?

    var body: some View {
        InsightCard(title: "Spending Over Time", subtitle: subtitle) {
            Picker("", selection: $measure) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let h = hovered {
                        Text("\(label(h.start)) · \(formatMoney(h.spent)) on \(albumCount(h.albums)) · \(formatMoney(h.cumulative)) in all")
                            .foregroundStyle(.primary)
                    } else {
                        Text("Albums with a purchase date, by \(stats.granularity.rawValue) · hover for details").foregroundStyle(.subtext)
                    }
                }
                .font(.caption).monospacedDigit()
                chart.frame(height: 190)
            }
        }
    }

    private var unit: Calendar.Component { stats.granularity == .month ? .month : .year }

    @ViewBuilder
    private var chart: some View {
        Chart {
            ForEach(stats.timeline) { p in
                switch measure {
                case .spent:
                    BarMark(x: .value("Period", p.start, unit: unit), y: .value("Spent", p.spent.doubleValue))
                        .foregroundStyle(theme.series.opacity(hovered == nil || hovered == p ? 1 : 0.35))
                        .cornerRadius(2)
                case .albums:
                    BarMark(x: .value("Period", p.start, unit: unit), y: .value("Albums", p.albums))
                        .foregroundStyle(theme.series.opacity(hovered == nil || hovered == p ? 1 : 0.35))
                        .cornerRadius(2)
                case .total:
                    AreaMark(x: .value("Period", p.start, unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [theme.series.opacity(0.28), theme.series.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Period", p.start, unit: unit), y: .value("Total", p.cumulative.doubleValue))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(theme.series)
                }
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase, let frame = proxy.plotFrame,
                              let date = proxy.value(atX: p.x - geo[frame].origin.x, as: Date.self) else { hovered = nil; return }
                        hovered = stats.timeline.last { $0.start <= date } ?? stats.timeline.first
                    }
            }
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

struct OwnedAlbumsCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var model
    let stats: OwnershipStats
    enum Shelf: String, CaseIterable { case recent = "Recent", priciest = "Priciest", value = "Best Value", unplayed = "Unplayed", missing = "Needs Details" }
    @State private var list = Shelf.recent
    @State private var expanded = false
    @State private var hovered: String?

    var body: some View {
        let available = Shelf.allCases.filter { !albums($0).isEmpty }
        let current = available.contains(list) ? list : (available.first ?? .recent)
        let rows = albums(current)
        InsightCard(title: "Your Albums", subtitle: subtitle(current)) {
            Picker("", selection: $list) { ForEach(available, id: \.self) { Text($0.rawValue) } }
                .labelsHidden().fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows.prefix(expanded ? 50 : 8)) { a in row(a, current) }
                if rows.count > 8 {
                    Button(expanded ? "Show less" : "Show all \(min(rows.count, 50))\(rows.count > 50 ? " of \(rows.count)" : "")") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .buttonStyle(.link).font(.caption).padding(.top, 4).padding(.leading, 6)
                }
            }
        }
        .onChange(of: list) { expanded = false }
    }

    private func albums(_ list: Shelf) -> [OwnershipStats.OwnedAlbum] {
        switch list {
        case .recent: stats.albums
        case .priciest: stats.albums.filter { $0.price != nil }.sorted { $0.price! > $1.price! }
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
        case .unplayed: "Owned but never played here"
        case .missing: "Owned, without a purchase date or price"
        }
    }

    private func row(_ a: OwnershipStats.OwnedAlbum, _ list: Shelf) -> some View {
        let summary = model.album(forKey: a.id)
        return Button { if let summary { model.navigationPath.append(summary) } } label: {
            HStack(spacing: 10) {
                CoverThumb(url: summary.flatMap(model.coverURL(forAlbum:)), size: 34, revision: model.coverRevision)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.album).lineLimit(1)
                    Text(a.artist).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(primary(a, list)).monospacedDigit()
                    if let s = secondary(a, list) { Text(s).font(.caption).foregroundStyle(.subtext).monospacedDigit() }
                }
                .lineLimit(1)
            }
            .font(.callout)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered == a.id ? theme.fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? a.id : (hovered == a.id ? nil : hovered) }
        .help("Open \(a.album)")
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
        case .value: "\(playCount(a.plays)) · \(a.price.map { formatMoney($0) } ?? "")"
        case .missing: nil
        default: a.purchasedOn.map(dayLabel)
        }
    }
}

// MARK: Breakdowns

struct OwnedArtistsCard: View {
    let stats: OwnershipStats
    enum Measure: String, CaseIterable { case spent = "Spent", albums = "Albums" }
    @State private var measure: Measure?

    var body: some View {
        let m = measure ?? (stats.pricedCount > 0 ? .spent : .albums)
        InsightCard(title: "Top Artists", subtitle: "By what you've spent on them, or albums owned") {
            Picker("", selection: Binding(get: { m }, set: { measure = $0 })) { ForEach(Measure.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            RankedBars(items: items(m), initialCount: 6).id(m)
        }
    }

    private func items(_ m: Measure) -> [RankedItem] {
        let sorted = m == .spent ? stats.artists : stats.artists.sorted { $0.albums != $1.albums ? $0.albums > $1.albums : $0.spent > $1.spent }
        return sorted.map { s in
            RankedItem(name: s.name, value: m == .spent ? s.spent.doubleValue : Double(s.albums),
                       detail: m == .spent ? formatMoney(s.spent) : albumCount(s.albums),
                       query: s.name == "Unknown Artist" ? nil : SearchFilterKey.token("albumartist", s.name),
                       subtitle: m == .spent ? albumCount(s.albums) : (s.spent > 0 ? formatMoney(s.spent) : nil))
        }
    }
}

/// Owned albums by genre or decade, with what they cost.
struct OwnedBreakdownCard: View {
    let title: String
    let subtitle: String
    let items: [OwnershipStats.Spend]
    let stats: OwnershipStats
    var sortByCount = true
    let query: (OwnershipStats.Spend) -> String

    var body: some View {
        let sorted = sortByCount ? items.sorted { $0.albums != $1.albums ? $0.albums > $1.albums : $0.spent > $1.spent } : items
        InsightCard(title: title, subtitle: subtitle) {
            RankedBars(items: sorted.map { s in
                RankedItem(name: s.name, value: Double(s.albums),
                           detail: albumCount(s.albums) + (s.spent > 0 ? " · \(formatMoney(s.spent, whole: true))" : ""),
                           query: query(s))
            }, initialCount: 6)
        }
    }
}

// MARK: Facts

struct OwnedFactsCard: View {
    let stats: OwnershipStats

    var body: some View {
        let facts = facts
        if !facts.isEmpty { InsightCard(title: "Fun Facts") { FactsGrid(facts: facts) } }
    }

    private var facts: [FunFact] {
        var out: [FunFact] = []
        if let a = stats.mostExpensive, let p = a.price {
            out.append(FunFact(icon: "crown", title: "Priciest album", value: formatMoney(p), detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if let a = stats.cheapest, let p = a.price {
            out.append(FunFact(icon: "tag", title: p == 0 ? "Got it for free" : "Best bargain", value: formatMoney(p),
                               detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if let a = stats.bestValue.first, let per = a.pricePerPlay {
            out.append(FunFact(icon: "star", title: "Best value", value: "\(formatMoney(per)) a play",
                               detail: "\(a.album) — \(playCount(a.plays)) for \(formatMoney(a.price ?? 0))", query: albumQuery(a)))
        }
        if let a = stats.mostPlayed {
            out.append(FunFact(icon: "flame", title: "Most played album you own", value: playCount(a.plays),
                               detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if let a = stats.firstPurchase, let d = a.purchasedOn {
            out.append(FunFact(icon: "clock.arrow.circlepath", title: "Longest owned", value: d.date().formatted(.dateTime.year()),
                               detail: "\(a.album) — since \(dayLabel(d))", query: albumQuery(a)))
        }
        if let a = stats.latestPurchase, let d = a.purchasedOn {
            out.append(FunFact(icon: "sparkles", title: "Latest purchase", value: d.date().formatted(.relative(presentation: .named)),
                               detail: "\(a.album) — \(a.artist)", query: albumQuery(a)))
        }
        if !stats.unplayed.isEmpty {
            out.append(FunFact(icon: "shippingbox", title: "Still in the wrapper", value: stats.unplayed.count.formatted(),
                               detail: "owned album\(stats.unplayed.count == 1 ? "" : "s") you haven't played here yet"))
        }
        if stats.ownedDuration > 0 {
            out.append(FunFact(icon: "infinity", title: "Your collection, back to back", value: formatLongDuration(stats.ownedDuration),
                               detail: "across \(albumCount(stats.ownedCount)) you own"))
        }
        if !stats.missingDetails.isEmpty {
            out.append(FunFact(icon: "pencil", title: "Needs details", value: stats.missingDetails.count.formatted(),
                               detail: "owned album\(stats.missingDetails.count == 1 ? " is" : "s are") missing a date or price"))
        }
        return out
    }
}
