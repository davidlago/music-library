import MusicLibraryCore
import SwiftUI

/// One thing you own, ripped or not: its case or sleeve with the label, where its digital copy stands (play it, download
/// it, or rip it on the Mac), your copy (label, when you bought it, what you paid, notes), the release, the track list
/// (a record's sides), other copies of the album, then the description and reviews. Read-only, like the Mac's item page
/// without its editor. ‹ › step along the shelf in place.
struct CollectionItemPage: View {
    @Environment(PhoneModel.self) private var model
    @State private var shownID: String

    init(id: String) { _shownID = State(initialValue: id) }

    var body: some View {
        if let library = model.library, let item = model.item(id: shownID) {
            CollectionItemContent(item: item, library: library, step: { shownID = $0 })
                .id(item.id)
        } else if model.library == nil {
            LibraryStatusView()
        } else {
            ContentUnavailableView("Not in Your Collection", systemImage: "books.vertical",
                                   description: Text("It was removed from the collection on the Mac."))
        }
    }
}

private struct CollectionItemContent: View {
    @Environment(PhoneModel.self) private var model
    @Environment(PhonePlayer.self) private var player
    let item: CollectionItem
    let library: LibrarySnapshot
    /// Shows another item in place (the shelf's neighbors).
    let step: (String) -> Void

    private var title: String { item.album.isEmpty ? "Unknown Album" : item.album }
    private var collection: MusicCollection { model.collection }
    private var tracks: [Track] { collection.libraryTracks(item) }
    private var info: AlbumInfo? { library.albumInfos[item.albumKey] }

