import MusicLibraryCore
import SwiftUI

struct CDView: View {
    @Environment(AppModel.self) private var model
    @Bindable var disc: CDDisc
    @State private var showWrongAlbum = false
    @State private var askOwnership = false

    private var hasExactMatch: Bool { disc.candidates.contains { $0.exactMatch } }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            if let warning = disc.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }
            lookupStatus
            if disc.lookup == .matched { wrongAlbumSection }
            if disc.release != nil { CDOwnershipPanel(disc: disc) }
            trackList
            Divider()
            footer.padding(12)
        }
        .navigationTitle(disc.title)
        .onAppear { showWrongAlbum = disc.lookup == .matched && !hasExactMatch }
        .onChange(of: disc.lookup) { _, new in
            if new == .matched { showWrongAlbum = !hasExactMatch }
        }
        .onChange(of: disc.owned) { if disc.ownershipSaved { model.cd.saveOwnership(disc) } }
        .onChange(of: disc.purchasedOn) { if disc.ownershipSaved { model.cd.saveOwnership(disc) } }
        .onChange(of: disc.price) { if disc.ownershipSaved { model.cd.saveOwnership(disc) } }
        .sheet(isPresented: $askOwnership) { CDOwnershipSheet(disc: disc) { model.cd.rip(disc) }.themedSheet() }
    }

    @ViewBuilder
    private var wrongAlbumSection: some View {
        if !hasExactMatch {
            Label("No exact match for this disc on MusicBrainz — these releases have a similar track layout. Check the album before ripping.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
        }
        DisclosureGroup("Not the right album?", isExpanded: $showWrongAlbum) {
            VStack(alignment: .leading, spacing: 10) {
                searchControls
                Button("Rip to Import Queue") { model.cd.ripToImportQueue(disc) }
                    .disabled(disc.isRipping || disc.selectedCount == 0 || !model.ffmpegAvailable)
                    .help("Rip the checked tracks to FLAC and match them in the Import queue")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            DataImage(data: disc.cover, size: 160)
            VStack(alignment: .leading, spacing: 6) {
                Text(disc.release?.album ?? disc.volume.name).font(.title2.bold()).lineLimit(2)
                if let release = disc.release {
                    Text(release.albumArtist).font(.title3).foregroundStyle(.subtext)
                    Text(details(release)).font(.callout).foregroundStyle(.subtext)
                } else {
                    Text("Audio CD · \(disc.volume.toc.audioTracks.count) tracks · \(formatTime(totalDuration))")
                        .font(.callout).foregroundStyle(.subtext)
                }
                if disc.candidates.count > 0 { editionPicker }
                Spacer(minLength: 0)
                HStack {
                    Button("Eject", systemImage: "eject") { model.cd.eject(disc) }.disabled(disc.isRipping)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 160)
    }

    private var totalDuration: Double { disc.rows.reduce(0) { $0 + $1.duration } }

    private func details(_ r: ReleaseInfo) -> String {
        let year = (r.originalYear ?? r.year).map(String.init) ?? ""
        let ext = disc.selectedCandidate
        return [year, r.label, r.catalogNumber, r.country, ext?.format ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var editionPicker: some View {
        Picker("Edition", selection: Binding(
            get: { disc.selectedCandidateID ?? "" },
            set: { id in
                if let c = disc.candidates.first(where: { $0.id == id }) { Task { await model.cd.select(disc, candidate: c) } }
            })
        ) {
            ForEach(disc.candidates) { c in Text(label(c)).tag(c.id) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 520)
        .disabled(disc.isRipping)
    }

    private func label(_ c: DiscRelease) -> String {
        let meta = [c.date, c.country, [c.label, c.catalogNumber].filter { !$0.isEmpty }.joined(separator: " "), c.mediumCount > 1 ? "\(c.mediumCount) discs" : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return (c.exactMatch ? "✓ " : "") + "\(c.title) — \(c.artist) (\(meta))"
    }

    // MARK: Lookup status

    @ViewBuilder
    private var lookupStatus: some View {
        switch disc.lookup {
        case .looking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up disc on MusicBrainz…").foregroundStyle(.subtext)
                Spacer()
            }
            .padding(10)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).lineLimit(2)
                Spacer()
                Button("Retry") { Task { await model.cd.lookup(disc) } }
            }
            .padding(10)
        case .notFound:
            notFoundPanel
        case .matched:
            EmptyView()
        }
    }

    private var notFoundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This disc isn't in MusicBrainz yet.").font(.headline)
            Text("Search for the album by name, submit this disc so it is known next time, or rip the tracks to the import queue and match them there.")
                .font(.callout).foregroundStyle(.subtext)
            searchControls
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Album", text: $disc.searchAlbum)
                TextField("Artist", text: $disc.searchArtist)
                Button("Search") { Task { await model.cd.searchManually(disc) } }
                    .disabled(disc.isSearching || disc.isRipping || (disc.searchAlbum.isEmpty && disc.searchArtist.isEmpty))
                if disc.isSearching { ProgressView().controlSize(.small) }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await model.cd.searchManually(disc) } }
            if let message = disc.message { Text(message).font(.callout).foregroundStyle(.subtext) }
            Button("Submit this disc to MusicBrainz…") { model.cd.submit(disc) }
        }
    }

    // MARK: Tracks

    private var trackList: some View {
        List {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { disc.rows.allSatisfy { $0.selected || $0.status.isFinished } },
                    set: { model.cd.toggleAll(disc, $0) })
                )
                .labelsHidden().disabled(disc.isRipping)
                Text("#").frame(width: 28, alignment: .trailing)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                Text("Artist").frame(width: 180, alignment: .leading)
                Text("Time").frame(width: 50, alignment: .trailing)
                Text("Status").frame(width: 170, alignment: .leading)
            }
            .font(.caption.bold()).foregroundStyle(.subtext)

            ForEach($disc.rows) { $row in
                HStack(spacing: 10) {
                    Toggle("", isOn: $row.selected)
                        .labelsHidden()
                        .disabled(disc.isRipping || row.status.isFinished)
                    Text("\(row.id)").monospacedDigit().foregroundStyle(.subtext).frame(width: 28, alignment: .trailing)
                    Text(row.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.artist).lineLimit(1).foregroundStyle(.subtext).frame(width: 180, alignment: .leading)
                    Text(formatTime(row.duration)).monospacedDigit().foregroundStyle(.subtext).frame(width: 50, alignment: .trailing)
                    statusView(row).frame(width: 170, alignment: .leading)
                }
            }
        }
        .themedScrollBackground()
    }

    @ViewBuilder
    private func statusView(_ row: CDDisc.Row) -> some View {
        if row.status == .done || row.status == .inLibrary, let track = disc.libraryTracks[row.id], let check = model.ripChecks[track.id],
           check.result == .inaccurate {
            HStack(spacing: 8) {
                RipMisreadLabel(check: check)
                Button("Rip Again") { model.cd.ripAgain(disc, track: row.id) }
                    .controlSize(.small)
                    .disabled(disc.isRipping || disc.isChecking)
                    .help("Rip the track again and keep the new rip if AccurateRip confirms it")
            }
        } else {
            plainStatus(row.status)
        }
    }

    @ViewBuilder
    private func plainStatus(_ status: CDDisc.RowStatus) -> some View {
        switch status {
        case .pending:
            Text("")
        case .ripping(let f):
            ProgressView(value: f).frame(width: 110)
        case .importing:
            HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Importing").font(.caption) }
        case .done:
            Label("Imported", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .queued:
            Label("Sent to Import", systemImage: "tray.and.arrow.down").font(.caption).foregroundStyle(.subtext)
        case .inLibrary:
            Text("In library").font(.caption).foregroundStyle(.subtext)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var accurateRipStatus: some View {
        let checks = disc.libraryTracks.values.compactMap { model.ripChecks[$0.id] }.filter { $0.result != .unchecked }
        if disc.isChecking {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking with AccurateRip…") }.font(.callout)
        } else if let error = disc.checkError {
            Label("Couldn't check with AccurateRip: \(error)", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).lineLimit(2)
        } else if !checks.isEmpty {
            let accurate = checks.filter { $0.result == .accurate }.count
            let misread = checks.filter { $0.result == .inaccurate }.count
            Group {
                if checks.allSatisfy({ $0.result == .notListed }) {
                    Text("This CD isn't in AccurateRip yet.")
                } else if misread > 0 {
                    Text("AccurateRip: \(misread) misread, \(accurate) of \(checks.count) accurate").foregroundStyle(.red)
                } else {
                    Text("AccurateRip: \(accurate) of \(checks.count) accurate")
                }
            }
            .font(.callout)
            .help(disc.driveOffset.map { "Drive read offset: \($0 > 0 ? "+" : "")\($0) samples" } ?? "")
        }
    }

    private var overallFraction: Double {
        let selected = disc.rows.filter(\.selected)
        guard !selected.isEmpty else { return 0 }
        let sum = selected.reduce(0.0) { acc, r in
            switch r.status {
            case .done, .queued, .inLibrary, .importing: return acc + 1
            case .ripping(let f): return acc + f
            default: return acc
            }
        }
        return sum / Double(selected.count)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if disc.isRipping {
                VStack(alignment: .leading, spacing: 4) {
                    Text(disc.statusLine).font(.callout)
                    ProgressView(value: overallFraction)
                }
                Button("Cancel") { model.cd.cancel(disc) }
            } else {
                if !model.ffmpegAvailable {
                    Label("ffmpeg is required for ripping", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                accurateRipStatus
                Spacer()
                if !disc.libraryTracks.isEmpty {
                    Button("Check with AccurateRip") { Task { await model.cd.checkRips(disc) } }
                        .disabled(disc.isChecking || !model.ffmpegAvailable)
                        .help("Compare the library's rips of this disc with other people's rips in AccurateRip")
                }
                if disc.release == nil {
                    Button("Rip to Import Queue") { model.cd.ripToImportQueue(disc) }
                        .disabled(disc.selectedCount == 0 || !model.ffmpegAvailable || disc.lookup == .looking)
                        .help("Rip the checked tracks to FLAC and match them in the Import queue")
                }
                Button("Rip \(disc.selectedCount) Track\(disc.selectedCount == 1 ? "" : "s")") {
                    if disc.owned == nil { askOwnership = true } else { model.cd.rip(disc) }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(disc.release == nil || disc.selectedCount == 0 || !model.ffmpegAvailable)
            }
        }
    }
}
