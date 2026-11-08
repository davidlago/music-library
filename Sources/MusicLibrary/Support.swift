import AppKit
import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

extension Track {
    var yearSort: Int { year ?? 0 }
    var trackSort: Int { trackNo ?? 0 }
    var formatSort: String { audioFormat?.codec ?? format }
    var formatLabel: String { audioFormat?.compact ?? format.uppercased() }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "3 hr 12 min", "2 days 4 hr"
func formatLongDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return formatTime(seconds) }
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
    f.unitsStyle = .short
    f.maximumUnitCount = 2
    return f.string(from: seconds) ?? formatTime(seconds)
}

/// Listening time: "—" for none, "52 sec" under a minute, then "3 hr, 12 min".
func formatListened(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 1 else { return "—" }
    return seconds < 60 ? "\(Int(seconds)) sec" : formatLongDuration(seconds)
}

func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n.formatted()) songs" }

struct CoverThumb: View {
    let url: URL?
    var size: CGFloat = 140
    /// Pass `AppModel.coverRevision` so a replaced cover.jpg is loaded again.
    var revision = 0
    /// What you own (`CopyMark`): a label pill in the top-left corner and badges in the bottom-right
    /// (`CoverCopyMark`). Never for a cover inside a `JewelCase` or `RecordSleeve`: give it to the case instead.
    var mark: CopyMark?
    /// 0 for a booklet in a `JewelCase`.
    var cornerRadius: CGFloat = 6
    /// Whether the music is only in iCloud: a cloud badge beside the mark's (`CopyBadges`).
    var iCloud: ICloudPlacement = .onMac
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.system(size: size / 3)).foregroundStyle(.secondary)
            }
            if mark != nil || iCloud != .onMac {
                CoverCopyMark(mark: mark, size: size, iCloud: iCloud)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(url?.path ?? "")|\(revision)") {
            guard let url else { image = nil; return }
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

struct DataImage: View {
    let data: Data?
    var size: CGFloat = 160

    var body: some View {
        ZStack {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "photo").font(.system(size: size / 4)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
