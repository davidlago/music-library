import MusicLibraryCore
import SwiftUI

struct ArtistPage: View {
    let artist: ArtistSummary
    var body: some View { Text(artist.name) }
}

struct SongInfoSheet: View {
    let track: Track
    var body: some View { Text(track.title) }
}
