import MusicLibraryCore
import SwiftUI

// MARK: Routes

/// Music DNA centered on someone (nil: the starting page). Each person opened is pushed, so Back goes to the last.
struct DNARoute: Hashable {
    var name: String?
}

/// Songs, albums and artists matching a query in the app's search language (from Insights, genre chips…).
struct QueryRoute: Hashable {
    var query: String
    /// Shown instead of the query.
    var title: String?
}

/// Pushes a page onto the current tab's navigation stack (for menus and taps that can't be `NavigationLink`s).
struct OpenRouteAction {
    let open: (any Hashable) -> Void
    func callAsFunction(_ value: some Hashable) { open(value) }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
}

/// A tab's navigation stack, with library pages and `openRoute` wired up.
struct LibraryStack<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root().libraryDestinations()
        }
        .environment(\.openRoute, OpenRouteAction { value in path.append(value) })
    }
}

// MARK: Formatting

func formatLongDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return Format.time(seconds) }
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
    f.unitsStyle = .short
    f.maximumUnitCount = 2
    return f.string(from: seconds) ?? Format.time(seconds)
}

/// Listening time: "—" for none, "52 sec" under a minute, then "3 hr, 12 min".
func formatListened(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 1 else { return "—" }
    return seconds < 60 ? "\(Int(seconds)) sec" : formatLongDuration(seconds)
}

func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n.formatted()) songs" }

func playCount(_ n: Int) -> String { n == 1 ? "1 play" : "\(n.formatted()) plays" }

/// Prices are entered and shown in the currency of the user's locale.
let currencyCode = Locale.current.currency?.identifier ?? "USD"

func formatMoney(_ amount: Decimal, whole: Bool = false) -> String {
    amount.formatted(.currency(code: currencyCode).precision(.fractionLength(whole ? 0 : 2)))
}

func countryName(_ code: String) -> String {
    if code.uppercased() == "XW" { return "Worldwide" }
    if code.uppercased() == "XE" { return "Europe" }
    return Locale.current.localizedString(forRegionCode: code) ?? code
}

// MARK: Layout

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

struct SectionHeader: View {
    let title: String
    var body: some View { Text(title).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading) }
}

extension View {
    /// A rounded card on the page background.
    func card(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// A big number with a label.
struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Two columns of stat tiles.
struct StatGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10, content: content)
    }
}

// MARK: Chips and links

/// A capsule that opens a search (genres, labels…).
struct QueryChip: View {
    let text: String
    let query: String

    var body: some View {
        NavigationLink(value: QueryRoute(query: query, title: text)) {
            Text(text).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }
}

/// Genre capsules that search the library.
struct GenreChips: View {
    let genres: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(genres, id: \.self) { g in QueryChip(text: g.capitalized, query: SearchFilterKey.token("genre", g)) }
        }
    }
}

