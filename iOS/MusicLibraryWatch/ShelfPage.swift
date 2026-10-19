import MusicLibraryGlance
import SwiftUI

/// Pages pushed by value on the watch's navigation stack (besides albums and collection items).
enum WatchRoute: Hashable {
    case find
}

// MARK: Shelf

/// The physical collection (titled "Physical"): the CDs and records you own (with a count of the downloads you bought),
/// what you added lately and the CDs still to rip, with Find to look one up by its label. From an iPhone before the
/// collection, the albums you bought instead.
struct ShelfPage: View {
    let glance: Glance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(value: WatchRoute.find) {
                    Label("Find by Label", systemImage: "number")
                        .frame(maxWidth: .infinity)
                }
                if let collection = glance.collection {
                    collectionContent(collection)
                } else {
                    UpdateIPhoneNote(text: "Update the iPhone app to see your physical collection.")
                    ownedContent(glance.owned)
                }
            }
        }
        .navigationTitle("Physical")
        .containerBackground(Color.green.gradient, for: .tabView)
    }

    @ViewBuilder
    private func collectionContent(_ c: Glance.Collection) -> some View {
        if Self.isEmpty(c) {
            Text("Add CDs and records in Music Library on your Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.counts(c))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let more = Self.moreCounts(c) {
                    Text(more).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let recent = c.recent, !recent.isEmpty {
                SectionTitle("Recently Added")
                ForEach(recent) { item in
                    NavigationLink(value: item) { ShelfItemRow(item: item) }
                        .buttonStyle(.plain)
                }
            } else if !glance.owned.recent.isEmpty {
                SectionTitle("Recently Added")
                ownedRecent(glance.owned)
            }
            if let toRip = c.toRipList, !toRip.isEmpty {
                SectionTitle("To Rip")
                ForEach(toRip) { item in
                    NavigationLink(value: item) { ShelfItemRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    /// Nothing to show: every field is optional, so it's empty only when none of them has anything.
    static func isEmpty(_ c: Glance.Collection) -> Bool {
        [c.items, c.cds, c.vinyl, c.downloads, c.toRip, c.vinylToDigitize].allSatisfy { ($0 ?? 0) == 0 }
            && (c.recent ?? []).isEmpty && (c.toRipList ?? []).isEmpty
    }

    /// "312 CDs · 48 records · 9 to rip" (counts, so never written like a label: "CD 312" reads as CD #312).
    static func counts(_ c: Glance.Collection) -> String {
        let cds = c.cds ?? 0, vinyl = c.vinyl ?? 0, toRip = c.toRip ?? 0
        var parts: [String] = []
        if cds > 0 || vinyl == 0 { parts.append(GlanceFormat.count(cds, "CD")) }
        if vinyl > 0 { parts.append(GlanceFormat.count(vinyl, "record")) }
        if toRip > 0 { parts.append("\(toRip.formatted()) to rip") }
        return parts.joined(separator: " · ")
    }

    /// "3 records to digitize · 97 owned downloads" (downloads are digital, so they come last, said as such); nil when
    /// there are neither.
    static func moreCounts(_ c: Glance.Collection) -> String? {
        var parts: [String] = []
        if let vinyl = c.vinylToDigitize, vinyl > 0 { parts.append("\(GlanceFormat.count(vinyl, "record")) to digitize") }
        if let downloads = c.downloads, downloads > 0 { parts.append("\(downloads.formatted()) owned \(downloads == 1 ? "download" : "downloads")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What an iPhone before the collection sends: library albums you own, and spending.
    @ViewBuilder
    private func ownedContent(_ owned: Glance.Owned) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(glance.money(owned.spentThisYear, whole: owned.spentThisYear >= 1000))
                .font(.system(.title, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.6)
            Text("\(GlanceFormat.count(owned.boughtThisYear, "album")) this year")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(owned.ownedCount.formatted()) owned in all · \(glance.money(owned.totalSpent, whole: true))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if owned.recent.isEmpty {
            Text("Add CDs, records and downloads in Music Library on your Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            SectionTitle("Latest")
            ownedRecent(owned)
        }
    }

    /// The library albums bought lately, with what they cost.
    private func ownedRecent(_ owned: Glance.Owned) -> some View {
        ForEach(owned.recent) { p in
            NavigationLink(value: p.album) {
                AlbumRow(album: p.album, detail: [p.price.map { glance.money($0) }, p.dateText].compactMap { $0 }.joined(separator: " · "))
            }
            .buttonStyle(.plain)
        }
    }
}

/// A CD, record or download in a list: its label (or medium) and artist, and whether there's music for it.
struct ShelfItemRow: View {
    var item: Glance.Collection.Item

    var body: some View {
        HStack(spacing: 8) {
            WatchCover(name: item.cover, title: item.title, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: ShelfMedium.symbol(item.medium))
                    Text([item.stickerText ?? ShelfMedium.name(item.medium), item.artist].joined(separator: " · "))
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let status = item.noCopyText {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        // Dimmed only when its music exists but isn't on the iPhone; with no digital copy there's nothing to download.
        .opacity(item.digitized == true && item.playable != true ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A collection item: its label, and Play when its songs are on the iPhone.
struct ShelfItemPage: View {
    @Environment(WatchModel.self) private var model
    let item: Glance.Collection.Item

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                WatchCover(name: item.cover, title: item.title, size: 96)
                Text(item.title).font(.headline).multilineTextAlignment(.center)
                Text([item.artist, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Label(item.stickerText ?? ShelfMedium.name(item.medium), systemImage: ShelfMedium.symbol(item.medium))
                    .font(.caption.weight(.semibold))
                if item.playable == true {
                    Button { model.send(.playAlbum(key: item.albumKey)) } label: { Label("Play on iPhone", systemImage: "play.fill") }
                        .tint(.pink)
                } else if item.digitized == false {
                    Text(["No digital copy", item.stickerText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    Text("Not on your iPhone. Download it there to play it.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let message = model.message { Text(message).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .navigationTitle(item.stickerText ?? item.title)
    }
}

// MARK: Find

/// What CD #142 (or Vinyl #12) is, from the shelf index the iPhone sent, so it works while the iPhone is away. The
/// Digital Crown moves through the labels in use; the buttons step by one, through unused numbers too.
struct WatchFindPage: View {
    @Environment(WatchModel.self) private var model
    @State private var index = ShelfSeriesIndex()
    /// What `index` was built from; nil until it's built.
    @State private var indexed: IndexKey?
    @State private var number = 1
    /// The crown's position: an index into `index.numbers`.
    @State private var crown = 0.0
    /// Set when the buttons move the crown, so that move doesn't pick a number in turn.
    @State private var ignoreCrown = false

    /// "cd" or "vinyl", the series last shown.
    private var series: String { model.find.seriesKey }
    private var seriesName: String { series == "vinyl" ? "Vinyl" : "CD" }

    var body: some View {
        Group {
            if let shelf = model.shelf {
                finder
                    .task(id: IndexKey(series: series, generatedAt: shelf.generatedAt)) { rebuild(shelf) }
            } else {
                unavailable
            }
        }
        // The series shown is in the title and on every number (CD #12 and Vinyl #12 are different shelves); the
        // button says what it switches to.
        .navigationTitle(model.shelf == nil ? "Find" : (series == "vinyl" ? "Vinyl" : "CDs"))
        .toolbar {
            if model.shelf != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    // Short, so the watch's toolbar doesn't clip it next to the title.
                    Button(series == "vinyl" ? "CDs" : "Vinyl") {
                        model.setFind(model.find.with(series: series == "vinyl" ? "cd" : "vinyl"))
                    }
                    .accessibilityLabel(series == "vinyl" ? "Showing vinyl; show CDs" : "Showing CDs; show vinyl")
                }
            }
        }
    }

    private struct IndexKey: Hashable {
        var series: String
        var generatedAt: Date
    }

    @ViewBuilder
    private var unavailable: some View {
        if model.glance != nil && model.glance?.collection == nil {
            ContentUnavailableView {
                Label("Update iPhone App", systemImage: "iphone")
            } description: {
                Text("Update Music Library on your iPhone to find your CDs and records by their label here.")
            }
        } else {
            ContentUnavailableView {
                Label("No Labels Yet", systemImage: "number")
            } description: {
                Text("Open Music Library on your iPhone, and your labeled CDs and records come over to the watch.")
            }
        }
    }

    @ViewBuilder
    private var finder: some View {
        if indexed == nil {
            ProgressView()
        } else if index.numbers.isEmpty {
            ScrollView {
                Text("No \(seriesName == "CD" ? "CDs" : "records") have a label yet. Label them in Music Library on your Mac.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 2) {
                    step(-1)
                    VStack(spacing: -2) {
                        Text(seriesName.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("#\(number)")
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(seriesName) label \(number)")
                    step(1)
                }
                .focusable()
                .digitalCrownRotation($crown, from: 0, through: Double(max(index.numbers.count - 1, 1)), by: 1,
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                .onChange(of: crown) { _, value in
                    if ignoreCrown { ignoreCrown = false; return }
                    let i = min(max(Int(value.rounded()), 0), index.numbers.count - 1)
                    if index.numbers[i] != number { select(index.numbers[i], moveCrown: false) }
                }
                result
                Spacer(minLength: 0)
                neighbors
            }
        }
    }

    private func step(_ delta: Int) -> some View {
        Button {
            select(min(max(number + delta, 1), 9_999_999), moveCrown: true)
        } label: {
            Image(systemName: delta < 0 ? "minus.circle" : "plus.circle").font(.title3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Previous number" : "Next number")
    }

    @ViewBuilder
    private var result: some View {
        let hits = index.entries(number)
        if let entry = hits.first {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    WatchCover(name: entry.c, title: entry.t, size: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.t).font(.footnote.weight(.semibold)).lineLimit(2)
                        Text([entry.a, entry.y.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let digitized = entry.d {
                    Text(series == "vinyl" ? (digitized ? "Digitized" : "Not digitized") : (digitized ? "Ripped" : "Not ripped"))
                        .font(.caption2).foregroundStyle(digitized ? .green : .secondary)
                }
                if hits.count > 1 {
                    Text("\(hits.count) items have this label").font(.caption2).foregroundStyle(.orange)
                }
            }
            .task(id: entry.c) {
                // Only for a lookup that stays on screen a moment, not every label the crown passes.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let cover = entry.c else { return }
                model.showShelfCover(cover)
            }
        } else {
            Text("Nothing has this label.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var neighbors: some View {
        let (previous, next) = index.neighbors(number)
        return HStack {
            if let previous {
                Button("← \(seriesName) #\(previous.n)") { select(previous.n, moveCrown: true) }
                    .accessibilityLabel("Previous label, \(seriesName) label \(previous.n), \(previous.t)")
            }
            Spacer(minLength: 4)
            if let next {
                Button("\(seriesName) #\(next.n) →") { select(next.n, moveCrown: true) }
                    .accessibilityLabel("Next label, \(seriesName) label \(next.n), \(next.t)")
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.secondary)
    }

    /// After the series or the shelf changed: the last lookup in the series, else its highest label.
    private func rebuild(_ shelf: GlanceShelf) {
        index = ShelfSeriesIndex(shelf: shelf, series: series)
        indexed = IndexKey(series: series, generatedAt: shelf.generatedAt)
        let last = model.find.last(in: series)
        number = last > 0 ? last : (index.numbers.last ?? 1)
        moveCrown(to: number)
    }

    private func select(_ n: Int, moveCrown move: Bool) {
        number = n
        model.setFind(model.find.with(last: n, in: series))
        if move { moveCrown(to: n) }
    }

    /// Puts the crown on the number (or the label in use just below it) without picking that label instead.
    private func moveCrown(to n: Int) {
        let target = Double(index.position(of: n))
        guard target != crown else { return }
        ignoreCrown = true
        crown = target
    }
}

/// One series of the shelf index, by number, for lookups as fast as the crown turns.
struct ShelfSeriesIndex {
    /// The labels in use, ascending.
    private(set) var numbers: [Int] = []
    private var byNumber: [Int: [GlanceShelf.Entry]] = [:]

    init() {}

    init(shelf: GlanceShelf, series: String) {
        for entry in shelf.entries where entry.s == series { byNumber[entry.n, default: []].append(entry) }
        numbers = byNumber.keys.sorted()
    }

    func entries(_ number: Int) -> [GlanceShelf.Entry] { byNumber[number] ?? [] }

    /// The first position whose number is at least `number`.
    private func insertionPoint(_ number: Int) -> Int {
        var low = 0, high = numbers.count
        while low < high {
            let mid = (low + high) / 2
            if numbers[mid] < number { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The crown position for a number: its own, else the label in use just below it.
    func position(of number: Int) -> Int {
        let i = insertionPoint(number)
        return i < numbers.count && numbers[i] == number ? i : max(0, i - 1)
    }

    /// The labeled items just before and after the number, whether or not it's in use.
    func neighbors(_ number: Int) -> (previous: GlanceShelf.Entry?, next: GlanceShelf.Entry?) {
        let i = insertionPoint(number)
        let previous = i > 0 ? byNumber[numbers[i - 1]]?.first : nil
        let after = i < numbers.count && numbers[i] == number ? i + 1 : i
        let next = after < numbers.count ? byNumber[numbers[after]]?.first : nil
        return (previous, next)
    }
}

// MARK: Pieces

/// How the watch shows a medium. A string from the iPhone, so a newer phone's medium shows as a generic one.
enum ShelfMedium {
    /// The medium as `GlanceFormat.sticker` reads it, so "CD" and " vinyl" show as a CD and a record, like their labels.
    static func kind(_ medium: String) -> String { medium.trimmingCharacters(in: .whitespaces).lowercased() }

    static func symbol(_ medium: String) -> String {
        switch kind(medium) {
        case "cd": "opticaldisc"
        case "vinyl": "record.circle"
        case "download": "arrow.down.circle"
        default: "shippingbox"
        }
    }

    static func name(_ medium: String) -> String {
        switch kind(medium) {
        case "cd": "CD"
        case "vinyl": "Vinyl"
        case "download": "Download"
        default: "Other"
        }
    }
}

extension Glance.Collection.Item {
    /// "On your shelf · no digital copy" for a CD or record whose music isn't in the library; nil otherwise.
    var noCopyText: String? {
        guard digitized == false else { return nil }
        return ShelfMedium.kind(medium) == "download" ? "No digital copy" : "On your shelf · no digital copy"
    }
}

/// Shown when the iPhone's app is older than the watch's.
struct UpdateIPhoneNote: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
}
