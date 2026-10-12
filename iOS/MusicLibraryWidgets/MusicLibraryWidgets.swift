import SwiftUI
import WidgetKit

/// The widgets: on the iPhone's home and lock screens, and as complications on the watch (where they show what the
/// watch app last received from the phone).
@main
struct MusicLibraryWidgets: WidgetBundle {
    var body: some Widget {
        ListeningWidget()
        NowPlayingWidget()
        PurchasesWidget()
        #if os(iOS)
        RediscoverWidget()
        LibraryWidget()
        #endif
    }
}
