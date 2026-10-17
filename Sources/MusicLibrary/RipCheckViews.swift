import MusicLibraryCore
import SwiftUI

extension RipCheck {
    var explanation: String {
        switch result {
        case .unchecked: return "Not checked with AccurateRip yet."
        case .accurate:
            let n = confidence ?? 0
            return "Accurate: bit for bit the same as \(n) other rip\(n == 1 ? "" : "s") of this CD in AccurateRip."
        case .inaccurate:
            return "Doesn't match AccurateRip, where other rips of this CD agree: the disc was misread here. Rip it again from the CD."
        case .unknown:
            return "AccurateRip couldn't tell: nobody submitted this track, or none of the disc's tracks matched (a pressing nobody submitted)."
        case .notListed: return "Nobody has submitted this CD to AccurateRip yet."
        }
    }
}

/// A rip's AccurateRip result, for the CD page's status column.
struct RipCheckLabel: View {
    let check: RipCheck
    var checking = false

    var body: some View {
        Group {
            if checking {
                HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Checking") }
            } else {
                switch check.result {
                case .accurate: Label("Accurate (\(check.confidence ?? 0))", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .inaccurate: Label("Misread", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .unknown: Label("Can't verify", systemImage: "questionmark.circle").foregroundStyle(.subtext)
                case .notListed: Label("Not in AccurateRip", systemImage: "seal").foregroundStyle(.subtext)
                case .unchecked: Label("Imported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .help(check.explanation)
    }
}

/// A small mark next to a track checked with AccurateRip: accurate or misread (other results show nothing).
struct RipCheckMark: View {
    let check: RipCheck?

    var body: some View {
        switch check?.result {
        case .accurate?: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green.opacity(0.8)).help(check!.explanation)
        case .inaccurate?: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(check!.explanation)
        default: EmptyView()
        }
    }
}

/// One line on an album page about its AccurateRip check: in progress, the result, or why it can't be checked.
struct AlbumRipSummary: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    let tracks: [Track]

    var body: some View {
        let state = model.rips.albumStates[AlbumInfoStore.key(album)]
        let checks = tracks.compactMap { model.ripChecks[$0.id] }.filter { $0.result != .unchecked }
        Group {
            if state == .checking {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking with AccurateRip…") }
            } else if case .failed(let message)? = state {
                Label("Couldn't check with AccurateRip: \(message)", systemImage: "exclamationmark.circle").foregroundStyle(.red)
            } else if state == .noDisc {
                Label("Can't check with AccurateRip: none of the CDs MusicBrainz lists for this album matches its files.",
                      systemImage: "questionmark.circle")
            } else if !checks.isEmpty {
                summary(checks)
            }
        }
        .font(.callout)
        .foregroundStyle(.subtext)
    }

    @ViewBuilder
    private func summary(_ checks: [RipCheck]) -> some View {
        let accurate = checks.filter { $0.result == .accurate }.count
        let misread = checks.filter { $0.result == .inaccurate }.count
        if misread > 0 {
            Label("\(misread) track\(misread == 1 ? " doesn't" : "s don't") match AccurateRip: rip \(misread == 1 ? "it" : "them") again from the CD.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if accurate == checks.count {
            Label(accurate == 1 ? "AccurateRip: accurate rip" : "AccurateRip: all \(accurate) tracks accurate", systemImage: "checkmark.seal.fill")
        } else if checks.allSatisfy({ $0.result == .notListed }) {
            Label("This CD isn't in AccurateRip yet.", systemImage: "seal")
        } else {
            Label("AccurateRip: \(accurate) of \(checks.count) tracks accurate, the others can't be verified.", systemImage: "checkmark.seal")
        }
    }
}