/// Web links as capsules. Only http(s) links with a host are shown (they come from community-edited sources).
struct LinkChips: View {
    let links: [ArtistLink]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(links.filter(\.url.isWebLink)) { link in
                Link(destination: link.url) {
                    Label(link.title, systemImage: Self.icon(link.kind))
                        .font(.callout)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func icon(_ kind: ArtistLink.Kind) -> String {
        switch kind {
        case .official: "globe"
        case .wikipedia, .wikidata: "book"
        case .review: "quote.bubble"
        case .rateyourmusic: "star"
        case .genius: "text.quote"
        case .lastfm: "dot.radiowaves.left.and.right"
        case .bandcamp, .spotify, .appleMusic, .tidal, .deezer, .soundcloud: "music.note"
        case .youtube: "play.rectangle"
        case .instagram, .tiktok: "camera"
        case .twitter, .facebook, .bluesky: "bubble.left"
        case .discogs, .allmusic, .musicbrainz: "opticaldisc"
        case .setlistfm, .songkick, .bandsintown: "ticket"
        case .imdb: "film"
        }
    }
}

/// A person's name that opens their Music DNA.
struct PersonLink: View {
    let name: String

    var body: some View {
        NavigationLink(value: DNARoute(name: name)) {
            Text(name).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

/// Several names as links, separated by commas, wrapping as needed.
struct PersonLinks: View {
    let names: [String]

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 0) {
                    PersonLink(name: name)
                    if i < names.count - 1 { Text(", ") }
                }
            }
        }
    }
}

/// Five stars with halves, plus the vote count.
struct RatingView: View {
    let rating: Double
    let votes: Int

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0..<5) { i in
                    let fill = rating - Double(i)
                    Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                }
            }
            .foregroundStyle(Color.accentColor)
            Text(String(format: "%.1f", rating)).monospacedDigit().fontWeight(.semibold)
            Text("· \(votes) MusicBrainz rating\(votes == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

/// Text that shows a few lines with Read More, and where it came from.
struct ExpandableText: View {
    let text: String
    var lines = 6
    var source: String?
    var sourceURL: URL?
    var credit: (label: String, url: URL?)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).lineSpacing(3).lineLimit(expanded ? nil : lines).textSelection(.enabled)
            HStack(spacing: 14) {
                if text.count > 300 {
                    Button(expanded ? "Show Less" : "Read More") { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.callout.weight(.medium))
                }
                if let source {
                    if let url = sourceURL?.webLink { Link("From \(source)", destination: url).font(.caption) }
                    else { Text("From \(source)").font(.caption).foregroundStyle(.secondary) }
                }
                if let credit {
                    if let url = credit.url?.webLink { Link("Photo: \(credit.label)", destination: url).font(.caption) }
                    else { Text("Photo: \(credit.label)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

// MARK: Artists

/// An artist's photo (the one chosen on the Mac, else the downloaded one), or their initials.
struct ArtistPhoto: View {
    @Environment(PhoneModel.self) private var model
    let name: String
    var size: CGFloat = 120

    var body: some View {
        let url = model.library?.artistImageURL(name)
        ZStack {
            InitialsBadge(name: name, size: size)
            if url != nil { PhotoImage(url: url, size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// An image file decoded off the main thread, filling a square; nothing until it loads (or if it can't).
struct PhotoImage: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await CoverLoader.image(at: url, maxPixel: size * scale)
        }
    }
}

struct InitialsBadge: View {
    let name: String
    var size: CGFloat = 76

    var body: some View {
        // "Rachael & Vilray" → "RV": skip words without letters.
        let initials = name.split(separator: " ").filter { $0.contains(where: \.isLetter) }.prefix(2)
            .compactMap { $0.first(where: \.isLetter) }.map(String.init).joined()
        ZStack {
            Circle().fill(Color(.tertiarySystemFill))
            if initials.isEmpty {
                Image(systemName: "music.mic").font(.system(size: size / 3)).foregroundStyle(.secondary)
            } else {
                Text(initials.uppercased()).font(.system(size: size / 3, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A count in a tinted capsule, at the end of a Library row.
struct CountPill: View {
    let count: Int
    var tint: Color = .accentColor

    var body: some View {
        Text(count.formatted())
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: Availability

/// A small mark for an album or song that isn't (all) on the phone, or is on its way.
struct AvailabilityMark: View {
    let availability: PhoneModel.Availability
    var pending = false

    var body: some View {
        Group {
            if pending {
                Image(systemName: "arrow.down.circle.dotted").foregroundStyle(Color.accentColor).accessibilityLabel("Waiting to download")
            } else {
                switch availability {
                case .onPhone, .empty: EmptyView()
                case .partial: Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).accessibilityLabel("Partly on this iPhone")
                case .notOnPhone: Image(systemName: "icloud").foregroundStyle(.secondary).accessibilityLabel("Not on this iPhone")
                }
            }
        }
        .font(.caption)
    }
}

/// What's on the phone, and Download / Remove from iPhone for an album, artist or list. Removing asks first.
struct AvailabilityBar: View {
    @Environment(PhoneModel.self) private var model
    let item: ExportItem
    let tracks: [Track]
    /// "album", "artist", "playlist"…
    let noun: String
    @State private var confirmRemove = false

    var body: some View {
        let availability = model.availability(tracks)
        let pending = model.isDownloadPending(tracks)
        let sync = model.sync
        HStack(spacing: 12) {
            Image(systemName: icon(availability, pending)).font(.title3)
                .foregroundStyle(pending ? Color.accentColor : (availability == .onPhone ? Color.green : Color.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(availability, pending)).font(.subheadline.weight(.semibold))
                if let detail = detail(availability, pending, sync: sync) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if availability != .onPhone && availability != .empty && !pending {
                Button { model.download(item) } label: { Label("Download", systemImage: "arrow.down") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!sync.isPaired)
            }
            if availability != .notOnPhone && availability != .empty {
                Menu {
                    Button("Remove from iPhone", systemImage: "trash", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("More")
            }
        }
        .padding(12)
        .card()
        .confirmationDialog("Remove this \(noun) from the iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from iPhone", role: .destructive) { model.remove(item) }
        } message: {
            Text("Its songs are deleted from this iPhone and the Mac stops syncing them. It stays in your library, and you can download it again.")
        }
    }

    private func icon(_ a: PhoneModel.Availability, _ pending: Bool) -> String {
        if pending { return "arrow.down.circle.dotted" }
        switch a {
        case .onPhone: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .notOnPhone, .empty: return "icloud"
        }
    }

    private func title(_ a: PhoneModel.Availability, _ pending: Bool) -> String {
        if pending { return "Waiting to download" }
        switch a {
        case .onPhone: return "On this iPhone"
        case .partial(let present, let total): return "\(present) of \(songCount(total)) on this iPhone"
        case .notOnPhone, .empty: return "Not on this iPhone"
        }
    }

    private func detail(_ a: PhoneModel.Availability, _ pending: Bool, sync: PhoneSync) -> String? {
        if !sync.isPaired { return a == .onPhone ? nil : "Pair with your Mac in the Sync tab to download music." }
        if pending {
            if case .syncing = sync.status { return "Syncing with \(sync.macName ?? "the Mac")…" }
            return sync.macPeer == nil ? "Starts when \(sync.macName ?? "your Mac") is on the same Wi-Fi with Music Library open." : "Starting…"
        }
        return nil
    }
}

/// Download or Remove for one song's menu.
struct SongAvailabilityButtons: View {
    @Environment(PhoneModel.self) private var model
    let track: Track

    var body: some View {
        if model.isPresent(track) {
            Button("Remove from iPhone", systemImage: "trash", role: .destructive) { model.remove(.track(track.id)) }
        } else if !model.pendingDownloads.contains(track.id) {
            Button("Download to iPhone", systemImage: "arrow.down.circle") { model.download(.track(track.id)) }
                .disabled(!model.sync.isPaired)
        }
    }
}
