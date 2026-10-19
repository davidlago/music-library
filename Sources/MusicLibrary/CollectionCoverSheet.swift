import MusicLibraryCore
import SwiftUI

/// Change Cover… for an item: a Cover Art Archive front, a file, a dragged image or the clipboard, saved as the
/// item's own cover (`AppModel.saveItem(_:cover:)`). Placeholder.
struct CollectionCoverSheet: View {
    let item: CollectionItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Cover for “\(item.album)”").font(.headline)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
