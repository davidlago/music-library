import MusicLibraryCore
import SwiftUI

/// Where an item's digital copy stands, in a word or two with its icon: "Ripped", "Not ripped", "8 of 12 songs",
/// "From your CD #142", "Digital copy missing". `compact` (list cells) leaves out a full digital copy, the usual
/// case, and shortens the longer ones. Shared by the Mac and iPhone apps.
public struct DigitalStatusLabel: View {
    let state: DigitalState
    let medium: CollectionMedium
    /// Looks up the copy the music came from (`DigitalState.otherCopy`'s `from`).
    var collection: MusicCollection?
    var compact: Bool

    public init(state: DigitalState, medium: CollectionMedium, collection: MusicCollection? = nil, compact: Bool = false) {
        self.state = state
        self.medium = medium
        self.collection = collection
        self.compact = compact
    }

    public var body: some View {
        if let status = Self.describe(state, medium: medium, from: source, compact: compact) {
            HStack(spacing: 3) {
                Image(systemName: status.icon)
                Text(status.text)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private var source: CollectionItem? {
        guard case .otherCopy(_, let id?) = state else { return nil }
        return collection?.item(id: id)
    }

    /// The words and the SF Symbol for a state, or nil when `compact` leaves it out.
    public static func describe(_ state: DigitalState, medium: CollectionMedium, from: CollectionItem? = nil,
                                compact: Bool = false) -> (text: String, icon: String)? {
        switch state {
        case .digitized:
            if compact { return nil }
            let text = switch medium {
            case .cd: "Ripped"
            case .download: "Downloaded"
            case .vinyl, .other: "Digitized"
            }
            return (text, "checkmark.circle")
        case .partial(let have, let of):
            return ("\(have) of \(of) songs", "circle.lefthalf.filled")
        case .otherCopy:
            if let sticker = from?.sticker { return ("From your \(sticker.text)", "arrow.triangle.2.circlepath") }
            if let from { return ("From your \(from.medium.name.lowercased())", "arrow.triangle.2.circlepath") }
            return (compact ? "From elsewhere" : "Same album, from elsewhere", "arrow.triangle.2.circlepath")
        case .none:
            switch medium {
            case .cd: return ("Not ripped", "waveform.slash")
            case .download: return ("Not imported", "questionmark.circle")
            case .vinyl, .other: return ("Not digitized", "waveform.slash")
            }
        case .missing:
            return (compact ? "Missing" : "Digital copy missing", "exclamationmark.triangle")
        }
    }
}
