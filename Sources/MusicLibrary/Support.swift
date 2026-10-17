import AppKit
import MusicLibraryCore
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
    /// Your label number for the album (`model.purchase(for:)?.labelNumber`), drawn as a sticker in the corner.
    var labelNumber: Int?
    /// 0 for a booklet in a `JewelCase`.
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.system(size: size / 3)).foregroundStyle(.subtext)
            }
            if let labelNumber { LabelSticker(number: labelNumber, size: size) }
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

/// The white sticker with your label number, in the top-right corner of a cover: like the one on the CD's case.
struct LabelSticker: View {
    let number: Int
    /// The cover's size.
    let size: CGFloat
    /// Smaller on the big covers of album pages.
    var scale: CGFloat = 1

    var body: some View {
        let font = max(9, size * 0.075 * scale)
        Text(String(number))
            .font(.system(size: font, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color(white: 0.1))
            .padding(.horizontal, font * 0.45).padding(.vertical, font * 0.15)
            .background(RoundedRectangle(cornerRadius: font * 0.25).fill(Color(white: 0.98)))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .padding(max(4, size * 0.04))
            .frame(width: size, height: size, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityLabel("Label \(number)")
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
                Image(systemName: "photo").font(.system(size: size / 4)).foregroundStyle(.subtext)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
