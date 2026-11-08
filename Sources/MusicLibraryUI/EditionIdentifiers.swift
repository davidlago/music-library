import MusicLibraryCore
import SwiftUI

/// A Discogs release's codes: its matrix/runouts first (monospaced, what to compare with the dead wax or a CD's inner
/// ring), then barcodes and the rest, and the plant that pressed it. `use` (optional) puts runouts in the copy's
/// Runouts field. Shared by the Mac and iPhone apps.
public struct DiscogsIdentifierList: View {
    let release: DiscogsRelease
    var limit: Int
    var use: (([DiscogsIdentifier]) -> Void)?

    public init(release: DiscogsRelease, limit: Int = 24, use: (([DiscogsIdentifier]) -> Void)? = nil) {
        self.release = release
        self.limit = limit
        self.use = use
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Runouts and codes on Discogs").font(.subheadline.weight(.semibold))
                Spacer()
                if let use, !release.runouts.isEmpty {
                    Button("Use Runouts") { use(release.runouts) }
                        .help("Copy Discogs' matrix/runouts into this copy's Runouts, to trim to the ones on yours")
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
            }
            if release.identifiers.isEmpty {
                Text("Discogs lists no runouts or codes for this edition.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(release.identifiers.prefix(limit)) { code in
                VStack(alignment: .leading, spacing: 1) {
                    Text(code.value)
                        .font(code.isRunout ? .callout.monospaced() : .callout)
                        .textSelection(.enabled)
                    Text([code.type, code.description].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
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

    /// Runouts as a copy's Runouts text: one per line, with where Discogs says each is.
    nonisolated public static func runoutText(_ runouts: [DiscogsIdentifier]) -> String {
        runouts.map { $0.description.isEmpty ? $0.value : "\($0.value) (\($0.description))" }.joined(separator: "\n")
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
