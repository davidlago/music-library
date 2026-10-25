import AppKit
import MusicLibraryCore
import SwiftUI

/// An item's page: its case or sleeve with the label, its digital copy, the release's tracks (from the album info
/// cache, the library's songs playable, a record's sides shown), the details of your copy, your other copies of the
/// album and what's known about it. It works for every item, with or without songs in the library, and never
/// dismisses itself for lack of tracks.
struct CollectionItemDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let id: String
    @State private var cover: NSImage?
    @State private var hoveringCover = false
    @State private var coverDropTargeted = false
    @State private var descriptionExpanded = false

    var body: some View {
        if let item = model.item(id: id) {
            page(item)
        } else {
            ContentUnavailableView("Copy Not Found", systemImage: "books.vertical",
                                   description: Text("This copy was removed from what you own."))
        }
    }

    private func page(_ item: CollectionItem) -> some View {
        let info = model.albumInfo.infos[item.albumKey]
        let coverURL = model.coverURL(for: item)
        return GeometryReader { geo in
            ZStack {
                AlbumBackdrop(image: cover)
                if geo.size.width >= 920 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                hero(item, info, coverSize: min(340, geo.size.width * 0.42 - 56))
                                digitalCopy(item)
                                yourCopy(item)
                                otherCopies(item)
                            }
                            .padding(28)
                        }
                        .frame(width: min(480, geo.size.width * 0.44))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                tracks(item, info)
                                about(item, info)
                            }
                            .padding(.vertical, 28).padding(.trailing, 28).padding(.leading, 4)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            hero(item, info, coverSize: min(300, geo.size.width - 48))
                            digitalCopy(item)
                            tracks(item, info)
                            yourCopy(item)
                            otherCopies(item)
                            about(item, info)
                        }
                        .padding(24)
                    }
                }
            }
        }
        .radioDJ { [model, item] in model.radioDJSubject(item: item) }
        .navigationTitle(item.album.isEmpty ? "Unknown Album" : item.album)
        .toolbar {
            ToolbarItem {
                Button { model.refreshAlbumInfo(for: item) } label: { Label("Update Album Info", systemImage: "arrow.clockwise") }
                    .disabled(item.album.isEmpty || model.albumInfo.current == item.albumKey)
                    .help("Download the latest description, rating, links and track list")
            }
        }
        .task(id: item.id) { model.ensureAlbumInfo(for: item) }
        .task(id: "\(coverURL?.path ?? "")|\(model.coverRevision)") {
            guard let coverURL else { cover = nil; return }
            let data = await Task.detached { try? Data(contentsOf: coverURL) }.value
            cover = data.flatMap(NSImage.init(data:))
        }
    }

    // MARK: Hero

    private func hero(_ item: CollectionItem, _ info: AlbumInfo?, coverSize: CGFloat) -> some View {
        let state = model.collection.digitalState(item)
        let album = model.linkedAlbum(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            coverArt(item, size: coverSize).padding(.bottom, 10)
            Text(item.album.isEmpty ? "Unknown Album" : item.album)
                .font(.system(size: 30, weight: .bold)).lineLimit(3).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            artistButton(item)
            if let meta = metaLine(item) { Text(meta).font(.callout).foregroundStyle(.subtext).textSelection(.enabled) }
            if let info, let rating = info.rating { RatingView(rating: rating, votes: info.ratingVotes) }
            if let genres = info?.genres, !genres.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(genres, id: \.self) { g in
                        Text(g.capitalized).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(theme.fill))
                    }
                }
            }
            HStack(spacing: 10) {
                if state.hasMusic {
                    Button { model.play(item: item) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                        .buttonStyle(.borderedProminent)
                    Button { model.play(item: item, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.bordered)
                }
                if let album {
                    Button("Open Album") { model.navigationPath.append(album) }
                        .buttonStyle(.bordered)
                        .help("Go to the album in your digital collection")
                }
                moreMenu(item, album: album)
            }
            .controlSize(.large)
            .padding(.top, 6)
            shelfNeighbors(item).padding(.top, 4)
        }
    }

    /// The case or sleeve, with "Change Cover…" on hover; dropping an image on it opens the cover sheet with it.
    private func coverArt(_ item: CollectionItem, size: CGFloat) -> some View {
        CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: size,
                revision: model.coverRevision, title: item.album)
            .overlay(alignment: .bottomTrailing) {
                if hoveringCover, item.isEditable {
                    Button { changeCover(item) } label: { Label("Change Cover…", systemImage: "photo") }
                        .controlSize(.small)
                        .padding(14)
                }
            }
            .overlay {
                if coverDropTargeted {
                    RoundedRectangle(cornerRadius: JewelCase<EmptyView>.cornerRadius(width: size)).strokeBorder(theme.accent, lineWidth: 3)
                }
            }
            .onHover { hoveringCover = $0 }
            .contextMenu {
                if item.isEditable { Button("Change Cover…") { changeCover(item) } }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard item.isEditable, let url = urls.first, url.isFileURL,
                      let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return false }
                model.collectionSheet = .cover(itemID: item.id, request: CoverSheetRequest(image: data, source: url.lastPathComponent))
                return true
            } isTargeted: { coverDropTargeted = $0 }
    }

    private func changeCover(_ item: CollectionItem) {
        model.collectionSheet = .cover(itemID: item.id, request: CoverSheetRequest())
    }

    @ViewBuilder
    private func artistButton(_ item: CollectionItem) -> some View {
        let name = item.artist.isEmpty ? "Unknown Artist" : item.artist
        if item.artist.isEmpty {
            Text(name).font(.title3.weight(.medium))
        } else {
            Button { model.showArtist(named: item.artist) } label: {
                HStack(spacing: 8) {
                    ArtistPhoto(name: item.artist, size: 26)
                    Text(name).font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.subtext)
                }
            }
            .buttonStyle(.plain)
            .help("Go to \(name)")
        }
    }

    /// "1959 · 12″ Vinyl · Columbia CL 1355 · US".
    private func metaLine(_ item: CollectionItem) -> String? {
        let label = [item.recordLabel, item.catalogNumber].compactMap { $0 }.joined(separator: " ")
        let parts = [item.year.map(String.init), item.formatDetail, label.isEmpty ? nil : label,
                     item.country.map(LabelsCard.countryName)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func moreMenu(_ item: CollectionItem, album: AlbumSummary?) -> some View {
        Menu {
            if item.isEditable {
                Button("Change Cover…") { changeCover(item) }
                Button("Link Digital Copy…") { model.collectionSheet = .link(itemID: item.id) }
                Menu("Digital Copy") {
                    Picker("Digital Copy", selection: Binding(get: { item.digitalSource }, set: { source in
                        model.changeItem(id: item.id) { $0.digitalSource = source }
                    })) {
                        ForEach(LinkAlbumPicker.sources(for: item.medium), id: \.0) { Text($0.1).tag(Optional($0.0)) }
                    }
                    .pickerStyle(.inline)
                    .disabled(model.collection.libraryTracks(item).isEmpty)
                    Divider()
                    Button("Unlink") { model.unlink(itemID: item.id) }.disabled(!model.canUnlink(item))
                }
            }
            if let album {
                Divider()
                QueueMenuButtons(player: model.player) { model.collection.libraryTracks(item) }
                AddToExportListButton(album: album)
            }
            if item.medium == .vinyl, item.isEditable {
                Divider()
                Button("Digitize This Record…", systemImage: "waveform.badge.mic") { model.vinyl.show(item) }
            }
            if item.medium == .cd {
                Divider()
                Button("Shop for This CD", systemImage: "cart") {
                    model.cdShop.shop(releaseId: item.releaseID, album: item.album, artist: item.artist)
                    model.sidebar = .cdShop
                }
            }
            if item.isEditable {
                Divider()
                Button(item.medium.isPhysical ? "Remove from Physical Collection…" : "Remove from Downloads…", role: .destructive) { model.confirmItemRemoval(item) }
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(.bordered).menuIndicator(.hidden).fixedSize()
            .help("Cover, link to the digital collection, the digital copy, the queue, digitizing, shopping and removing")
    }

    /// ‹ Previous on Shelf / Next on Shelf › (⌘[ / ⌘]): the labeled items either side in the same series.
    @ViewBuilder
    private func shelfNeighbors(_ item: CollectionItem) -> some View {
        if let sticker = item.sticker {
            let n = model.collection.neighbors(of: sticker)
            HStack(spacing: 10) {
                Button { if let p = n.previous { go(to: p) } } label: {
                    Label(n.previous?.sticker.map { "Previous on Shelf · \($0.text)" } ?? "Previous on Shelf", systemImage: "chevron.left")
                }
                .disabled(n.previous == nil)
                .keyboardShortcut("[", modifiers: .command)
                .help(n.previous.map { "“\($0.album)” by \($0.artist)" } ?? "Nothing before \(sticker.text)")
                Button { if let next = n.next { go(to: next) } } label: {
                    HStack(spacing: 4) {
                        Text(n.next?.sticker.map { "Next on Shelf · \($0.text)" } ?? "Next on Shelf")
                        Image(systemName: "chevron.right")
                    }
                }
                .disabled(n.next == nil)
                .keyboardShortcut("]", modifiers: .command)
                .help(n.next.map { "“\($0.album)” by \($0.artist)" } ?? "Nothing after \(sticker.text)")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    /// Replaces this page with another item's.
    private func go(to other: CollectionItem) {
        if !model.navigationPath.isEmpty { model.navigationPath.removeLast() }
        model.navigationPath.append(CollectionItemRoute(id: other.id))
    }

    // MARK: Digital copy

    private func digitalCopy(_ item: CollectionItem) -> some View {
        let state = model.collection.digitalState(item)
        let songs = model.collection.libraryTracks(item)
        let album = model.linkedAlbum(for: item)
        let disc = model.discInDrive(for: item)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Digital Copy")
            VStack(alignment: .leading, spacing: 10) {
                switch state {
                case .digitized:
                    status("checkmark.circle.fill", "In your digital collection · \(songsLine(songs))")
                    albumButton(album)
                case .partial(let have, let of):
                    status("circle.lefthalf.filled", "\(have) of \(of) songs in your digital collection · \(formatLongDuration(songs.reduce(0) { $0 + $1.duration }))")
                    HStack {
                        albumButton(album)
                        if let disc { Button("Rip the Rest") { model.cd.show(disc, for: item) } }
                        if item.medium == .vinyl, item.isEditable {
                            Button("Digitize the Rest…") { model.vinyl.show(item) }
                                .help("Record the songs that aren't in your digital collection yet")
                        }
                    }
                case .otherCopy(_, let fromID):
                    let from = fromID.flatMap { model.item(id: $0) }
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.subtext)
                        Text("Same album in your digital collection, from").fixedSize()
                        if let from {
                            Button(from.sticker.map { "your \($0.text)" } ?? "your \(from.medium.name.lowercased())") {
                                go(to: from)
                            }
                            .buttonStyle(.link)
                        } else {
                            Text("elsewhere")
                        }
                    }
                    .font(.callout)
                    Text(songsLine(songs)).font(.caption).foregroundStyle(.subtext)
                    albumButton(album)
                case .none:
                    noCopy(item, disc: disc)
                case .missing:
                    status("exclamationmark.triangle.fill", "The linked album is no longer in your digital collection")
                    if item.isEditable {
                        HStack {
                            Button("Unlink") { model.unlink(itemID: item.id) }
                                .help("Mark it as never digitized")
                            if item.medium == .cd {
                                Button("Rip Again") { if let disc { model.cd.show(disc, for: item) } }
                                    .disabled(disc == nil)
                                    .help(disc == nil ? "Insert this CD to rip it again" : "Rip the CD in the drive")
                            }
                            if item.medium == .vinyl {
                                Button("Digitize Again…") { model.vinyl.show(item) }
                                    .help("Record this record and save its tracks again")
                            }
                            Button("Link…") { model.collectionSheet = .link(itemID: item.id) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.card.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func noCopy(_ item: CollectionItem, disc: CDDisc?) -> some View {
        switch item.medium {
        case .cd:
            if let disc {
                status("opticaldisc.fill", "This CD is in the drive")
                HStack {
                    Button("Rip Now") { model.cd.show(disc, for: item) }.buttonStyle(.borderedProminent)
                    actions(item, importTitle: "Import Files…")
                }
            } else {
                status("waveform.slash", "Not ripped yet. Insert this CD to rip it.")
                actions(item, importTitle: "Import Files…")
            }
        case .vinyl:
            status("waveform.slash", "No digital copy yet")
            HStack {
                if item.isEditable {
                    Button("Digitize…") { model.vinyl.show(item) }
                        .buttonStyle(.borderedProminent)
                        .help("Record this record from your turntable and save its tracks as FLAC")
                }
                actions(item, importTitle: "Import a Transfer…")
            }
        case .other:
            status("waveform.slash", "No digital copy yet")
            actions(item, importTitle: "Import a Transfer…")
        case .download:
            status("arrow.down.circle", "Not in your digital collection yet")
            actions(item, importTitle: "Import Files…")
        }
    }

    @ViewBuilder
    private func actions(_ item: CollectionItem, importTitle: String) -> some View {
        if item.isEditable {
            HStack {
                Button(importTitle) { model.importFiles(for: item) }
                    .help("Import the files of this \(item.medium == .vinyl ? "record's transfer" : "album"), linked to this copy")
                Button("Link…") { model.collectionSheet = .link(itemID: item.id) }
                    .help("It's already in your digital collection: link it to that album")
            }
        }
    }

    private func status(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout)
    }

    @ViewBuilder
    private func albumButton(_ album: AlbumSummary?) -> some View {
        if let album { Button("Open Album") { model.navigationPath.append(album) } }
    }

    /// "12 songs · 46 min · FLAC 16/44.1".
    private func songsLine(_ songs: [Track]) -> String {
        var parts = [songCount(songs.count), formatLongDuration(songs.reduce(0) { $0 + $1.duration })]
        let formats = songs.compactMap(\.audioFormat)
        if let common = Dictionary(grouping: formats, by: \.compact).max(by: { $0.value.count < $1.value.count }) {
            parts.append(common.key)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Tracks

    @ViewBuilder
    private func tracks(_ item: CollectionItem, _ info: AlbumInfo?) -> some View {
        let songs = model.collection.libraryTracks(item)
        let rows = AlbumTracklist.merge(library: songs, tracklist: info?.tracklist ?? [])
        let discs = Array(Set(rows.map(\.disc))).sorted()
        let missing = rows.filter { if case .missing = $0 { true } else { false } }.count
        let playable = rows.compactMap { if case .owned(let t, _) = $0 { t } else { nil } }
        let positions = item.medium == .vinyl
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Tracks")
                Spacer()
                if missing > 0, !playable.isEmpty {
                    Text("\(playable.count) of \(rows.count) in your digital collection").font(.callout).foregroundStyle(.subtext)
                }
            }
            if rows.isEmpty {
                Group {
                    if model.albumInfo.current == item.albumKey {
                        Label("Looking up the track list…", systemImage: "arrow.down.circle")
                    } else if item.releaseID == nil && item.releaseGroupID == nil {
                        Text("No track list: this item isn't matched to a release on MusicBrainz. Use Change Edition… below.")
                    } else {
                        Text("No track list yet. Update Album Info (in the toolbar) downloads it.")
                    }
                }
                .font(.callout).foregroundStyle(.subtext)
            } else {
                VStack(spacing: 0) {
                    ForEach(discs, id: \.self) { disc in
                        if discs.count > 1 {
                            HStack {
                                Image(systemName: positions ? "record.circle" : "opticaldisc").foregroundStyle(.subtext)
                                Text("\(positions ? "Record" : "Disc") \(disc)").font(.callout.weight(.semibold))
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.top, disc == discs.first ? 10 : 18).padding(.bottom, 4)
                        }
                        ForEach(rows.filter { $0.disc == disc }) { row in
                            AlbumTrackRow(row: row, albumArtist: item.artist, total: playTotal(row), showsPositions: positions) {
                                if case .owned(let t, _) = row, let i = playable.firstIndex(of: t) {
                                    model.player.play(queue: playable, startAt: i, source: item.album)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.card.opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator.opacity(0.5), lineWidth: 0.5))
                if missing > 0 {
                    Text(playable.isEmpty ? "The release's tracks. None of them is in your digital collection yet."
                         : "Greyed-out tracks are on this release but not in your digital collection.")
                        .font(.caption).foregroundStyle(.subtext)
                }
            }
        }
    }

    private func playTotal(_ row: AlbumTracklist.Row) -> PlayTotal? {
        if case .owned(let t, _) = row { return model.playTotals[t.id] }
        return nil
    }

    // MARK: Your copy, other copies

    private func yourCopy(_ item: CollectionItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Copy")
            CollectionItemEditor(item: item)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.card.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func otherCopies(_ item: CollectionItem) -> some View {
        let others = model.collection.copies(albumKey: item.albumKey).filter { $0.id != item.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: others.count == 1 ? "Your Other Copy" : "Your Other Copies")
                VStack(spacing: 0) {
                    ForEach(others) { other in
                        NavigationLink(value: CollectionItemRoute(id: other.id)) { CopyRow(item: other) }
                            .buttonStyle(.plain)
                        if other.id != others.last?.id { Divider().opacity(0.5) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.card.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.separator.opacity(0.6), lineWidth: 0.5))
            }
        }
    }

    // MARK: About

    @ViewBuilder
    private func about(_ item: CollectionItem, _ info: AlbumInfo?) -> some View {
        if let info, let text = info.description {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "About")
                Text(text).lineSpacing(3).lineLimit(descriptionExpanded ? nil : 6).textSelection(.enabled)
                HStack(spacing: 14) {
                    if text.count > 350 {
                        Button(descriptionExpanded ? "Show Less" : "Read More") { withAnimation(.snappy) { descriptionExpanded.toggle() } }
                            .buttonStyle(.link)
                    }
                    if let source = info.descriptionSource {
                        if let url = info.descriptionURL?.webLink { Link("From \(source)", destination: url).font(.caption) }
                        else { Text("From \(source)").font(.caption).foregroundStyle(.subtext) }
                    }
                }
            }
        }
        if let reviews = info?.reviews.filter(\.url.isWebLink), !reviews.isEmpty { linkChips("Reviews", reviews) }
        if let links = info?.links.filter({ $0.kind != .review && $0.url.isWebLink }), !links.isEmpty { linkChips("Links", links) }
    }

    private func linkChips(_ title: String, _ links: [ArtistLink]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            FlowLayout(spacing: 8) {
                ForEach(links) { link in
                    if let url = link.url.webLink {
                        Link(destination: url) {
                            Label(link.title, systemImage: ArtistDetail.icon(link.kind))
                                .font(.callout)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(theme.fill))
                        }
                        .buttonStyle(.plain)
                        .help(url.absoluteString)
                    }
                }
            }
        }
    }
}

/// One copy in a list of copies: its small case or sleeve, label, medium, purchase and digital copy.
struct CopyRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let item: CollectionItem
    @State private var hovering = false

    var body: some View {
        let state = model.collection.digitalState(item)
        HStack(spacing: 12) {
            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 56,
                    revision: model.coverRevision, title: item.album)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let s = item.sticker { StickerPill(sticker: s, size: 10) }
                    Text(item.formatDetail ?? item.medium.name).font(.callout.weight(.medium)).lineLimit(1)
                }
                if let line = LabelLookupCard.purchaseLine(item) { Text(line).font(.caption).foregroundStyle(.subtext) }
                DigitalStatusLabel(state: state, medium: item.medium, from: LabelLookupCard.from(state, in: model)).font(.caption)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.subtext)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? theme.fill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
