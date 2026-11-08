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

/// An item's digital copy in a word or two, with an icon unless it's digitized: "Not ripped", "8 of 12 songs",
/// "From your CD #142", "Digital copy missing".
struct DigitalStatusLabel: View {
    let state: DigitalState
    let medium: CollectionMedium
    /// For `.otherCopy`: the copy the music came from (`DigitalState.otherCopy`'s `from`), if one is in the collection.
    var from: CollectionItem?

    var body: some View {
        Group {
            if let symbol {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    var symbol: String? {
        switch state {
        case .digitized: nil
        case .partial: "circle.lefthalf.filled"
        case .otherCopy: "arrow.triangle.2.circlepath"
        case .none: medium.isPhysical ? "waveform.slash" : nil
        case .missing: "exclamationmark.triangle"
        }
    }

    var text: String {
        switch state {
        case .digitized:
            switch medium {
            case .cd: return "Ripped"
            case .download: return "Downloaded"
            case .vinyl, .other: return "Digitized"
            }
        case .partial(let have, let of): return "\(have) of \(of) songs"
        case .otherCopy:
            if let sticker = from?.sticker { return "From your \(sticker.text)" }
            if let from { return "From your \(from.medium.name.lowercased())" }
            return "Same album, from elsewhere"
        case .none:
            switch medium {
            case .cd: return "Not ripped"
            case .download: return "Not imported"
            case .vinyl, .other: return "Not digitized"
            }
        case .missing: return "Digital copy missing"
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
