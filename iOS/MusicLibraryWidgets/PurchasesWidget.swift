import MusicLibraryGlance
import SwiftUI
import WidgetKit

/// Your collection: the CDs, records and downloads you added lately, how many need ripping and the next free labels.
/// Its kind is still "Purchases", so widgets placed before the collection keep working. From an iPhone app that sends
/// no collection (an older summary), it shows the albums you bought lately, as before.
struct PurchasesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceWidgetKind.purchases.rawValue, provider: GlanceProvider()) { entry in
            PurchasesWidgetView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("Collection")
        .description("The CDs, records and downloads you added lately, what's left to rip and your next labels.")
        .supportedFamilies(Self.families)
        .contentMarginsDisabled()
    }

    #if os(watchOS)
    static let families: [WidgetFamily] = [.accessoryRectangular, .accessoryInline]
    #else
    static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline]
    #endif
}

struct PurchasesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GlanceEntry

    static let tint = Color.green

    var body: some View {
        content.widgetURL(url)
    }

    /// The small widget opens what it shows; the others open the Collection pane of Insights (their items are links).
    private var url: URL {
        #if os(iOS)
        if family == .systemSmall, let glance = entry.glance {
            if let collection = glance.collection {
                if let latest = collection.recent?.first { return GlanceLink.item(id: latest.id).url }
            } else if let latest = glance.owned.recent.first {
                return GlanceLink.album(key: latest.album.key).url
            }
        }
        #endif
        return GlanceLink.insights(.owned).url
    }

    @ViewBuilder
    private var content: some View {
        if let glance = entry.glance {
            if let collection = glance.collection {
                collectionContent(glance, collection)
            } else {
                ownedContent(glance, glance.owned)
            }
        } else {
            NoLibraryView(systemImage: "books.vertical").padding()
        }
    }

    // MARK: Collection

    @ViewBuilder
    private func collectionContent(_ glance: Glance, _ c: Glance.Collection) -> some View {
        switch family {
        case .accessoryRectangular: rectangular(c)
        case .accessoryInline: Label(Self.nextLabel(c), systemImage: "number")
        #if os(iOS)
        case .systemMedium: medium(glance, c).padding(14)
        case .systemLarge: large(glance, c).padding(16)
        default: small(c)
        #else
        default: rectangular(c)
        #endif
        }
    }

    /// "312 CDs · 48 vinyl"
    static func counts(_ c: Glance.Collection) -> String {
        let cds = c.cds ?? 0, vinyl = c.vinyl ?? 0
        if cds == 0 && vinyl == 0 { return GlanceFormat.count(c.items ?? 0, "item") }
        return [cds > 0 || vinyl == 0 ? GlanceFormat.count(cds, "CD") : nil, vinyl > 0 ? "\(vinyl.formatted()) vinyl" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "Next label: CD #313", or the vinyl series' when there are records and no CDs.
    static func nextLabel(_ c: Glance.Collection) -> String {
        if (c.cds ?? 0) == 0, (c.vinyl ?? 0) > 0, let next = c.nextVinyl {
            return "Next label: " + GlanceFormat.sticker(medium: "vinyl", number: next)
        }
        return "Next label: " + GlanceFormat.sticker(medium: "cd", number: c.nextCD ?? 1)
    }

    /// "Next: CD #313 · Vinyl #49"
    static func nextLabels(_ c: Glance.Collection) -> String {
        var parts = [GlanceFormat.sticker(medium: "cd", number: c.nextCD ?? 1)]
        if (c.vinyl ?? 0) > 0, let next = c.nextVinyl { parts.append(GlanceFormat.sticker(medium: "vinyl", number: next)) }
        return "Next: " + parts.joined(separator: " · ")
    }

    private func collectionEmpty() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Collection", systemImage: "books.vertical", tint: Self.tint)
            Spacer(minLength: 0)
            Text("Nothing in your collection yet").font(.headline)
            Text("Add CDs, records and downloads in Music Library on your Mac.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: Collection: home screen

    @ViewBuilder
    private func small(_ c: Glance.Collection) -> some View {
        if let latest = c.recent?.first {
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(title: "Latest", systemImage: "books.vertical", tint: Self.tint)
                ShelfArt(item: latest, height: 62)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text(latest.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(latest.stickerText.map { "\($0) · \(latest.artist)" } ?? latest.artist)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let added = latest.addedText() {
                    Text(added).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            collectionEmpty()
        }
    }

    private func countStats(_ c: Glance.Collection) -> some View {
        HStack(alignment: .top) {
            Stat(value: (c.cds ?? 0).formatted(), label: (c.cds ?? 0) == 1 ? "CD" : "CDs")
            Stat(value: (c.vinyl ?? 0).formatted(), label: "vinyl")
            Stat(value: (c.toRip ?? 0).formatted(), label: "to rip")
        }
    }

    @ViewBuilder
    private func medium(_ glance: Glance, _ c: Glance.Collection) -> some View {
        let recent = Array((c.recent ?? []).prefix(2))
        if recent.isEmpty {
            collectionEmpty()
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: "Collection", systemImage: "books.vertical", tint: Self.tint)
                    Spacer(minLength: 0)
                    countStats(c)
                    Text(Self.nextLabels(c)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(recent) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Link(destination: GlanceLink.item(id: item.id).url) {
                            VStack(alignment: .leading, spacing: 2) {
                                ShelfArt(item: item, height: 58)
                                Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1)
                                Text(item.stickerText ?? item.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        playButton(item)
                    }
                    .frame(width: 74, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func large(_ glance: Glance, _ c: Glance.Collection) -> some View {
        let owned = glance.owned
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                WidgetHeader(title: "Collection", systemImage: "books.vertical", tint: Self.tint)
                Spacer()
                Text(Self.nextLabels(c)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            countStats(c)
            Divider()
            let recent = Array((c.recent ?? []).prefix(4))
            if recent.isEmpty {
                Text("Add CDs, records and downloads in Music Library on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(recent) { item in
                HStack(spacing: 10) {
                    Link(destination: GlanceLink.item(id: item.id).url) {
                        HStack(spacing: 10) {
                            ShelfArt(item: item, height: 36).frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(item.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(item.stickerText ?? ShelfArt.mediumName(item.medium)).font(.caption.weight(.medium)).monospacedDigit()
                                if let added = item.addedText(short: true) { Text(added).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    playButton(item)
                }
            }
            Spacer(minLength: 0)
            Text("\(glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000)) spent this year · \(GlanceFormat.count(owned.boughtThisYear, "purchase"))")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Play, only for an item whose songs are on this iPhone.
    @ViewBuilder
    private func playButton(_ item: Glance.Collection.Item) -> some View {
        #if os(iOS)
        if item.playable == true {
            Button(intent: PlayAlbumIntent(albumKey: item.albumKey)) {
                Image(systemName: "play.fill").font(.caption)
            }
            .tint(Self.tint)
            .accessibilityLabel("Play \(item.title)")
        }
        #endif
    }

    // MARK: Collection: lock screen and watch

    private func rectangular(_ c: Glance.Collection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(Self.counts(c), systemImage: "books.vertical")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .widgetAccentable()
            Text("\((c.toRip ?? 0).formatted()) to rip").font(.caption).lineLimit(1)
            Text(Self.nextLabels(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Before the collection

    @ViewBuilder
    private func ownedContent(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        switch family {
        case .accessoryRectangular: ownedRectangular(glance, owned)
        case .accessoryInline:
            Label("\(GlanceFormat.count(owned.boughtThisYear, "album")) this year · \(glance.money(owned.spentThisYear, whole: true))", systemImage: "bag")
        #if os(iOS)
        case .systemMedium: ownedMedium(glance, owned).padding(14)
        case .systemLarge: ownedLarge(glance, owned).padding(16)
        default: ownedSmall(glance, owned)
        #else
        default: ownedRectangular(glance, owned)
        #endif
        }
    }

    private func thisYear(_ glance: Glance, _ owned: Glance.Owned) -> String {
        "\(GlanceFormat.count(owned.boughtThisYear, "album")) · \(glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000))"
    }

    private func priceAndDate(_ glance: Glance, _ p: Glance.Owned.Purchase) -> String {
        [p.price.map { glance.money($0) }, p.dateText].compactMap { $0 }.joined(separator: " · ")
    }

    private func ownedEmpty(_ owned: Glance.Owned) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Purchases", systemImage: "bag", tint: Self.tint)
            Spacer(minLength: 0)
            Text(owned.ownedCount == 0 ? "No purchases yet" : "\(GlanceFormat.count(owned.ownedCount, "album")) owned").font(.headline)
            Text("Add CDs, records and downloads in Music Library on your Mac.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    @ViewBuilder
    private func ownedSmall(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        if let latest = owned.recent.first {
            ZStack(alignment: .bottomLeading) {
                CoverBackground(name: latest.album.cover, title: latest.album.title)
                VStack(alignment: .leading, spacing: 2) {
                    Label("LATEST", systemImage: "bag.fill").font(.caption2.weight(.bold)).opacity(0.9)
                    Spacer(minLength: 0)
                    Text(latest.album.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(latest.album.artist).font(.caption).opacity(0.85).lineLimit(1)
                    Text(priceAndDate(glance, latest)).font(.caption2.weight(.medium)).opacity(0.85).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
        } else {
            ownedEmpty(owned)
        }
    }

    @ViewBuilder
    private func ownedMedium(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        if owned.recent.isEmpty {
            ownedEmpty(owned)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetHeader(title: "Recent Purchases", systemImage: "bag", tint: Self.tint)
                    Spacer()
                    Text(thisYear(glance, owned) + " this year").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .top, spacing: 10) {
                    ForEach(owned.recent.prefix(4)) { p in
                        Link(destination: GlanceLink.album(key: p.album.key).url) {
                            VStack(alignment: .leading, spacing: 2) {
                                CoverArt(name: p.album.cover, title: p.album.title)
                                Text(p.album.title).font(.caption2.weight(.semibold)).lineLimit(1)
                                Text(p.dateText ?? p.album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, 4 - owned.recent.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    @ViewBuilder
    private func ownedLarge(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(title: "Purchases", systemImage: "bag", tint: Self.tint)
            HStack(alignment: .top) {
                Stat(value: glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000), label: "this year")
                Stat(value: owned.boughtThisYear.formatted(), label: owned.boughtThisYear == 1 ? "album bought" : "albums bought")
                Stat(value: owned.ownedCount.formatted(), label: owned.libraryAlbumCount > 0
                     ? "owned (\(Int((Double(owned.ownedCount) / Double(owned.libraryAlbumCount) * 100).rounded()))%)" : "owned")
            }
            Divider()
            if owned.recent.isEmpty {
                Text("Add CDs, records and downloads in Music Library on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(owned.recent.prefix(5)) { p in
                Link(destination: GlanceLink.album(key: p.album.key).url) {
                    HStack(spacing: 10) {
                        CoverArt(name: p.album.cover, title: p.album.title, cornerRadius: 4).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.album.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(p.album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            if let price = p.price { Text(glance.money(price)).font(.caption.weight(.medium)).monospacedDigit() }
                            if let date = p.dateText { Text(date).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ownedRectangular(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(glance.money(owned.spentThisYear, whole: true), systemImage: "bag")
                .font(.headline)
                .widgetAccentable()
            Text("\(GlanceFormat.count(owned.boughtThisYear, "album")) this year").font(.caption).lineLimit(1)
            if let latest = owned.recent.first {
                Text("Latest: \(latest.album.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A big number over a small label.
struct Stat: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
