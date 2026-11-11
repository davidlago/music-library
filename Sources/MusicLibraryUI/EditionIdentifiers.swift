import MusicLibraryCore
import SwiftUI

/// A Discogs release's codes: its matrix/runouts first (monospaced, what to compare with the dead wax or a CD's inner
/// ring), then barcodes and the rest, and the plant that pressed it. With `use`, each runout has a **Use for** menu of
/// the copy's sides (`sides`, named as `RunoutSides.name` names them) that puts it on that side; the side Discogs says
/// it's on (`RunoutSides.side`) is the button's own choice. Shared by the Mac and iPhone apps.
public struct DiscogsIdentifierList: View {
    let release: DiscogsRelease
    var limit: Int
    var medium: CollectionMedium
    var sides: [String]
    var use: ((DiscogsIdentifier, Int) -> Void)?

    public init(release: DiscogsRelease, limit: Int = 24, medium: CollectionMedium = .vinyl, sides: [String] = [],
                use: ((DiscogsIdentifier, Int) -> Void)? = nil) {
        self.release = release
        self.limit = limit
        self.medium = medium
        self.sides = sides
        self.use = use
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runouts and codes on Discogs").font(.subheadline.weight(.semibold))
            if release.identifiers.isEmpty {
                Text("Discogs lists no runouts or codes for this edition.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(release.identifiers.prefix(limit)) { code in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(code.value)
                            .font(code.isRunout ? .callout.monospaced() : .callout)
                            .textSelection(.enabled)
                        Text([code.type, code.description].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let use, code.isRunout, !sides.isEmpty {
                        Spacer(minLength: 8)
                        useMenu(code, use)
                    }
                }
            }
            if release.identifiers.count > limit {
                Text("And \(release.identifiers.count - limit) more on Discogs").font(.caption).foregroundStyle(.secondary)
            }
            if !release.pressedBy.isEmpty {
                Text("Pressed by \(release.pressedBy.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// "Use for Side A" (the side Discogs names) with every side in its menu, or "Use for" when Discogs doesn't say.
    @ViewBuilder
    private func useMenu(_ code: DiscogsIdentifier, _ use: @escaping (DiscogsIdentifier, Int) -> Void) -> some View {
        let suggested = RunoutSides.side(of: code, medium: medium).flatMap { $0 < sides.count ? $0 : nil }
            ?? (sides.count == 1 ? 0 : nil)
        let menu = Group {
            ForEach(Array(sides.enumerated()), id: \.offset) { i, name in
                Button(name) { use(code, i) }
            }
        }
        Group {
            if let suggested {
                Menu("Use for \(sides[suggested])") { menu } primaryAction: { use(code, suggested) }
            } else {
                Menu("Use for") { menu }
            }
        }
        .fixedSize()
        .help("Put this runout on one of your copy's sides, replacing what that side has")
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        #endif
    }
}

/// "VG+ / VG" for a copy's media and sleeve grades, or nil when neither is set.
public enum GradeText {
    public static func pair(media: CollectionGrade?, sleeve: CollectionGrade?) -> String? {
        switch (media, sleeve) {
        case (nil, nil): nil
        case (let m?, nil): m.short
        case (nil, let s?): "Sleeve \(s.short)"
        case (let m?, let s?): "\(m.short) / \(s.short)"
        }
    }
}
