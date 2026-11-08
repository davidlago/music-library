import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

// MARK: Pane

/// The Collection pane of Insights (`CollectionStats`): everything you own, CDs, records and downloads, with or
/// without music in the library: how much of it is digitized, your label series, what you paid and how much you
/// play it. The cards are shared with the iPhone (`OwnedInsights.swift` in MusicLibraryUI); this lays them out and
/// opens what they link to: rows open the item, drill-downs open the Shelf with a collection query, never a song search.
struct CollectionContent: View {
    @Environment(AppModel.self) private var model
    let stats: CollectionStats

    var body: some View {
        if stats.itemCount == 0 {
            VStack(spacing: 14) {
                ContentUnavailableView("Nothing Owned Yet", systemImage: "books.vertical",
                                       description: Text("Add the CDs, records and downloads you own: by barcode or by name, from an album page, or when you rip a CD. Add when you bought them and what you paid, and this page fills in."))
                HStack {
                    Button("Add to Physical Collection…") { model.addToCollection() }
                    Button("Add Albums You Own from Your Digital Collection…") { model.collectionSheet = .addLibraryAlbums }
                        .disabled(model.albums.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TileGrid { CollectionTiles(stats: stats) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        CollectionShelvesCard(stats: stats, collection: model.collection)
                        CollectionMediaCard(stats: stats)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        let values = model.values
                        CollectionValueCard(stats: values.stats, progress: values.progress, update: { values.updateAll() },
                                            stop: { values.stop() }) { item in
                            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 34,
                                    revision: model.coverRevision, title: item.album)
                        }
                        BuyListCard(shown: model.buyList.shown) { model.showBuyList() }
                    }
                    if !stats.timeline.isEmpty { CollectionSpendingCard(stats: stats) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        CollectionListsCard(stats: stats) { item in
                            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 38,
                                    revision: model.coverRevision, title: item.album)
                        }
                        CollectionArtistsCard(stats: stats)
                        CollectionBreakdownCard(stats: stats)
                    }
                    facts
                }
                .padding(20)
                .environment(\.collectionInsightActions, actions)
            }
        }
    }

    /// The shared facts in this app's facts grid: one about several items opens them on the Shelf, else its item.
    @ViewBuilder
    private var facts: some View {
        let facts = CollectionFacts.list(stats)
        if !facts.isEmpty {
            InsightCard(title: "Fun Facts") {
                FactsGrid(facts: facts.map { f in
                    FunFact(icon: f.icon, title: f.title, value: f.value, detail: f.detail,
                            itemID: f.shelfQuery == nil ? f.itemID : nil, shelfQuery: f.shelfQuery)
                })
            }
        }
    }

    /// Where the cards' links go on the Mac, where the collection is edited.
    private var actions: CollectionInsightActions {
        CollectionInsightActions(canEdit: true, canShowNotOwned: true) { [model] link in
            switch link {
            case .item(let id): model.showItem(id: id)
            case .query(let query, _): model.showShelf(query: query)
            case .scope(let scope): model.showShelf(scope: scope)
            case .labelCheck: model.collectionSheet = .labelCheck
            case .freeLabel(let sticker): model.findByLabel(sticker)
            case .addNext(let series): model.addToCollection(medium: series.medium)
            case .notOwnedAlbums:
                UserDefaults.standard.set(AlbumsCollectionFilter.notInCollection.rawValue, forKey: "albumsCollectionFilter")
                model.sidebar = .albums
            }
        }
    }
}
