import AppKit
import MusicLibraryCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var importer = model.importer
        HSplitView {
            List(selection: $importer.selection) {
                ForEach(importer.entries) { entry in
                    ImportRow(entry: entry).tag(entry.id)
                        .contextMenu { Button("Remove") { importer.remove(entry) } }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            .themedScrollBackground()
            .overlay {
                if importer.entries.isEmpty {
                    ContentUnavailableView("Nothing to Import", systemImage: "square.and.arrow.down",
                                           description: Text("Drop audio files or folders anywhere in the window, or press ⌘O."))
                        .allowsHitTesting(false)
                }
            }
            Group {
                if let entry = importer.selectedEntry {
                    ImportDetail(entry: entry).id(entry.id)
                } else {
                    ContentUnavailableView("Select an item", systemImage: "music.note")
                }
            }
            .frame(minWidth: 480)
        }
        .navigationTitle("Import")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Files…", systemImage: "plus") { model.chooseFilesToImport() }
                Button("Import All Ready (\(importer.readyCount))", systemImage: "square.and.arrow.down.on.square") {
                    Task { await importer.importAllReady() }
                }
                .disabled(importer.readyCount == 0)
                Button("Clear Finished", systemImage: "trash") { importer.clearFinished() }
            }
        }
    }
}

struct ImportRow: View {
    let entry: ImportEntry

    var color: Color {
        switch entry.status {
        case .ready, .done: return .green
        case .failed: return .red
        case .duplicate: return .orange
        case .needsReview: return .yellow
        default: return .secondary
        }
    }

    var body: some View {
        HStack {
            if case .matching = entry.status { ProgressView().controlSize(.small) }
            else if case .importing = entry.status { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle).lineLimit(1)
                Text(entry.metadata.artist.isEmpty ? entry.url.lastPathComponent : entry.metadata.artist)
                    .font(.caption).foregroundStyle(.subtext).lineLimit(1)
                Text(entry.status.label).font(.caption2).foregroundStyle(color).lineLimit(2)
            }
        }
    }
}

struct ImportDetail: View {
    @Environment(AppModel.self) private var model
    @Bindable var entry: ImportEntry
    @State private var pick: String?

    private var importer: ImportController { model.importer }
    private var editable: Bool { entry.status != .importing && entry.status != .done && entry.status != .duplicate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 20) {
                    form
                    coverColumn
                }
                .disabled(!editable)
                candidatesSection.disabled(!editable)
                actions
            }
            .padding(20)
        }
        .onAppear { pick = entry.selectedCandidateID }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.url.lastPathComponent).font(.title3.bold()).lineLimit(1)
            Text(entry.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.subtext).lineLimit(1)
            HStack {
                Text(entry.status.label).foregroundStyle(.subtext)
                if let note = entry.note { Text("· \(note)").foregroundStyle(.subtext) }
            }
            .font(.callout)
        }
    }

    private var form: some View {
        Form {
            TextField("Title", text: $entry.metadata.title)
            TextField("Artist", text: $entry.metadata.artist)
            TextField("Album", text: $entry.metadata.album)
            TextField("Album Artist", text: $entry.metadata.albumArtist)
            TextField("Year", value: $entry.metadata.year, format: .number.grouping(.never))
            HStack {
                TextField("Track", value: $entry.metadata.trackNo, format: .number.grouping(.never))
                TextField("of", value: $entry.metadata.trackTotal, format: .number.grouping(.never))
            }
            HStack {
                TextField("Disc", value: $entry.metadata.discNo, format: .number.grouping(.never))
                TextField("of", value: $entry.metadata.discTotal, format: .number.grouping(.never))
            }
            TextField("Genre", text: $entry.metadata.genre)
            TextField("Composer", text: $entry.metadata.composer)
            TextField("Lyricist", text: $entry.metadata.extended.lyricist)
            TextField("Label", text: $entry.metadata.extended.label)
            TextField("Catalog #", text: $entry.metadata.extended.catalogNumber)
            DisclosureGroup("More details & credits") {
                MetadataDetailsView(metadata: entry.metadata).padding(.top, 4)
            }
        }
        .frame(minWidth: 280)
    }

    private var coverColumn: some View {
        VStack(spacing: 8) {
            DataImage(data: entry.previewCover, size: 170)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    importer.setCover(entry, from: u)
                    return true
                }
            Text(entry.cover != nil ? "New cover" : (entry.item?.embeddedCover != nil ? "Embedded cover" : "No cover"))
                .font(.caption).foregroundStyle(.subtext)
            HStack {
                Button("Choose Image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK, let u = panel.url { importer.setCover(entry, from: u) }
                }
                if entry.cover != nil { Button("Reset") { entry.cover = nil } }
            }
            .controlSize(.small)
        }
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matches").font(.headline)
            HStack {
                TextField("Title", text: $entry.searchTitle)
                TextField("Artist", text: $entry.searchArtist)
                TextField("Album", text: $entry.searchAlbum)
                Button("Search") { Task { await importer.search(entry) } }
                    .disabled(entry.status == .matching)
                if model.acoustID != nil {
                    Button("Fingerprint") { Task { await importer.fingerprint(entry) } }
                        .disabled(entry.status == .matching)
                        .help("Identify this file with AcoustID")
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await importer.search(entry) } }

            Table(entry.candidates, selection: $pick) {
                TableColumn("") { c in CandidateThumb(candidate: c) }.width(40)
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("Year") { Text($0.year.map(String.init) ?? "") }.width(45)
                TableColumn("Type") { Text(([$0.releaseType, $0.releaseStatus].compactMap { $0 } + $0.secondaryTypes).joined(separator: " · ")) }.width(150)
                TableColumn("Score") { Text("\($0.score)").monospacedDigit() }.width(45)
            }
            .frame(height: 260)
            .themedScrollBackground()
            .onChange(of: pick) {
                if let id = pick, let c = entry.candidates.first(where: { $0.id == id }), id != entry.selectedCandidateID {
                    Task { await importer.choose(entry, candidate: c) }
                }
            }
            .overlay {
                if entry.candidates.isEmpty && entry.status != .matching {
                    Text("No matches. Edit the search fields and press Search.").foregroundStyle(.subtext).allowsHitTesting(false)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            if let release = entry.appliedRelease {
                Button("Apply “\(release.album)” to other queued items") { importer.applyRelease(of: entry) }
            }
            Spacer()
            Button("Remove", role: .destructive) { importer.remove(entry) }
            Button("Import") { Task { await importer.importEntry(entry) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!entry.canImport || entry.metadata.title.isEmpty)
        }
    }
}

struct CandidateThumb: View {
    @Environment(AppModel.self) private var model
    let candidate: MatchCandidate
    @State private var data: Data?

    var body: some View {
        DataImage(data: data, size: 32)
            .task(id: candidate.id) { data = await model.importer.thumbnail(for: candidate) }
    }
}
