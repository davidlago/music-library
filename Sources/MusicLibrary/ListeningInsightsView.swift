import AppKit
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

// MARK: Pane

/// The Listening pane of Insights: the period picker over the shared listening report (`ListeningReport` in
/// MusicLibraryUI), with the Mac's pictures, links, ranked bars and facts grid.
struct ListeningContent: View {
    @Environment(AppModel.self) private var model
    let stats: ListeningStats
    @Binding var period: ListeningStats.Period

    var body: some View {
        if !stats.hasHistory {
            ContentUnavailableView("No Listening History Yet", systemImage: "headphones",
                                   description: Text("Play some music and this page fills in with what, when and how much you listen."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ListeningReport(stats: stats) {
                        ListenedGenresCard(stats: stats)
                    } facts: {
                        InsightCard(title: "Fun Facts") { FactsGrid(facts: ListeningFacts.facts(stats).map(FunFact.init)) }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .environment(\.listeningLinks, ListeningLinks.mac(model))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ListeningText.range(stats)).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            Picker("Period", selection: $period) { ForEach(ListeningStats.Period.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

func playCount(_ n: Int) -> String { ListeningText.plays(n) }

private extension FunFact {
    init(_ fact: ListeningFact) {
        self.init(icon: fact.icon, title: fact.title, value: fact.value, detail: fact.detail, query: fact.query)
    }
}

/// Top genres as ranked bars, like the Digital Collection pane's.
private struct ListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Top Genres", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            RankedBars(items: stats.genres.byPlays.map {
                RankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 7)
        }
    }
}

// MARK: Pictures and links

extension ListeningLinks {
    /// The Mac's: artist photos and covers from the library, and clicks that open an artist's page, an album or a
    /// search, with a context menu on ranked items.
    @MainActor
    static func mac(_ model: AppModel) -> ListeningLinks {
        ListeningLinks(
            art: { item, kind, _, onLoad in AnyView(MacListeningArt(item: item, kind: kind, onLoad: onLoad)) },
            open: { target, label in
                switch target {
                case .item(let item, let kind):
                    AnyView(Button { openListening(item, kind, model) } label: { label }
                        .buttonStyle(.plain)
                        .contextMenu { ListeningItemMenu(item: item, kind: kind) }
                        .help(kind == .song ? "Search for this song" : "Open \(item.name)"))
                case .query(let query, _):
                    AnyView(Button { model.search(query) } label: { label }.buttonStyle(.plain))
                }
            })
    }
}

/// Opens what a ranked item is: an artist's page, an album, or a search for a song.
@MainActor
private func openListening(_ item: ListeningStats.Item, _ kind: ListeningKind, _ model: AppModel) {
    switch kind {
    case .artist:
        if item.name != "Unknown Artist" { model.showArtist(named: item.name) }
    case .album:
        if let album = model.album(forKey: String(item.id.dropFirst(3))) {
            model.navigationPath.append(album)
        } else {
            model.search(ListeningText.albumQuery(item))
        }
    case .song:
        model.search(ListeningText.songQuery(item))
    }
}

/// The artist's photo (or a cover of theirs), or the cover of the album or song, loaded from the library.
private struct MacListeningArt: View {
    @Environment(AppModel.self) private var model
    let item: ListeningStats.Item
    let kind: ListeningKind
    var onLoad: ((NSImage?) -> Void)?
    @State private var image: NSImage?

    var body: some View {
        ListeningArt(image: image, kind: kind)
            .task(id: "\(item.id)|\(kind == .artist ? model.artistInfo.imageFile(for: item.name) ?? "" : "")|\(model.coverRevision)") {
                let loaded = await load()
                image = loaded
                onLoad?(loaded)
            }
    }

    private func load() async -> NSImage? {
        if kind == .artist, let photo = await model.artistInfo.image(for: item.name) { return photo }
        guard let id = item.trackId, let track = model.trackByID[id], let url = model.coverURL(for: track) else { return nil }
        return await ListeningCovers.image(url)
    }
}

/// Covers, decoded off the main thread and kept while the app runs (the pane shows the same few many times).
@MainActor
private enum ListeningCovers {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url.path as NSString)
        return image
    }
}

private struct ListeningItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: ListeningStats.Item
    let kind: ListeningKind

    var body: some View {
        let track = item.trackId.flatMap { model.trackByID[$0] }
        let album = track.flatMap { model.album(forKey: SearchIndex.albumKey(album: $0.album, artist: $0.effectiveAlbumArtist)) }
        switch kind {
        case .song:
            if let track { Button("Play") { model.player.play(queue: [track], startAt: 0, source: "Insights") } }
            if let album { Button("Open Album") { model.navigationPath.append(album) } }
            if let track, !track.effectiveAlbumArtist.isEmpty {
                Button("Show Artist") { model.showArtist(named: track.effectiveAlbumArtist) }
            }
        case .album:
            if let album {
                Button("Play") { model.player.play(queue: model.tracks(of: album), startAt: 0, source: album.album) }
                Button("Open Album") { model.navigationPath.append(album) }
                Button("Show Artist") { model.showArtist(named: album.artist) }
            }
        case .artist:
            if item.name != "Unknown Artist" {
                Button("Show Artist") { model.showArtist(named: item.name) }
                Button("Show Music DNA") { model.showMusicDNA(item.name) }
                    .disabled(model.collaborations.person(named: item.name) == nil)
            }
        }
    }
}
