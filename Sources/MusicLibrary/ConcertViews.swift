import AppKit
import MusicLibraryCore
import SwiftUI

// MARK: Rows

/// A calendar-page date: "NOV" over "2".
struct ConcertDateTile: View {
    @Environment(\.theme) private var theme
    let day: PurchaseDay

    var body: some View {
        let date = day.date()
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(theme.accent)
            Text(date.formatted(.dateTime.day())).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.subtext)
        }
        .frame(width: 48, height: 56)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
    }
}

/// One concert. With `artist` set, the row leads with that artist (the Concerts page); without, with the venue
/// (an artist's own page, `pageArtist`).
struct ConcertRow: View {
    @Environment(\.theme) private var theme
    let concert: Concert
    let store: ConcertStore
    /// The artist whose page this is, to leave out of "with …".
    let pageArtist: String
    var artistLink: ArtistSummary?
    var showsArtist = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ConcertDateTile(day: concert.day)
            VStack(alignment: .leading, spacing: 2) {
                if showsArtist {
                    HStack(spacing: 6) {
                        if let artistLink {
                            NavigationLink(value: artistLink) { Text(pageArtist).font(.headline) }
                                .buttonStyle(.plain)
                                .help("Show \(pageArtist)")
                        } else {
                            Text(pageArtist).font(.headline)
                        }
                        statusBadge
                    }
                    Text(concert.venue).lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(concert.venue).font(.headline).lineLimit(1)
                        statusBadge
                    }
                }
                Text(details).font(.caption).foregroundStyle(.subtext).lineLimit(1)
                if let extra { Text(extra).font(.caption).foregroundStyle(.subtext).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let price = priceText {
                Text(price).font(.caption).foregroundStyle(.subtext).monospacedDigit()
            }
            if let url = concert.url?.webLink {
                Link(destination: url) {
                    Label(concert.sources.first == .ticketmaster ? "Tickets" : "Details", systemImage: "ticket")
                }
                .buttonStyle(.bordered)
                .help("Open on \(concert.sources.first?.name ?? "the web")")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? theme.fill.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = concert.url?.webLink {
                Link("Open on \(concert.sources.first?.name ?? "the Web")", destination: url)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        .opacity(concert.status == .cancelled ? 0.6 : 1)
    }

    /// "Boston, MA · 3 mi · 7:30 PM"
    private var details: String {
        [concert.place, store.distance(concert.distanceKm), concert.formattedTime()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tour or festival, or who else is playing.
    private var extra: String? {
        if let title = concert.title(for: pageArtist) { return title }
        let others = concert.otherActs(than: pageArtist)
        guard !others.isEmpty else { return nil }
        let shown = others.prefix(3)
        return "with " + ListFormatter.localizedString(byJoining: Array(shown)) + (others.count > 3 ? " and more" : "")
    }

    private var priceText: String? {
        guard let price = concert.minPrice, price > 0, let currency = concert.currency else { return nil }
        return "from " + price.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }

    @ViewBuilder
    private var statusBadge: some View {
        let label: String? = switch concert.status {
        case .cancelled: "Cancelled"
        case .postponed: "Postponed"
        case .rescheduled: "Rescheduled"
        case .scheduled: nil
        }
        if let label {
            Text(label).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
                .foregroundStyle(.orange)
        }
    }
}

/// "Concert listings from Ticketmaster and JamBase", linking to each (JamBase's free plan asks for credit).
struct ConcertAttribution: View {
    let sources: [ConcertSource]

    var body: some View {
        if !sources.isEmpty {
            HStack(spacing: 4) {
                Text("Concert listings from").foregroundStyle(.subtext)
                ForEach(Array(sources.enumerated()), id: \.element) { i, s in
                    if i > 0 { Text(i == sources.count - 1 ? "and" : ",").foregroundStyle(.subtext) }
                    Link(s.name, destination: s.homepage)
                }
            }
            .font(.caption)
        }
    }
}

// MARK: Artist page

/// Upcoming concerts near home on an artist's page.
struct ArtistConcertsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let artist: String
    let mbid: String?
    @State private var showAll = false

    var body: some View {
        let store = model.concerts
        if store.showsOnArtistPages, !artist.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Concerts Near You")
                    if store.isConfigured {
                        Text(store.areaDescription).font(.callout).foregroundStyle(.subtext)
                    }
                    Spacer()
                    if store.isConfigured {
                        Button { store.load(artist: artist, mbid: mbid, force: true) } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.link)
                        .disabled(store.isLoading(artist))
                    }
                }
                content(store)
            }
            .task(id: "\(artist)|\(store.isConfigured)|\(store.areaDescription)") {
                store.load(artist: artist, mbid: mbid)
            }
        }
    }

    @ViewBuilder
    private func content(_ store: ConcertStore) -> some View {
        if !store.isConfigured {
            HStack(spacing: 10) {
                Image(systemName: "ticket").foregroundStyle(.subtext)
                Text(store.home == nil
                     ? "Add your \(store.codeName) and a free concert listings key to see when artists play near you."
                     : "Add a free Ticketmaster or JamBase key to see when artists play near you.")
                    .foregroundStyle(.subtext)
                Spacer()
                SettingsLink { Text("Open Settings…") }
            }
            .font(.callout)
        } else if let found = store.concerts(for: artist) {
            let concerts = found.concerts
            if concerts.isEmpty {
                Text(store.isLoading(artist) ? "Checking for new dates…" : "No upcoming concerts \(store.areaDescription).")
                    .font(.callout).foregroundStyle(.subtext)
            } else {
                let shown = showAll ? concerts : Array(concerts.prefix(5))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                        ConcertRow(concert: c, store: store, pageArtist: artist)
                        if i < shown.count - 1 { Divider().opacity(0.5) }
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
                if concerts.count > 5 {
                    Button(showAll ? "Show Fewer" : "Show All \(concerts.count) Concerts") { withAnimation(.snappy) { showAll.toggle() } }
                        .buttonStyle(.link)
                }
            }
            footer(found, store)
        } else if store.isLoading(artist) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for concerts \(store.areaDescription)…").font(.callout).foregroundStyle(.subtext)
            }
        }
        if let error = store.error(for: artist) {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        ForEach(store.warnings(for: artist), id: \.self) { w in
            Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func footer(_ found: NearbyConcerts, _ store: ConcertStore) -> some View {
        HStack(spacing: 14) {
            if found.elsewhereCount > 0 {
                Text("\(found.elsewhereCount) more show\(found.elsewhereCount == 1 ? "" : "s") farther away")
                    .foregroundStyle(.subtext)
            }
            ForEach(found.bySource.filter { $0.artistURL?.webLink != nil }, id: \.source) { s in
                Link("All dates on \(s.source.name)", destination: s.artistURL!)
            }
            Spacer()
            ConcertAttribution(sources: found.bySource.map(\.source))
        }
        .font(.caption)
    }
}

// MARK: Concerts page

/// Upcoming concerts near home by artists in the library.
struct ConcertsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var filter = ""
    @AppStorage("concertsListenedOnly") private var listenedOnly = false

    var body: some View {
        let store = model.concerts
        let items = shownItems(store)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.isConfigured {
                    header(store, count: items.count)
                    ForEach(months(items), id: \.title) { month in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(month.title).font(.title3.bold())
                            VStack(spacing: 0) {
                                ForEach(Array(month.items.enumerated()), id: \.element.id) { i, item in
                                    ConcertRow(concert: item.concert, store: store, pageArtist: item.artist,
                                               artistLink: model.artistSummary(named: item.artist), showsArtist: true)
                                    if i < month.items.count - 1 { Divider().opacity(0.5) }
                                }
                            }
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
                        }
                    }
                    if let scan = store.scan, !items.isEmpty { ConcertAttribution(sources: scan.sources) }
                }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay { emptyState(store, items: items) }
        .navigationTitle("Concerts")
        .navigationSubtitle(store.isConfigured ? "Your artists \(store.areaDescription)" : "")
        .toolbar {
            ToolbarItem {
                Button { store.scanLibrary(model.concertArtists(), force: true) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!store.isConfigured || store.isScanning)
                .help("Look for new concerts")
            }
        }
        .task(id: "\(store.isConfigured)|\(store.areaDescription)|\(model.libraryVersion)") {
            store.scanLibrary(model.concertArtists())
        }
    }

    private func header(_ store: ConcertStore, count: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.subtext)
                TextField("Filter artists, venues, cities", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.subtext)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.fill))
            .frame(maxWidth: 300)
            Picker("Artists", selection: $listenedOnly) {
                Text("All Artists").tag(false)
                Text("Artists I've Played").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            status(store)
        }
    }

    @ViewBuilder
    private func status(_ store: ConcertStore) -> some View {
        if store.isScanning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for concerts…").font(.caption).foregroundStyle(.subtext)
            }
        } else if let error = store.scanError {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1).help(error)
        } else if let warning = store.scanWarnings.first {
            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                .help(store.scanWarnings.joined(separator: "\n"))
        } else if let scan = store.scan {
            Text("Updated \(scan.scannedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.subtext)
        }
    }

    @ViewBuilder
    private func emptyState(_ store: ConcertStore, items: [ArtistConcert]) -> some View {
        if !store.isConfigured {
            ContentUnavailableView {
                Label("Concerts Near You", systemImage: "ticket")
            } description: {
                Text("See when artists in your library play near you. Add your \(store.codeName.lowercased()) and a free Ticketmaster or JamBase key in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else if items.isEmpty, let scan = store.scan, !store.isScanning {
            if scan.items.isEmpty {
                ContentUnavailableView("No Upcoming Concerts", systemImage: "ticket",
                                       description: Text("None of your artists have concerts \(store.areaDescription) yet."))
            } else {
                ContentUnavailableView.search(text: filter)
            }
        } else if store.scan == nil, store.isScanning {
            ProgressView("Looking for concerts \(store.areaDescription)…")
        }
    }

    private func shownItems(_ store: ConcertStore) -> [ArtistConcert] {
        var items = store.scan?.items ?? []
        let today = PurchaseDay(Date())
        items.removeAll { $0.concert.day < today }
        if listenedOnly {
            items = items.filter { (model.artistPlayTotals[ArtistInfoStore.key($0.artist)]?.plays ?? 0) > 0 }
        }
        let q = TextNormalizer.normalize(filter)
        if !q.isEmpty {
            items = items.filter { i in
                let c = i.concert
                return TextNormalizer.normalize([i.artist, c.venue, c.place, c.name].joined(separator: " ")).contains(q)
            }
        }
        return items
    }

    private func months(_ items: [ArtistConcert]) -> [(title: String, items: [ArtistConcert])] {
        var groups: [(title: String, items: [ArtistConcert])] = []
        for item in items {
            let title = item.concert.day.date().formatted(.dateTime.month(.wide).year())
            if groups.last?.title == title { groups[groups.count - 1].items.append(item) } else { groups.append((title, [item])) }
        }
        return groups
    }
}

// MARK: Settings

struct ConcertSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.concerts
        Form {
            Section {
                Text("See upcoming concerts near you on artist pages, and every artist in your library on the Concerts page.")
                    .font(.callout).foregroundStyle(.subtext)
            }
            Section("Where you live") {
                PostalCodeField(store: store)
                LabeledContent("Location") { locationStatus(store) }
                Picker("Distance", selection: $store.radius) {
                    ForEach(ConcertStore.radiusChoices, id: \.self) { Text("Within \($0) \(store.unit.abbreviation)").tag($0) }
                }
            }
            Section {
                keyField("Ticketmaster Consumer Key", text: $store.ticketmasterKey, source: .ticketmaster,
                         note: "Arenas, theaters and larger clubs. Free: in your Ticketmaster developer account, open your app and copy its Consumer Key (the Consumer Secret isn't needed).")
                keyField("JamBase API key", text: $store.jambaseKey, source: .jambase,
                         note: "Venue calendars, including small clubs and independent venues: better for smaller bands. Free for personal use (1,000 requests a month).")
            } header: {
                Text("Concert listings")
            } footer: {
                Text("Use either or both; shows listed by both appear once. Keys are stored in your keychain on this Mac. Results are saved for a day (two for the whole library) to stay within the free limits.")
                    .font(.caption).foregroundStyle(.subtext)
            }
            Section("Artist pages") {
                Toggle("Show upcoming concerts on artist pages", isOn: $store.showsOnArtistPages)
            }
        }
        .formStyle(.grouped)
        .themedScrollBackground()
        .frame(height: 600)
    }

    @ViewBuilder
    private func locationStatus(_ store: ConcertStore) -> some View {
        if store.isLocating {
            HStack { ProgressView().controlSize(.small); Text("Looking up…").foregroundStyle(.subtext) }
        } else if let error = store.locationError {
            Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else if let home = store.home {
            Label(home.place, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text("Not set").foregroundStyle(.subtext)
        }
    }

    private func keyField(_ title: String, text: Binding<String>, source: ConcertSource, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(text: text) { Text(title).font(.body) }
                .font(.system(.body, design: .monospaced))
            HStack(alignment: .firstTextBaseline) {
                Text(note).font(.caption).foregroundStyle(.subtext)
                Spacer()
                Link("Get a key", destination: source.signupURL).font(.caption)
            }
        }
    }
}

/// The ZIP code, looked up when you press Return or leave the field (not on every keystroke).
private struct PostalCodeField: View {
    let store: ConcertStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(store.codeName, text: $draft, prompt: Text(store.country == "US" ? "02139" : ""))
            .focused($focused)
            .onSubmit { store.applyPostalCode(draft) }
            .onChange(of: focused) { _, isFocused in if !isFocused { store.applyPostalCode(draft) } }
            .onAppear { draft = store.postalCode }
    }
}
