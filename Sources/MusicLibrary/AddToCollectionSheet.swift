import MusicLibraryCore
import SwiftUI

/// What Add to Collection… starts from when it's opened for something in particular (a library CD's catalog page, a
/// shop listing, an album page): the search to run, and what's already known about the release.
struct CollectionPrefill: Hashable {
    /// "Artist and album, or barcode", as typed in the sheet's search field.
    var query = ""
    var album: String?
    var artist: String?
    var releaseID: String?
    var releaseGroupID: String?
    var barcode: String?
    var catalogNumber: String?
}

/// Add to Collection… (⇧⌘N): pick the medium, find the edition on MusicBrainz (by barcode, or artist and album) or
/// enter it yourself, then the label and purchase details. Placeholder.
struct AddToCollectionSheet: View {
    /// Nil: the medium last used.
    let medium: CollectionMedium?
    let prefill: CollectionPrefill?
    @Environment(\.dismiss) private var dismiss

    init(medium: CollectionMedium? = nil, prefill: CollectionPrefill? = nil) {
        self.medium = medium
        self.prefill = prefill
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add to Collection").font(.headline)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
