import Charts
import MusicLibraryCore
import SwiftUI

// What things are worth, on both apps: a copy's value on its page (`CollectionValueSection`), the Buy List's prices
// (`WantedPriceSummary`, `WantedPriceHistory`), and the Owned pane's Collection Value and Buy List cards.

// MARK: A copy's value

/// "What It's Worth" on an item's page: the latest value of this copy's edition on Discogs, against what you paid, with
/// Discogs' price guide underneath once it has been read this session.
public struct CollectionValueSection: View {
    let value: CollectionValue?
    let guide: PriceGuide?
    let paid: Decimal?
    /// The copy's media grade: the guide underneath leads with its price, and an ungraded copy is valued at VG to NM.
    let grade: CollectionGrade?
    let pricing: Bool
    let refresh: () -> Void
    @State private var showsGuide = false

    public init(value: CollectionValue?, guide: PriceGuide?, paid: Decimal?, grade: CollectionGrade? = nil, pricing: Bool,
                refresh: @escaping () -> Void) {
        self.value = value
        self.guide = guide
        self.paid = paid
        self.grade = grade
        self.pricing = pricing
        self.refresh = refresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "What It's Worth")
                Spacer()
                if pricing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(value == nil ? "Price It" : "Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if let value, let text = value.text {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(text).font(.title2.weight(.semibold)).monospacedDigit()
                        if let delta = gain(value) { gainLabel(delta) }
                    }
                    if let source = value.source { Text("From \(source)").font(.caption).foregroundStyle(.secondary) }
                    if let sales = salesText(value) {
                        Text(sales).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let note = gradeNote(value) {
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    figures(value)
                } else if let value, !value.found {
                    Text("Nothing on Discogs matched this edition when it was priced.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let value {
                    Text("No price on Discogs for this edition yet: it hasn't sold there, and none is for sale.")
                        .font(.callout).foregroundStyle(.secondary)
                    figures(value)
                } else if pricing {
                    Text("Checking Discogs for this edition…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("See what this edition sells for on Discogs.").font(.callout).foregroundStyle(.secondary)
                }
                if let value {
                    Text("Priced \(value.at.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let guide, guide.hasPrices {
                    DisclosureGroup(isExpanded: $showsGuide) {
                        PriceGuideView(guide: guide, lead: .copy(grade: grade)).padding(.top, 6)
                    } label: {
                        Text("Price Guide").font(.callout.weight(.medium))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    /// "Median $10 · last sold Sep 23, 2026", for a value from the pressing's Discogs sales.
    private func salesText(_ value: CollectionValue) -> String? {
        guard let median = value.median else { return nil }
        let last = value.lastSold.map { " · last sold \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "Median \(PriceGuide.text(median))\(last)"
    }

    /// Why a copy's value isn't for its grade: it has none, or Discogs gave no price for it.
    private func gradeNote(_ value: CollectionValue) -> String? {
        guard let grade else { return "Set the copy's condition for a price for its grade." }
        guard let source = value.source, !source.contains(" in \(grade.short)") else { return nil }
        return "Discogs gave no price for \(grade.short) on this pressing (Discogs' prices by condition need a Discogs token, set on the Mac in Settings ▸ Discogs)."
    }

    private func gain(_ value: CollectionValue) -> Decimal? {
        guard let paid, let estimate = value.estimate else { return nil }
        return estimate.amount - paid
    }

    private func gainLabel(_ delta: Decimal) -> some View {
        let up = delta >= 0
        return Label("\(up ? "+" : "−")\(CollectionInsightText.money(abs(delta))) vs. what you paid",
                     systemImage: up ? "arrow.up.right" : "arrow.down.right")
            .font(.caption.weight(.medium))
            .foregroundStyle(up ? Color.green : Color.orange)
    }

    @ViewBuilder
    private func figures(_ value: CollectionValue) -> some View {
        let parts = [
            value.lowest.map { "Cheapest on Discogs \(PriceGuide.text($0))" },
            value.forSale.map { $0 == 1 ? "1 for sale" : "\($0.formatted()) for sale" },
            value.have.map { "\($0.formatted()) have" },
            value.want.map { "\($0.formatted()) want" },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if let release = value.releaseID, let url = DiscogsLink.releaseURL(release), url.isWebLink {
            Link("Open on Discogs", destination: url).font(.caption)
        }
    }
}

// MARK: Buy List

/// A Buy List album's prices: the fair price, the cheapest asking now, how that moved since the check before, and
/// whether it's at or under the most you'd pay.
public struct WantedPriceSummary: View {
    let album: WantedAlbum
    let checking: Bool
    let compact: Bool

    public init(album: WantedAlbum, checking: Bool, compact: Bool = false) {
        self.album = album
        self.checking = checking
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let check = album.latest {
                if let now = check.cheapestNow {
                    HStack(spacing: 6) {
                        if let change = album.change, change != 0 { changeLabel(change) }
                        Text(PriceGuide.text(now)).font(compact ? .callout.weight(.semibold) : .title3.weight(.semibold)).monospacedDigit()
                    }
                } else if !check.found {
                    Text("Not found").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("None for sale").font(.callout).foregroundStyle(.secondary)
                }
                if let fair = check.fairText {
                    Text("fair \(fair)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if !checking {
                Text("Not priced").font(.callout).foregroundStyle(.secondary)
            }
            if album.isDeal {
                Text("At or under your max").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
            } else if let max = album.maxMoney, !compact {
                Text("max \(PriceGuide.text(max))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if checking {
                ProgressView().controlSize(.mini)
            } else if let at = album.latest?.at, !compact {
                Text(at.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func changeLabel(_ change: Decimal) -> some View {
        let down = change < 0
        return Label(CollectionInsightText.money(abs(change)), systemImage: down ? "arrow.down" : "arrow.up")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(down ? Color.green : Color.orange)
            .help(down ? "Cheaper than at the check before" : "Dearer than at the check before")
    }
}

/// How a Buy List album's prices moved over its checks: the cheapest asking price and the fair price's middle.
public struct WantedPriceHistory: View {
    let album: WantedAlbum

    public init(album: WantedAlbum) { self.album = album }

    private struct Point: Identifiable {
        var at: Date
        var series: String
        var amount: Double
        var id: String { "\(series)\(at.timeIntervalSince1970)" }
    }

    public var body: some View {
        let currency = album.latest?.headline?.currency ?? album.currency
        let points = album.checks.reversed().flatMap { c -> [Point] in
            [c.cheapestNow.map { ("Cheapest", $0) }, c.fairMid.map { ("Fair", $0) }].compactMap { $0 }
                .filter { $0.1.currency == currency }
                .map { Point(at: c.at, series: $0.0, amount: $0.1.amount.doubleValue) }
        }
        if Set(points.map(\.at)).count >= 2 {
            Chart(points) { p in
                LineMark(x: .value("Checked", p.at), y: .value("Price", p.amount))
                    .foregroundStyle(by: .value("Price", p.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Checked", p.at), y: .value("Price", p.amount))
                    .foregroundStyle(by: .value("Price", p.series))
                    .symbolSize(18)
            }
            .chartForegroundStyleScale(domain: ["Cheapest", "Fair"], range: [VizColor.series, VizColor.neutral])
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(PriceGuide.text(Money(Decimal(v), currency))) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 120)
        }
    }
}

// MARK: Insights

/// The Owned pane's Collection Value card: what the CDs and records are worth now, against what you paid, by medium,
/// with the most valuable copies and the ones that gained most. `update` (the Mac) prices what isn't priced yet.
public struct CollectionValueCard<Art: View>: View {
    let stats: CollectionValueStats
    let progress: (done: Int, total: Int)?
    let update: (() -> Void)?
    let stop: (() -> Void)?
    let art: (CollectionItem) -> Art
    @Environment(\.collectionInsightActions) private var actions
    public enum List: String, CaseIterable { case top = "Most Valuable", gainers = "Biggest Gains" }
    @State private var list = List.top

    public init(stats: CollectionValueStats, progress: (done: Int, total: Int)? = nil, update: (() -> Void)? = nil,
                stop: (() -> Void)? = nil, @ViewBuilder art: @escaping (CollectionItem) -> Art) {
        self.stats = stats
        self.progress = progress
        self.update = update
        self.stop = stop
        self.art = art
    }

    public var body: some View {
        InsightCard(title: "Collection Value", subtitle: subtitle) {
            if !stats.gainers.isEmpty {
                Picker("List", selection: $list) { ForEach(List.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if stats.isEmpty {
                    Text(update == nil ? "Your CDs and records haven't been priced yet. Price them on the Mac (Insights ▸ Owned ▸ Update Values), or open one and check what it's worth."
                         : "See what your CDs and records are worth on Discogs: each copy's edition is priced, about two requests per copy, at the pace Discogs allows.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    headline
                    media
                    rows
                }
                footer
            }
        }
    }

    private func money(_ d: Decimal) -> String { PriceGuide.text(Money(d.rounded(0), stats.currency)) }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(money(stats.total)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                Text("\(CollectionInsightText.itemCount(stats.valued)) priced").font(.caption).foregroundStyle(.secondary)
            }
            if stats.paid > 0 {
                let up = stats.gain >= 0
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(up ? "+" : "−")\(money(abs(stats.gain)))").font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(up ? Color.green : Color.orange)
                    Text("vs. \(money(stats.paid)) paid for those with a price").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var media: some View {
        let parts = stats.byMedium.sorted { $0.value > $1.value }.compactMap { raw, amount -> String? in
            CollectionMedium(rawValue: raw).map { "\(CollectionInsightText.plural($0)) \(money(amount))" }
        }
        if parts.count > 1 { Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
    }

    private var rows: some View {
        let shown = list == .top || stats.gainers.isEmpty ? stats.top : stats.gainers
        return VStack(spacing: 0) {
            ForEach(shown) { row in
                Button { actions.open(.item(id: row.item.id)) } label: {
                    HStack(spacing: 10) {
                        art(row.item)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.item.album).lineLimit(1)
                            HStack(spacing: 6) {
                                if let sticker = row.item.sticker { StickerPill(sticker: sticker) }
                                Text(row.item.artist).lineLimit(1)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(PriceGuide.text(row.value)).monospacedDigit()
                            if let gain = row.gain, list == .gainers || gain != 0 {
                                Text("\(gain >= 0 ? "+" : "−")\(CollectionInsightText.money(abs(gain)))")
                                    .font(.caption).monospacedDigit().foregroundStyle(gain >= 0 ? Color.green : Color.orange)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let progress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(maxWidth: 200)
                Text("Pricing \(progress.done) of \(progress.total)…").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let stop { Button("Stop", action: stop).font(.caption) }
            }
        } else if let update, stats.toUpdate > 0 || stats.isEmpty {
            HStack(spacing: 8) {
                Button(stats.isEmpty ? "Price My Collection" : "Update Values", action: update)
                Text(stats.toUpdate == 1 ? "1 copy to price" : "\(stats.toUpdate.formatted()) copies to price (not priced, or priced over a month ago)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String? {
        guard !stats.isEmpty else { return nil }
        var parts = ["Fair prices on Discogs and eBay"]
        if stats.eligible > stats.valued { parts.append("\(stats.valued) of \(stats.eligible) CDs and records") }
        if let last = stats.lastCheck { parts.append("updated \(last.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// The Owned pane's Buy List card: how many albums you're after, what they'd cost, and which are deals now.
public struct BuyListCard: View {
    let shown: [WantedAlbum]
    let open: () -> Void

    public init(shown: [WantedAlbum], open: @escaping () -> Void) {
        self.shown = shown
        self.open = open
    }

    public var body: some View {
        let totals = BuyList.totals(shown)
        InsightCard(title: "Buy List", subtitle: shown.isEmpty ? nil : "What you're looking for") {
            Button("Open", action: open).font(.callout)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if shown.isEmpty {
                    Text("Price an album in the Shop and put it on your Buy List: it keeps what it goes for, and tells you when something's at or under the most you'd pay.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        stat(CollectionInsightText.albumCount(totals.count), "wanted")
                        if let cost = totals.cost { stat("≈ \(PriceGuide.text(Money(cost.amount.rounded(0), cost.currency)))", "to get them all") }
                        if totals.deals > 0 { stat("\(totals.deals)", totals.deals == 1 ? "deal now" : "deals now", color: .green) }
                    }
                    ForEach(shown.prefix(4)) { w in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.album).lineLimit(1)
                                Text([w.artist, w.format.name].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            WantedPriceSummary(album: w, checking: false, compact: true)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Decimal {
    /// Rounded to `places` decimal places, half up.
    func rounded(_ places: Int) -> Decimal {
        var value = self, result = Decimal()
        NSDecimalRound(&result, &value, places, .plain)
        return result
    }

    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
