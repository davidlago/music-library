import MusicLibraryCore
import SwiftUI

struct DetailRow: View {
    let label: String
    let value: String
    var labelWidth: CGFloat = 170

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// A label with one or more people's names (each opening their Music DNA) as the value.
struct PeopleRow: View {
    let label: String
    let names: [String]
    var labelWidth: CGFloat = 170
    let open: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
            PersonLinks(names: names, open: open).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct MetadataDetailsView: View {
    let metadata: TrackMetadata
    var labelWidth: CGFloat = 170
    var showsEmptyState = true
    /// Opens a person's Music DNA (see `PersonLink`).
    let openPerson: (String) -> Void

    /// Fields whose values are people's names.
    static let peopleFields: Set<String> = ["Lyricist", "Writer", "Arranger", "Conductor", "Producer", "Engineer", "Mixer", "Remixer", "Performers"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(metadata.extended.displayFields.enumerated()), id: \.offset) { _, field in
                if Self.peopleFields.contains(field.label) {
                    let names = CollaborationGraph.splitNames(field.value).map(CollaborationGraph.stripParenthetical)
                    PeopleRow(label: field.label, names: names, labelWidth: labelWidth, open: openPerson)
                } else {
                    row(field.label, field.value)
                }
            }
            let people = CreditFormatter.grouped(metadata.extended.credits)
            if !people.isEmpty {
                Text("Credits").font(.subheadline.bold()).padding(.top, 6)
                ForEach(Array(people.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline) {
                        PersonLink(name: p.name, open: openPerson)
                            .frame(width: labelWidth, alignment: .trailing)
                        Text(p.roles.joined(separator: ", ")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            if showsEmptyState && metadata.extended.displayFields.isEmpty && people.isEmpty {
                Text("No extra details").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ key: String, _ value: String) -> some View {
        DetailRow(label: key, value: value, labelWidth: labelWidth)
    }
}

struct TrackInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track

    var body: some View {
        let m = track.metadata
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                CoverThumb(url: track.coverURL(root: model.libraryRoot), size: 120, revision: model.coverRevision)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.title).font(.title2.bold())
                    Text(m.artist)
                    Text(m.album).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    info("Album Artist", m.albumArtist)
                    if !m.composer.isEmpty { PeopleRow(label: "Composer", names: CollaborationGraph.splitNames(m.composer), open: openPerson) }
                    info("Year", m.year.map(String.init) ?? "")
                    info("Track", numberPair(m.trackNo, m.trackTotal))
                    info("Disc", numberPair(m.discNo, m.discTotal))
                    info("Genre", m.genre)
                    info("Format", track.format.uppercased())
                    info("Codec", track.audioFormat?.codecLabel ?? "")
                    info("Sample Rate", track.audioFormat?.sampleRate.map { "\(AudioFormat.kHzString(Double($0))) kHz" } ?? "")
                    info("Bit Depth", track.audioFormat?.bitDepth.map { "\($0)-bit" } ?? "")
                    info("Bitrate", track.audioFormat?.bitrate.map { "\(($0 + 500) / 1000) kbps" } ?? "")
                    info("Channels", track.audioFormat?.channels.map(String.init) ?? "")
                    info("Duration", formatTime(track.duration))
                    info("MusicBrainz Recording ID", m.mbRecordingId ?? "")
                    info("MusicBrainz Release ID", m.mbReleaseId ?? "")
                    info("File", track.fileURL(root: model.libraryRoot).path)
                    MetadataDetailsView(metadata: m, openPerson: openPerson)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }

    /// Closes the sheet before showing the person's Music DNA.
    private func openPerson(_ name: String) {
        dismiss()
        model.showMusicDNA(name)
    }

    private func numberPair(_ n: Int?, _ total: Int?) -> String {
        guard let n else { return "" }
        return total.map { "\(n) of \($0)" } ?? "\(n)"
    }

    @ViewBuilder
    private func info(_ key: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(key).foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
                Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }
}
