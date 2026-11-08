import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

/// The art for what you own: a CD (or a library album not in your collection: a borrowed CD) in its `JewelCase`, a
/// record in its `RecordSleeve`, or a flat cover with its badges for a download or another medium. Always as tall as a
/// jewel case `width` wide, so cells line up; a flat cover is that tall and square.
struct CopyArt: View {
    let mark: CopyMark
    let url: URL?
    let width: CGFloat
    /// Drawn on the placeholder when there's no cover.
    var title: String?

    static func height(width: CGFloat) -> CGFloat { JewelCase<EmptyView>.height(width: width) }

    var body: some View {
        switch mark {
        case .cd, .notInCollection:
            JewelCase(width: width, mark: mark) {
                CoverImage(url: url, size: JewelCase<EmptyView>.bookletSide(width: width), cornerRadius: 0, title: title)
            }
        case .vinyl:
            RecordSleeve(width: width, mark: mark) {
                CoverImage(url: url, size: RecordSleeve<EmptyView>.sleeveSide(width: width), cornerRadius: 0, title: title)
            }
        case .download, .other:
            CoverImage(url: url, size: Self.height(width: width), mark: mark, title: title)
                .frame(width: width, alignment: .leading)
        }
    }
}
