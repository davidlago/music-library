import MusicLibraryCore
import SwiftUI

/// Find by Label (⌘L): a series and a number, and what's at that spot on your shelf, with its neighbors.
/// Placeholder.
struct FindByLabelPanel: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Find by Label").font(.headline)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
