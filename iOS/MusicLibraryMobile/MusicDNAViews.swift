import MusicLibraryCore
import SwiftUI

/// Music DNA, centered on `name` (nil: the starting page).
struct MusicDNAPage: View {
    let name: String?
    var body: some View { Text(name ?? "Music DNA").navigationTitle("Music DNA") }
}