    var body: some View {
        let state = collection.digitalState(item)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                digitalCopy(state)
                yourCopy(state)
                AlbumTrackList(album: model.album(for: item), tracks: tracks, info: info, source: title)
                release
                otherCopies
                if let text = info?.description, let info {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About")
                        ExpandableText(text: text, source: info.descriptionSource, sourceURL: info.descriptionURL)
                    }
                }
                if let reviews = info?.reviews.filter(\.url.isWebLink), !reviews.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Reviews")
                        LinkChips(links: reviews)
                    }
                }
                Text("Edit your collection in Music Library on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background { AlbumBackdrop(url: library.coverURL(item: item)) }
        .navigationTitle(item.sticker?.text ?? title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 8) {
            CopyArt(mark: collection.mark(item: item), url: library.coverURL(item: item), width: 300, title: item.album)
                .padding(.top, 8)
                .padding(.bottom, 8)
            if let sticker = item.sticker {
                StickerPill(sticker: sticker, size: 20)
            }
            Text(typeLine).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center).textSelection(.enabled)
            artistButton
            if let meta = metaLine {
                Text(meta).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            shelfSteps
        }
        .frame(maxWidth: .infinity)
    }

    /// "VINYL · 10\" VINYL", "CD", "DOWNLOAD · BOUGHT AS SONGS".
    private var typeLine: String {
        if item.origin == .songs { return "DOWNLOAD · BOUGHT AS SONGS" }
        if case .other(let raw) = item.medium { return raw.uppercased() }
        // "12\" Vinyl" says it already.
        if let detail = item.formatDetail, detail.localizedCaseInsensitiveContains(item.medium.name) { return detail.uppercased() }
        return [item.medium.name, item.formatDetail].compactMap { $0?.uppercased() }.joined(separator: " · ")
    }

    @ViewBuilder
    private var artistButton: some View {
        let name = item.artist.isEmpty ? "Unknown Artist" : item.artist
        if !item.artist.isEmpty {
            // Artists who are only in the collection have a page too.
            NavigationLink(value: ArtistNameRoute(name: library.artist(named: item.artist)?.name ?? item.artist)) {
                HStack(spacing: 8) {
                    ArtistPhoto(name: item.artist, size: 26)
                    Text(name).font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(name).font(.title3.weight(.medium))
        }
    }

    /// "1959 · Columbia CL 1355 · US".
    private var metaLine: String? {
        var parts: [String] = []
        if let year = item.year ?? info?.firstReleaseYear { parts.append(String(year)) }
        let label = [item.recordLabel, item.catalogNumber].compactMap { $0 }.joined(separator: " ")
        if !label.isEmpty { parts.append(label) }
        if let country = item.country { parts.append(countryName(country)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The items on either side on the shelf: by label in the item's series; for one without a label, among the others
    /// without one, by artist and title (the end of the Shelf sorted by label).
    private var shelfNeighbors: (previous: CollectionItem?, next: CollectionItem?) {
        if let sticker = item.sticker { return collection.neighbors(of: sticker) }
        let unlabeled = CollectionSort.sticker.sorted(collection.items.filter { $0.sticker == nil })
        guard let i = unlabeled.firstIndex(where: { $0.id == item.id }) else { return (nil, nil) }
        return (i > 0 ? unlabeled[i - 1] : nil, i + 1 < unlabeled.count ? unlabeled[i + 1] : nil)
    }

    /// ‹ Previous on the shelf · Next ›.
    @ViewBuilder
    private var shelfSteps: some View {
        let neighbors = shelfNeighbors
        if neighbors.previous != nil || neighbors.next != nil {
            shelfSteps(neighbors)
        }
    }

    private func shelfSteps(_ neighbors: (previous: CollectionItem?, next: CollectionItem?)) -> some View {
        HStack(spacing: 12) {
            Button { if let p = neighbors.previous { step(p.id) } } label: {
                Label(neighbors.previous?.sticker.map { "#\($0.number)" } ?? "Previous", systemImage: "chevron.left")
            }
            .disabled(neighbors.previous == nil)
            .accessibilityLabel("Previous on the shelf")
            Text("On the shelf").font(.caption).foregroundStyle(.secondary)
            Button { if let n = neighbors.next { step(n.id) } } label: {
                HStack(spacing: 4) {
                    Text(neighbors.next?.sticker.map { "#\($0.number)" } ?? "Next")
                    Image(systemName: "chevron.right")
                }
            }
            .disabled(neighbors.next == nil)
            .accessibilityLabel("Next on the shelf")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote.monospacedDigit())
        .padding(.top, 4)
    }

    // MARK: Digital copy

    @ViewBuilder
    private func digitalCopy(_ state: DigitalState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Digital Copy")
            switch state {
            case .none, .missing:
                noMusic(state)
            case .digitized, .partial, .otherCopy:
                withMusic(state)
            }
        }
    }

    /// No songs to play or download: what to do about it on the Mac. Shown at full strength, with nothing to download.
    private func noMusic(_ state: DigitalState) -> some View {
        let missing = state == .missing
        let text: String
        if missing {
            text = "Digital copy no longer in the library."
        } else {
            switch item.medium {
            case .cd: text = "No digital copy yet. Rip it with Music Library on your Mac."
            case .vinyl: text = "No digital copy yet. Digitize it with Music Library on your Mac."
            default: text = "Its files aren't in the library."
            }
        }
        return HStack(spacing: 12) {
            Image(systemName: missing ? "exclamationmark.circle" : item.medium == .vinyl ? "record.circle" : "opticaldisc")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(12)
        .card()
    }

    @ViewBuilder
    private func withMusic(_ state: DigitalState) -> some View {
        let playable = model.playable(tracks)
        let album = model.album(for: item)
        // Digitized, but only on the Mac: dimmed, like the Library tab's albums.
        DigitalStatusLine(item: item, state: state, collection: collection, tracks: tracks)
            .opacity(model.availability(tracks) == .notOnPhone && !model.isSample ? 0.55 : 1)
        if let exportItem = model.exportItem(for: item) {
            AvailabilityBar(item: exportItem, tracks: tracks, noun: "album")
        }
        if !playable.isEmpty {
            HStack(spacing: 10) {
                Button { player.play(queue: playable, source: title) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { player.play(queue: playable.shuffled(), source: title) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let album {
                    NavigationLink(value: album) {
                        Image(systemName: "square.stack").frame(height: 20)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open Album")
                }
            }
            .lineLimit(1)
            .controlSize(.large)
        } else if let album {
            NavigationLink(value: album) {
                Label("Open Album", systemImage: "square.stack")
            }
            .font(.callout.weight(.medium))
        }
    }

    // MARK: Your copy

    @ViewBuilder
    private func yourCopy(_ state: DigitalState) -> some View {
        let rows = copyRows(state)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your Copy")
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Divider().padding(.leading, 14) }
                        LabeledContent(row.title) {
                            Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
                                .foregroundStyle(row.emphasized ? .primary : .secondary)
                                .fontWeight(row.emphasized ? .semibold : .regular)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .card()
            }
            if let notes = item.notes {
                Text(notes).font(.callout).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
            }
            if item.origin == .songs {
                Text("Made of the songs you bought as downloads, one by one.").font(.caption).foregroundStyle(.secondary)
            } else if case .other = item.medium {
                Text("Added by a newer version of Music Library.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copyRows(_ state: DigitalState) -> [(title: String, value: String, emphasized: Bool)] {
        var rows: [(title: String, value: String, emphasized: Bool)] = []
        if let sticker = item.sticker {
            rows.append(("Label", sticker.text, true))
        } else if item.medium.series != nil {
            rows.append(("Label", "None", false))
        }
        if let day = item.purchasedOn { rows.append(("Bought", day.date().formatted(date: .abbreviated, time: .omitted), false)) }
        if let price = item.price { rows.append(("Paid", formatMoney(price), false)) }
        if let price = item.price, price > 0, state.hasMusic {
            let plays = tracks.reduce(0) { $0 + (model.playTotals[$1.id]?.plays ?? 0) }
            if plays > 0 { rows.append(("Per play", "\(formatMoney(price / Decimal(plays))) · \(playCount(plays))", false)) }
        }
        rows.append(("Added", item.createdAt.formatted(date: .abbreviated, time: .omitted), false))
        return rows
    }

    // MARK: Release

    @ViewBuilder
    private var release: some View {
        let rows: [(String, String)] = [
            ("Record label", item.recordLabel), ("Catalog #", item.catalogNumber), ("Barcode", item.barcode),
            ("Country", item.country.map(countryName)), ("Media", item.formatDetail),
            ("Discs", item.discCount.flatMap { $0 > 1 ? String($0) : nil }), ("Tracks", item.trackCount.map(String.init)),
            ("Released", item.year.map(String.init)),
        ].compactMap { k, v in v.map { (k, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Release")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        LabeledContent(row.0) { Text(row.1).textSelection(.enabled).multilineTextAlignment(.trailing) }
                            .font(.callout)
                            .padding(.vertical, 9).padding(.horizontal, 14)
                        if i < rows.count - 1 { Divider().padding(.leading, 14) }
                    }
                }
                .card()
            }
        }
    }

    @ViewBuilder
    private var otherCopies: some View {
        let others = collection.copies(albumKey: item.albumKey).filter { $0.id != item.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Other Copies")
                VStack(spacing: 0) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { i, other in
                        if i > 0 { Divider().padding(.leading, 74) }
                        NavigationLink(value: CollectionItemRoute(id: other.id)) { CopyRow(item: other) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .card()
            }
        }
    }
}

/// "In your library · 12 songs · 46 min · FLAC 16/44.1", "8 of 12 songs", "Same album in your library, from your
/// CD #142".
private struct DigitalStatusLine: View {
    let item: CollectionItem
    let state: DigitalState
    let collection: MusicCollection
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        switch state {
        case .partial(let have, let total): return "\(have) of \(total) songs in your library"
        case .otherCopy(_, let from):
            if let from = from.flatMap(collection.item(id:)) {
                return "Same album in your library, from your " + (from.sticker?.text ?? from.medium.name.lowercased())
            }
            return "Same album in your library, from elsewhere"
        default: return "In your library"
        }
    }

    private var detail: String {
        var parts = [songCount(tracks.count), formatLongDuration(tracks.reduce(0) { $0 + $1.duration })]
        let formats = tracks.compactMap(\.audioFormat)
        if let common = Dictionary(grouping: formats, by: \.compact).max(by: { $0.value.count < $1.value.count }) {
            parts.append(common.key)
        }
        return parts.joined(separator: " · ")
    }
}
