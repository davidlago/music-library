import MusicLibraryCore
import SwiftUI

struct AlbumPage: View {
    let album: AlbumSummary
    var body: some View { Text(album.album) }
}
