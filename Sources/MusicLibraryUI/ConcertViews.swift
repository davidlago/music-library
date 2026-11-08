import MusicLibraryCore
import SwiftUI

// The parts of a concert row both apps draw the same way. The rows themselves stay in each app: the Mac's leads
// with the artist on the Concerts page and has hover and a pasteboard menu, the iPhone's wraps and shares.

/// A calendar-page date: "NOV" over "2", the weekday under it.
public struct ConcertDateTile: View {
    let day: PurchaseDay

    public init(day: PurchaseDay) {
        self.day = day
    }

    public var body: some View {
        let date = day.date()
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(AppColor.accent)
            Text(date.formatted(.dateTime.day())).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 56)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColor.fill))
    }
}

/// "Cancelled", "Postponed" or "Rescheduled" in an orange capsule; nothing for a scheduled show.
public struct ConcertStatusBadge: View {
    let status: Concert.Status

    public init(status: Concert.Status) {
        self.status = status
    }

    public var body: some View {
        let label: String? = switch status {
        case .cancelled: "Cancelled"
        case .postponed: "Postponed"
        case .rescheduled: "Rescheduled"
        case .scheduled: nil
        }
        if let label {
            Text(label).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
                .foregroundStyle(.orange)
        }
    }
}

extension Concert {
    /// The tour or festival, or who else is playing besides `pageArtist` ("with A, B and C and more").
    public func extraLine(besides pageArtist: String) -> String? {
        if let title = title(for: pageArtist) { return title }
        let others = otherActs(than: pageArtist)
        guard !others.isEmpty else { return nil }
        let shown = others.prefix(3)
        return "with " + ListFormatter.localizedString(byJoining: Array(shown)) + (others.count > 3 ? " and more" : "")
    }

    /// "from $45", when the listing has a price.
    public var priceLine: String? {
        guard let price = minPrice, price > 0, let currency else { return nil }
        return "from " + price.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }
}
