import AppKit
import MusicLibraryCore
import SwiftUI

/// What Add to Collection… starts from when it's opened for something in particular (a library CD's catalog page, a
/// shop listing, an album page): the search to run, and what's already known about the release.
struct CollectionPrefill: Hashable {
    /// "Artist and album, or barcode", as typed in the sheet's search field.
    var query = ""
    var album: String?
    var artist: String?
    var releaseID: String?
    var releaseGroupID: String?
    var barcode: String?
    var catalogNumber: String?

    /// What to search for: the query, else the barcode, else the artist and album.
    var searchText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return query }
        if let barcode, !barcode.isEmpty { return barcode }
        return [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: Edition search

/// A MusicBrainz search for the edition you own (`MusicBrainzClient.searchEditions`: a barcode, else words of the
/// artist and album, then a catalog number), run only when asked (Return or Search).
@MainActor @Observable
final class EditionSearch {
    var text = ""
    private(set) var results: [CollectionEdition] = []
    private(set) var searching = false
    private(set) var message: String?
    /// The text and medium the results are for.
    private(set) var searched: (text: String, medium: CollectionMedium)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Small Cover Art Archive fronts, by release; nil once known to have none.
    private(set) var thumbnails: [String: Data?] = [:]

    var isCurrent: Bool { searched?.text == text.trimmingCharacters(in: .whitespaces) }

    func run(_ client: MusicBrainzClient, medium: CollectionMedium, done: @escaping @MainActor ([CollectionEdition]) -> Void = { _ in }) {
        let query = CollectionReleaseQuery(text: text.trimmingCharacters(in: .whitespaces), medium: medium)
        guard !query.isEmpty else { return }
        task?.cancel()
        searching = true
        message = nil
        task = Task {
            do {
                let found = try await client.searchEditions(query)
                guard !Task.isCancelled else { return }
                results = found
                searched = (query.text, medium)
                message = found.isEmpty ? "Nothing found on MusicBrainz. Try other words, or enter it yourself." : nil
                searching = false
                done(found)
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searched = (query.text, medium)
                message = "Search failed: \(error.localizedDescription)"
                searching = false
            }
        }
    }

    func clear() {
        task?.cancel()
        text = ""
        results = []
        searched = nil
        message = nil
        searching = false
    }

    func loadThumbnail(_ edition: CollectionEdition, client: CoverArtClient) async {
        guard thumbnails[edition.id] == nil else { return }
        let data = try? await client.fetchFront(releaseId: edition.id, releaseGroupId: nil, size: 250)
        thumbnails[edition.id] = .some(data.flatMap { NSImage(data: $0) != nil ? $0 : nil })
    }

    /// The results by release group, in the order MusicBrainz ranked them.
    var groups: [(id: String, title: String, artist: String, editions: [CollectionEdition])] {
        var order: [String] = []
        var byGroup: [String: [CollectionEdition]] = [:]
        for e in results {
            if byGroup[e.groupKey] == nil { order.append(e.groupKey) }
            byGroup[e.groupKey, default: []].append(e)
        }
        return order.compactMap { key in
            guard let editions = byGroup[key], let first = editions.first else { return nil }
            return (key, first.releaseGroupTitle.isEmpty ? first.title : first.releaseGroupTitle, first.artist, editions)
        }
    }
}

/// The search field and its results grouped by album, each edition with its cover and "year · country · record
/// label · cat. no. · media · barcode".
struct EditionResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Bindable var search: EditionSearch
    let medium: CollectionMedium
    @Binding var selection: String?
    var focused: FocusState<Bool>.Binding
    /// Return in the field with the results already for its text.
    var submitCurrent: () -> Void = {}
    var onResults: @MainActor ([CollectionEdition]) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $search.text, prompt: Text("Artist and album, or barcode"))
                    .textFieldStyle(.roundedBorder)
                    .focused(focused)
                    .onSubmit {
                        if search.isCurrent, search.searched?.medium == medium, selection != nil, !search.results.isEmpty {
                            submitCurrent()
                        } else {
                            run()
                        }
                    }
                Button("Search", action: run)
                    .disabled(search.searching || search.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(selection: $selection) {
                ForEach(search.groups, id: \.id) { group in
                    Section {
                        ForEach(group.editions) { e in row(e).tag(e.id) }
                    } header: {
                        Text("\(group.title) — \(group.artist)").lineLimit(1)
                    }
                }
            }
            .overlay {
                if search.searching {
                    ProgressView("Searching MusicBrainz…")
                } else if let message = search.message {
                    Text(message).foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
                } else if search.results.isEmpty {
                    Text(medium == .download ? "Search for the album, or type its barcode."
                         : "Search for the \(medium == .cd ? "CD" : "record"), or scan its barcode.")
                        .foregroundStyle(.subtext).multilineTextAlignment(.center).padding()
                }
            }
        }
    }

    private func run() {
        selection = nil
        search.run(model.musicBrainz, medium: medium, done: onResults)
    }

    private func row(_ e: CollectionEdition) -> some View {
        HStack(spacing: 10) {
            DataImage(data: search.thumbnails[e.id] ?? nil, size: 40)
                .task(id: e.id) { await search.loadThumbnail(e, client: model.coverArt) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).lineLimit(1)
                    if !e.status.isEmpty, e.status != "Official" {
                        Text(e.status).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
                    }
                }
                Text(Self.detail(e)).font(.caption).foregroundStyle(.subtext).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let owned = model.collection.matches(releaseID: e.id, releaseGroupID: nil, albumKey: nil, barcode: nil, medium: nil).first {
                Text(owned.sticker?.text ?? "Yours").font(.caption.weight(.medium)).foregroundStyle(.subtext)
                    .help("Already in your collection")
            }
        }
        .padding(.vertical, 2)
    }

    /// "1959 · US · Columbia · CL 1355 · 12″ Vinyl · 074646493525".
    static func detail(_ e: CollectionEdition) -> String {
        [e.year.map(String.init), e.country, e.recordLabel, e.catalogNumber, e.formatDetail, e.barcode]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Add to Collection

/// Add to Collection… (⇧⌘N): pick the medium, find the edition on MusicBrainz (by barcode, or artist and album) or
/// enter it yourself, then the label and purchase details. Add saves it and opens its page; Add & Next saves it and
/// starts over with the next label, for going through a stack of CDs or records (a barcode scanner's Return picks a
/// single match, and the next Return adds it).
struct AddToCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// Nil: the medium last used.
    let medium: CollectionMedium?
    let prefill: CollectionPrefill?

    struct Manual {
        var album = ""
        var artist = ""
        var year = ""
        var recordLabel = ""
        var catalogNumber = ""
        var barcode = ""
        var formatDetail = ""
    }

    @AppStorage("addCollectionMedium") private var lastMedium = "cd"
    @State private var chosenMedium: CollectionMedium = .cd
    @State private var search = EditionSearch()
    @State private var selection: String?
    @State private var manualEntry = false
    @State private var manual = Manual()
    @State private var number: Int?
    @State private var purchasedOn: PurchaseDay? = PurchaseDay(Date())
    @State private var price: Decimal?
    @State private var notes = ""
    @State private var link = true
    /// The library album the item would be linked to, and whether that's a sure match (same key, release or release
    /// group) rather than one by title.
    @State private var libraryMatch: (album: AlbumSummary, sure: Bool)?
    @State private var cover: Data?
    @State private var coverSource: String?
    /// The cover is one the user chose (not the Cover Art Archive's), so it's kept whatever is linked.
    @State private var ownCover = false
    @State private var loadingCover = false
    @State private var coverDropTargeted = false
    @State private var added = 0
    @State private var message: String?
    @FocusState private var searchFocused: Bool

    init(medium: CollectionMedium? = nil, prefill: CollectionPrefill? = nil) {
        self.medium = medium
        self.prefill = prefill
    }

    private var edition: CollectionEdition? {
        guard let selection else { return nil }
        return search.results.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add to Collection").font(.title2.bold())
                Spacer()
                Picker("Medium", selection: $chosenMedium) {
                    ForEach(CollectionMedium.known, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    if manualEntry {
                        manualFields
                    } else {
                        EditionResults(search: search, medium: chosenMedium, selection: $selection, focused: $searchFocused,
                                       submitCurrent: { add(next: true) }, onResults: autoSelect)
                    }
                    Button(manualEntry ? "Search MusicBrainz Instead" : "Not on MusicBrainz? Enter it yourself") {
                        manualEntry.toggle()
                        selection = nil
                        updateMatch()
                    }
                    .buttonStyle(.link).font(.callout)
                }
                .frame(width: 440)
                Divider()
                details.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 900, height: 620)
        .onAppear(perform: start)
        .onChange(of: chosenMedium) { old, new in
            lastMedium = new.rawValue
            if old.series != new.series { number = new.series.map { model.nextNumber(in: $0) } }
            // MusicBrainz is searched by format: the same words again, for the other medium.
            if !manualEntry, search.searched != nil, search.searched?.medium != new {
                selection = nil
                search.run(model.musicBrainz, medium: new, done: autoSelect)
            }
            updateMatch()
        }
        .onChange(of: selection) { pickEdition() }
        // Looking for the library album goes over every song: not on each keystroke.
        .task(id: "\(manual.album)\u{1}\(manual.artist)") {
            guard manualEntry else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { updateMatch() }
        }
    }

    // MARK: Manual

    private var manualFields: some View {
        Form {
            TextField("Album", text: $manual.album)
            TextField("Artist", text: $manual.artist)
            TextField("Year", text: $manual.year)
            TextField("Record label", text: $manual.recordLabel)
            TextField("Cat. No.", text: $manual.catalogNumber)
            TextField("Barcode", text: $manual.barcode)
            TextField("Media", text: $manual.formatDetail, prompt: Text(chosenMedium == .vinyl ? "12\" Vinyl" : "CD"))
        }
        .formStyle(.grouped)
    }

    // MARK: Details

    @ViewBuilder
    private var details: some View {
        if let draft = makeItem(numbered: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        coverWell(draft)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.album.isEmpty ? "Unknown Album" : draft.album).font(.headline).lineLimit(3)
                            Text(draft.artist).foregroundStyle(.subtext).lineLimit(2)
                            if let e = edition { Text(EditionResults.detail(e)).font(.caption).foregroundStyle(.subtext).lineLimit(3) }
                        }
                    }
                    alreadyOwned(draft)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        if let series = chosenMedium.series {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Label").foregroundStyle(.subtext)
                                StickerField(series: series, number: $number, live: true)
                            }
                        }
                        GridRow {
                            Text("Bought").foregroundStyle(.subtext)
                            PurchaseDateField(day: $purchasedOn)
                        }
                        GridRow {
                            Text("Paid").foregroundStyle(.subtext)
                            PurchasePriceField(price: $price)
                        }
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Notes").foregroundStyle(.subtext)
                            TextField("Notes", text: $notes, prompt: Text("Where you got it, its condition…"), axis: .vertical)
                                .textFieldStyle(.roundedBorder).labelsHidden().lineLimit(1...4)
                        }
                    }
                    .font(.callout)
                    if let match = libraryMatch {
                        Toggle(isOn: $link) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link to “\(match.album.album)” in your library (\(songCount(match.album.trackCount)))")
                                if !match.sure {
                                    Text("Matched by title and artist\(match.album.artist.isEmpty ? "" : " (\(match.album.artist))"): check it's the same album")
                                        .font(.caption).foregroundStyle(.subtext)
                                }
                            }
                        }
                        .help(Self.linkHelp(chosenMedium))
                    }
                }
            }
        } else {
            Text(manualEntry ? "Type at least the album or the artist." : "Pick the edition you own.")
                .foregroundStyle(.subtext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func linkHelp(_ medium: CollectionMedium) -> String {
        switch medium {
        case .cd: "Its songs are your rip of this CD"
        case .download: "Its songs are this download"
        case .vinyl, .other: "Its songs are the same music (it shows as digitized from elsewhere)"
        }
    }

    /// Copies you already have of this release or album.
    @ViewBuilder
    private func alreadyOwned(_ draft: CollectionItem) -> some View {
        let owned = model.collection.matches(releaseID: draft.releaseID, releaseGroupID: nil, albumKey: draft.albumKey,
                                             barcode: draft.barcode, medium: nil)
        if !owned.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.subtext)
                Text("Already in your collection:").foregroundStyle(.subtext)
                ForEach(owned.prefix(3)) { item in
                    if let s = item.sticker { StickerPill(sticker: s, size: 10) } else { Text(item.medium.name) }
                }
            }
            .font(.callout)
        }
    }

    private func coverWell(_ draft: CollectionItem) -> some View {
        let linkedCover = link ? libraryMatch.flatMap { model.coverURL(forAlbum: $0.album) } : nil
        return VStack(spacing: 6) {
            Group {
                if cover == nil, let linkedCover {
                    CoverThumb(url: linkedCover, size: 120, revision: model.coverRevision)
                } else {
                    DataImage(data: cover, size: 120)
                }
            }
            .overlay {
                if loadingCover { ProgressView().controlSize(.small) }
                if coverDropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent, lineWidth: 3) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await load(url) }
                return true
            } isTargeted: { coverDropTargeted = $0 }
            HStack(spacing: 4) {
                Button("Choose…", action: chooseCover)
                Button("Paste", action: pasteCover)
            }
            .controlSize(.mini)
            Text(coverSource ?? (linkedCover != nil && cover == nil ? "The album's cover" : "Drop an image"))
                .font(.caption2).foregroundStyle(.subtext).lineLimit(1)
        }
        .frame(width: 124)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).lineLimit(2)
            } else if added > 0 {
                Text("Added \(added)\(chosenMedium.series.map { " · next \($0.name) #\(model.nextNumber(in: $0))" } ?? "")")
                    .font(.callout).foregroundStyle(.subtext)
            }
            Spacer()
            Button(added > 0 ? "Done" : "Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add & Next") { add(next: true) }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(makeItem(numbered: true) == nil)
                .help("Add it and start on the next one (⌥⌘↩)")
            Button("Add") { add(next: false) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(makeItem(numbered: true) == nil)
                .help("Add it and open its page (⌘↩)")
        }
    }

    // MARK: Actions

    private func start() {
        chosenMedium = medium ?? CollectionMedium(rawValue: lastMedium).flatMap { CollectionMedium.known.contains($0) ? $0 : nil } ?? .cd
        number = chosenMedium.series.map { model.nextNumber(in: $0) }
        searchFocused = true
        guard let prefill else { return }
        search.text = prefill.searchText
        manual.album = prefill.album ?? ""
        manual.artist = prefill.artist ?? ""
        manual.barcode = prefill.barcode ?? ""
        manual.catalogNumber = prefill.catalogNumber ?? ""
        if !search.text.isEmpty {
            search.run(model.musicBrainz, medium: chosenMedium) { found in
                if let id = prefill.releaseID, found.contains(where: { $0.id == id }) { selection = id } else { autoSelect(found) }
            }
        }
    }

    /// A barcode with one edition: picked, so Return (from a scanner) adds it.
    private func autoSelect(_ found: [CollectionEdition]) {
        if CollectionReleaseQuery(text: search.text, medium: chosenMedium).barcode != nil, found.count == 1 {
            selection = found[0].id
        }
    }

    private func pickEdition() {
        message = nil
        if !ownCover { cover = nil; coverSource = nil }
        updateMatch()
        guard let e = edition, !ownCover else { return }
        loadingCover = true
        let id = e.id, group = e.releaseGroupId
        Task {
            defer { if selection == id { loadingCover = false } }
            for size in [1200, 500] {
                if let data = try? await model.coverArt.fetchFront(releaseId: id, releaseGroupId: group, size: size),
                   NSImage(data: data) != nil {
                    guard selection == id, !ownCover else { return }
                    cover = data
                    coverSource = "Cover Art Archive"
                    return
                }
            }
        }
    }

    /// The library album this copy's songs would be, if any: under its key, else tagged with its release or release
    /// group (sure), else one with its title by a compatible artist (offered, not linked unless asked).
    private func updateMatch() {
        let before = libraryMatch.map { AlbumInfoStore.key($0.album) }
        defer {
            // On whenever a library album matches (§4.1), each time it's another album; a match by name only says so
            // next to the switch. The user's choice stays while the match does.
            if libraryMatch.map({ AlbumInfoStore.key($0.album) }) != before { link = libraryMatch != nil }
        }
        guard let draft = makeItem(numbered: false, linking: false) else { libraryMatch = nil; return }
        if let album = model.album(forKey: draft.albumKey) {
            libraryMatch = (album, true)
        } else if let first = CollectionLinker.suggestions(for: draft, albums: model.albums, tracks: model.tracks).first {
            let tracks = model.tracks(of: first)
            let sure = tracks.contains { t in
                (draft.releaseID != nil && t.metadata.mbReleaseId == draft.releaseID)
                    || (draft.releaseGroupID != nil && t.metadata.extended.mbReleaseGroupId == draft.releaseGroupID)
            }
            libraryMatch = (first, sure)
        } else {
            libraryMatch = nil
        }
    }

    /// The item as entered. `numbered`: with the label (nil while the label isn't valid); `linking`: linked to the
    /// library album when that's on.
    private func makeItem(numbered: Bool, linking: Bool = true) -> CollectionItem? {
        var item: CollectionItem
        if manualEntry {
            let album = manual.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = manual.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !album.isEmpty || !artist.isEmpty else { return nil }
            item = CollectionItem(medium: chosenMedium, album: album, artist: artist)
            item.year = Int(manual.year.trimmingCharacters(in: .whitespaces)).flatMap { (1000...9999).contains($0) ? $0 : nil }
            item.recordLabel = Self.field(manual.recordLabel)
            item.catalogNumber = Self.field(manual.catalogNumber)
            let digits = manual.barcode.filter(\.isNumber)
            item.barcode = (6...20).contains(digits.count) ? digits : nil
            item.formatDetail = Self.field(manual.formatDetail)
            item.purchasedOn = purchasedOn
        } else {
            guard let e = edition else { return nil }
            item = CollectionDraft.item(from: e, medium: chosenMedium, sticker: nil)
        }
        if numbered, chosenMedium.series != nil { item.stickerNumber = number }
        item.purchasedOn = purchasedOn
        item.price = price
        item.notes = Self.field(notes)
        if linking, link, let match = libraryMatch {
            item.albumKey = AlbumInfoStore.key(match.album)
            item.digitalSource = LinkAlbumPicker.defaultSource(chosenMedium)
        }
        return item
    }

    private static func field(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func add(next: Bool) {
        guard let item = makeItem(numbered: true) else { return }
        // The label is checked again here: one suggested a moment ago may have been taken since (D7).
        if let sticker = item.sticker, let other = model.itemLabeled(sticker, excluding: nil) {
            message = "\(sticker.text) is taken by “\(other.album)”. Pick another number."
            return
        }
        // Linked to a library album with a cover, the item shows that one unless the user chose another (D11).
        let linkedCover = item.digitalSource != nil && libraryMatch.flatMap { model.coverURL(forAlbum: $0.album) } != nil
        let jpeg = (ownCover || !linkedCover) ? cover.flatMap(CoverImage.jpeg) : nil
        guard let saved = model.saveItem(item, cover: jpeg) else { return }
        model.ensureAlbumInfo(for: saved)
        added += 1
        if next {
            search.clear()
            selection = nil
            manual = Manual()
            notes = ""
            price = nil
            cover = nil
            coverSource = nil
            ownCover = false
            libraryMatch = nil
            message = nil
            number = chosenMedium.series.map { model.nextNumber(in: $0) }
            searchFocused = true
        } else {
            dismiss()
            model.showItem(id: saved.id)
        }
    }

    private func use(_ data: Data, source: String) {
        guard NSImage(data: data) != nil else { message = "That file isn't an image."; return }
        cover = data
        coverSource = source
        ownCover = true
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    private func pasteCover() {
        switch ImageInput.pasted() {
        case .file(let url): Task { await load(url) }
        case .image(let data): use(data, source: "Pasted image")
        case nil: message = "There's no image on the clipboard."
        }
    }

    private func load(_ url: URL) async {
        loadingCover = !url.isFileURL
        defer { loadingCover = false }
        switch await ImageInput.load(url) {
        case .success(let image): use(image.data, source: image.source)
        case .failure(let failure): message = failure.message
        }
    }
}

// MARK: Change Edition

/// Change Edition… on an item's page: the edition picker again. The edition picked replaces the item's release
/// details (release, record label, catalog number, barcode, country, media, discs, tracks, year) and nothing else:
/// its title, artist, link, label number and purchase stay.
struct ChangeEditionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @State private var search = EditionSearch()
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let item = model.item(id: itemID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Edition").font(.title2.bold())
            if let item {
                HStack(spacing: 6) {
                    Text("Which edition is").foregroundStyle(.subtext)
                    if let s = item.sticker { StickerPill(sticker: s, size: 10) }
                    Text("“\(item.album)”?").lineLimit(1)
                }
                .font(.callout)
                EditionResults(search: search, medium: item.medium, selection: $selection, focused: $searchFocused,
                               submitCurrent: { apply(item) })
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Edition") { if let item { apply(item) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(item == nil || selection == nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .onAppear {
            guard let item else { return }
            search.text = item.barcode ?? [item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " ")
            searchFocused = true
            search.run(model.musicBrainz, medium: item.medium) { found in
                if let id = item.releaseID, found.contains(where: { $0.id == id }) { selection = id }
            }
        }
    }

    private func apply(_ item: CollectionItem) {
        guard let id = selection, let e = search.results.first(where: { $0.id == id }) else { return }
        let draft = CollectionDraft.item(from: e, medium: item.medium, sticker: nil)
        let saved = model.changeItem(id: item.id) {
            $0.releaseID = draft.releaseID
            $0.releaseGroupID = draft.releaseGroupID
            $0.year = draft.year ?? $0.year
            $0.barcode = draft.barcode
            $0.catalogNumber = draft.catalogNumber
            $0.recordLabel = draft.recordLabel
            $0.country = draft.country
            $0.formatDetail = draft.formatDetail
            $0.discCount = draft.discCount
            $0.trackCount = draft.trackCount
        }
        // An item without songs takes its track list and info from its own release.
        if let saved, model.collection.libraryTracks(saved).isEmpty { model.refreshAlbumInfo(for: saved) }
        dismiss()
    }
}
