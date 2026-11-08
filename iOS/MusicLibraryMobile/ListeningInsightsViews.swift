import MusicLibraryCore
import MusicLibraryUI
import SwiftUI
import UIKit

// MARK: Pane

/// The Listening pane of Insights: the shared listening report (`ListeningReport` in MusicLibraryUI), with the
/// iPhone's pictures, links, ranked bars and facts grid. The period picker is above it, in `InsightsTab`.
struct ListeningInsightsPane: View {
    @Environment(PhoneModel.self) private var model
    let stats: ListeningStats

    var body: some View {
        if !stats.hasHistory {
            ContentUnavailableView("No Listening History Yet", systemImage: "headphones",
                                   description: Text("Play some music and this page fills in with what, when and how much you listen."))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text(ListeningText.range(stats)).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                ListeningReport(stats: stats) {
                    ListenedGenresCard(stats: stats)
                } facts: {
                    InsightFactsCard(facts: ListeningFacts.facts(stats).map(InsightFact.init))
                }
            }
            .environment(\.listeningLinks, ListeningLinks.phone(model))
        }
    }
}

private extension InsightFact {
    init(_ fact: ListeningFact) {
        self.init(icon: fact.icon, title: fact.title, value: fact.value, detail: fact.detail, query: fact.query, queryTitle: fact.queryTitle)
    }
}

/// Top genres as ranked bars, like the Digital Collection pane's.
private struct ListenedGenresCard: View {
    let stats: ListeningStats

    var body: some View {
        InsightCard(title: "Top Genres", subtitle: "\(stats.genres.total) genre\(stats.genres.total == 1 ? "" : "s") · songs can carry several") {
            InsightRankedBars(items: stats.genres.byPlays.map {
                InsightRankedItem(name: $0.name, value: Double($0.plays), detail: playCount($0.plays), query: SearchFilterKey.token("genre", $0.name))
            }, initialCount: 6)
        }
    }
}

// MARK: Pictures and links

extension ListeningLinks {
    /// The iPhone's: artist photos and covers from the library on the phone, and taps that push an artist's page, an
    /// album or a search.
    static func phone(_ model: PhoneModel) -> ListeningLinks {
        ListeningLinks(
            art: { item, kind, size, onLoad in AnyView(PhoneListeningArt(item: item, kind: kind, size: size, onLoad: onLoad)) },
            open: { target, label in AnyView(ListeningLink(target: target, label: label)) })
    }
}

/// The artist's photo (or a cover of theirs), or the cover of the album or song, decoded at the size it's shown.
private struct PhoneListeningArt: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.displayScale) private var scale
    let item: ListeningStats.Item
    let kind: ListeningKind
    /// The largest side it's shown at, in points.
    var size: CGFloat
    var onLoad: ((UIImage?) -> Void)?
    @State private var image: UIImage?

    var body: some View {
        let url = url
        ListeningArt(image: image, kind: kind)
            .task(id: url) {
                image = nil
                var loaded: UIImage?
                if let url { loaded = await CoverLoader.image(at: url, maxPixel: size * scale) }
                image = loaded
                onLoad?(loaded)
            }
    }

    private var url: URL? {
        guard let library = model.library else { return nil }
        if kind == .artist, let photo = library.artistImageURL(item.name) { return photo }
        guard let id = item.trackId, let track = library.track(id: id) else { return nil }
        return LibraryPath.coverURL(forTrackAt: track.path, root: library.root)
    }
}

/// Opens what a ranked item is (an artist's page, an album, or a search for a song), or a search.
private struct ListeningLink: View {
    @Environment(PhoneModel.self) private var model
    let target: ListeningTarget
    let label: AnyView

    var body: some View {
        Group {
            switch target {
            case .item(let item, .artist):
                if item.name == "Unknown Artist" {
                    label
                } else {
                    NavigationLink(value: ArtistNameRoute(name: item.name)) { label }
                }
            case .item(let item, .album):
                if let album = model.library?.album(forKey: String(item.id.dropFirst(3))) {
                    NavigationLink(value: album) { label }
                } else {
                    NavigationLink(value: QueryRoute(query: ListeningText.albumQuery(item), title: item.name)) { label }
                }
            case .item(let item, .song):
                NavigationLink(value: QueryRoute(query: ListeningText.songQuery(item), title: item.name)) { label }
            case .query(let query, let title):
                NavigationLink(value: QueryRoute(query: query, title: title)) { label }
            }
        }
        .buttonStyle(.plain)
    }
}
