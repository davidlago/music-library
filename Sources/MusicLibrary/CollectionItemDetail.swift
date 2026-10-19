import MusicLibraryCore
import SwiftUI

/// An item's page: its case or sleeve, label, digital copy, tracks and the details of your copy. It works for every
/// item, with or without songs in the library, and never dismisses itself for lack of tracks.
/// Placeholder hero; the cards (Digital Copy, Tracks, Your Copy, Other Copies, About) come later.
struct CollectionItemDetail: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let item = model.item(id: id) {
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: 300,
                            revision: model.coverRevision, title: item.album)
                    VStack(alignment: .leading, spacing: 8) {
                        if let sticker = item.sticker { StickerPill(sticker: sticker, size: 18) }
                        Text(item.album).font(.largeTitle.bold()).textSelection(.enabled)
                        Text(item.artist).font(.title3).foregroundStyle(.subtext)
                        DigitalStatusLabel(state: model.collection.digitalState(item), medium: item.medium)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .themedScrollBackground()
            .navigationTitle(item.album)
            .task(id: item.id) { model.ensureAlbumInfo(for: item) }
        } else {
            ContentUnavailableView("Not in your collection", systemImage: "books.vertical",
                                   description: Text("This item was removed from your collection."))
        }
    }
}
