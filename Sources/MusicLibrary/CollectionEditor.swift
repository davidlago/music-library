import MusicLibraryCore
import SwiftUI

/// Your copy's details on its page (medium, label, purchase, release), edited inline and saved on commit through
/// `AppModel.saveItem`. Placeholder.
struct CollectionItemEditor: View {
    let item: CollectionItem

    var body: some View {
        Text(item.sticker?.text ?? item.medium.name)
    }
}

/// A label number in one series, with the next number suggested and a number another item has refused (D7).
/// Placeholder.
struct StickerField: View {
    let series: StickerSeries
    @Binding var number: Int?
    /// The item being edited, which doesn't count as taking its own number.
    var itemID: String?

    var body: some View {
        TextField(series.name, value: $number, format: .number.grouping(.never))
    }
}

/// Link to Library Album…: `CollectionLinker.suggestions` first, then a search, then None. Placeholder.
struct LinkAlbumPicker: View {
    let item: CollectionItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Link “\(item.album)” to a Library Album").font(.headline)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}

/// Add Library Albums…: library albums with no copy, numbered in order and added in one go. Placeholder.
struct BulkAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Library Albums").font(.headline)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
