import MusicLibraryCore
import SwiftUI

/// The Shelf (or one of its scopes: CDs, Vinyl, Downloads, To Digitize): everything you own, with or without songs
/// in the library, filtered by `AppModel.shelfQuery` in the collection query language.
/// Placeholder grid; the full page (header, Go to, Label Check, list layout, sorting) comes later.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    let scope: CollectionScope

    var body: some View {
        let items = shown
        Group {
            if model.collection.items.isEmpty {
                ContentUnavailableView {
                    Label("Your shelf is empty", systemImage: "books.vertical")
                } actions: {
                    Button("Add to Collection…") { model.addToCollection() }
                }
            } else if items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "books.vertical")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 24) {
                        ForEach(items) { item in
                            NavigationLink(value: CollectionItemRoute(id: item.id)) { CollectionCell(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
                .themedScrollBackground()
            }
        }
        .navigationTitle(scope.title)
    }

    private var shown: [CollectionItem] {
        let query = model.shelfQuery.trimmingCharacters(in: .whitespaces)
        let inScope = model.collection.items(in: scope)
        guard !query.isEmpty else { return inScope }
        let ids = Set(model.collectionIndex.search(query).map(\.id))
        return inScope.filter { ids.contains($0.id) }
    }
}

/// One item in the Shelf's grid: its case or sleeve, title, artist, and its label and digital status.
struct CollectionCell: View {
    @Environment(AppModel.self) private var model
    let item: CollectionItem
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CopyArt(mark: model.collection.mark(item: item), url: model.coverURL(for: item), width: width,
                    revision: model.coverRevision, title: item.album)
            Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            HStack(spacing: 6) {
                if let sticker = item.sticker { StickerPill(sticker: sticker, size: 9) }
                let state = model.collection.digitalState(item)
                DigitalStatusLabel(state: state, medium: item.medium, from: from(state)).font(.caption2)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func from(_ state: DigitalState) -> CollectionItem? {
        if case .otherCopy(_, let id?) = state { return model.item(id: id) }
        return nil
    }
}

/// The Shelf as a list. Its cells never read the model from the environment (they don't always get it in a `Table`):
/// they're given it. Placeholder; the columns come later.
struct CollectionTable: View {
    let model: AppModel
    let items: [CollectionItem]

    var body: some View {
        Table(items) {
            TableColumn("Label") { item in Text(item.sticker?.text ?? "") }
            TableColumn("Title", value: \.album)
            TableColumn("Artist", value: \.artist)
        }
    }
}

/// Gaps and duplicates in each label series. Placeholder.
struct LabelCheckSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Label Check").font(.headline)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
