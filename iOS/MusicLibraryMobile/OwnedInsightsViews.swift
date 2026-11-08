import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

// MARK: Pane

/// The Owned pane of Insights: everything you own (CDs, records, downloads, ripped or not), how much of it is
/// digitized, your label series, what it cost and what it's been worth. The cards are shared with the Mac
/// (`OwnedInsights.swift` in MusicLibraryUI); this lays them out and pushes what they link to: rows open items, and
/// drill-downs open the collection, never a song search.
struct CollectionInsightsPane: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.openRoute) private var openRoute
    let stats: CollectionStats

    var body: some View {
        if stats.itemCount == 0 {
            ContentUnavailableView("Nothing Owned Yet", systemImage: "books.vertical",
                                   description: Text("Add the CDs, records and downloads you own in Music Library on your Mac, with when you bought them and what you paid, and this page fills in."))
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                InsightTileGrid { CollectionTiles(stats: stats) }
                CollectionShelvesCard(stats: stats, collection: model.collection)
                CollectionMediaCard(stats: stats)
                if !stats.timeline.isEmpty { CollectionSpendingCard(stats: stats) }
                CollectionListsCard(stats: stats) { item in
                    CoverImage(url: model.library?.coverURL(item: item), size: 40, title: nil)
                }
                CollectionArtistsCard(stats: stats)
                CollectionBreakdownCard(stats: stats)
                let facts = CollectionFacts.list(stats)
                if !facts.isEmpty {
                    InsightFactsCard(facts: facts.map { f in
                        InsightFact(icon: f.icon, title: f.title, value: f.value, detail: f.detail, itemID: f.itemID)
                    })
                }
            }
            .environment(\.collectionInsightActions, actions)
        }
    }

    /// Where the cards' links go on the phone (read-only: no adding, and Find by Label has its own card).
    private var actions: CollectionInsightActions {
        CollectionInsightActions { [openRoute] link in
            switch link {
            case .item(let id): openRoute(CollectionItemRoute(id: id))
            case .query(let query, let title): openRoute(CollectionRoute.query(query, title: title))
            case .scope(let scope): openRoute(CollectionRoute.scope(scope))
            case .labelCheck(let series): openRoute(CollectionRoute.labelCheck(series))
            case .freeLabel, .addNext, .notOwnedAlbums: break
            }
        }
    }
}
