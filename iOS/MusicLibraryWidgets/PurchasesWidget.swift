import MusicLibraryGlance
import SwiftUI
import WidgetKit

/// The albums you bought lately, with what you've spent this year.
struct PurchasesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GlanceWidgetKind.purchases.rawValue, provider: GlanceProvider()) { entry in
            PurchasesWidgetView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("Recent Purchases")
        .description("The albums you bought lately and what you've spent this year.")
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

    /// The small widget opens the album it shows; the others open Insights (their albums are links).
    private var url: URL {
        #if os(iOS)
        if family == .systemSmall, let latest = entry.glance?.owned.recent.first { return GlanceLink.album(key: latest.album.key).url }
        #endif
        return GlanceLink.insights(.owned).url
    }

    @ViewBuilder
    private var content: some View {
        if let glance = entry.glance {
            let owned = glance.owned
            switch family {
            case .accessoryRectangular: rectangular(glance, owned)
            case .accessoryInline:
                Label("\(GlanceFormat.count(owned.boughtThisYear, "album")) this year · \(glance.money(owned.spentThisYear, whole: true))", systemImage: "bag")
            #if os(iOS)
            case .systemMedium: medium(glance, owned).padding(14)
            case .systemLarge: large(glance, owned).padding(16)
            default: small(glance, owned)
            #else
            default: rectangular(glance, owned)
            #endif
            }
        } else {
            NoLibraryView(systemImage: "bag").padding()
        }
    }

    private func thisYear(_ glance: Glance, _ owned: Glance.Owned) -> String {
        "\(GlanceFormat.count(owned.boughtThisYear, "album")) · \(glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000))"
    }

    private func priceAndDate(_ glance: Glance, _ p: Glance.Owned.Purchase) -> String {
        [p.price.map { glance.money($0) }, p.dateText].compactMap { $0 }.joined(separator: " · ")
    }

    private func empty(_ owned: Glance.Owned) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Purchases", systemImage: "bag", tint: Self.tint)
            Spacer(minLength: 0)
            Text(owned.ownedCount == 0 ? "No purchases yet" : "\(GlanceFormat.count(owned.ownedCount, "album")) owned").font(.headline)
            Text("Add when you bought an album and what you paid on its page, under Your Copy.")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: Home screen

    @ViewBuilder
    private func small(_ glance: Glance, _ owned: Glance.Owned) -> some View {
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
            empty(owned)
        }
    }

    @ViewBuilder
    private func medium(_ glance: Glance, _ owned: Glance.Owned) -> some View {
        if owned.recent.isEmpty {
            empty(owned)
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
    private func large(_ glance: Glance, _ owned: Glance.Owned) -> some View {
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
                Text("Add when you bought an album and what you paid on its page, under Your Copy.")
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

    // MARK: Lock screen and watch

    private func rectangular(_ glance: Glance, _ owned: Glance.Owned) -> some View {
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
