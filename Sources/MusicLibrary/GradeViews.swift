import MusicLibraryCore
import MusicLibraryUI
import SwiftUI

/// A grade menu (none, then Mint down to Poor; a sleeve's also Generic, Not graded and No cover).
struct GradePicker: View {
    let part: GradingNotes.Part
    @Binding var grade: CollectionGrade?

    var body: some View {
        Picker(part.name, selection: $grade) {
            Text("Not set").tag(CollectionGrade?.none)
            ForEach(part.grades, id: \.self) { g in
                Text(g.isMediaGrade ? "\(g.short) · \(g.name)" : g.name).tag(CollectionGrade?.some(g))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 200, alignment: .leading)
        .help(grade.map { GradingNotes.summary($0, part: part) } ?? "Not graded yet")
    }
}

/// A copy's two grades as two rows of a `Grid` (Record or Disc, then Sleeve or Case), each with the guide a click
/// away.
struct CopyGradeRows: View {
    let medium: CollectionMedium
    @Binding var media: CollectionGrade?
    @Binding var sleeve: CollectionGrade?
    @State private var guide: GradingNotes.Part?

    private var mediaPart: GradingNotes.Part { medium == .cd ? .cd : .record }

    var body: some View {
        GridRow {
            Text(medium == .cd ? "Disc" : "Record").foregroundStyle(.secondary)
            HStack(spacing: 6) {
                GradePicker(part: mediaPart, grade: $media)
                guideButton(mediaPart)
            }
        }
        GridRow {
            Text(medium == .cd ? "Case" : "Sleeve").foregroundStyle(.secondary)
            HStack(spacing: 6) {
                GradePicker(part: .sleeve, grade: $sleeve)
                guideButton(.sleeve)
            }
            .sheet(item: $guide) { part in
                GradingGuideSheet(part: part, mediaPart: mediaPart, media: $media, sleeve: $sleeve)
            }
        }
    }

    private func guideButton(_ part: GradingNotes.Part) -> some View {
        Button {
            guide = part
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Grading Guide: what each grade means, with drawings")
    }
}

/// The grading guide in a sheet with a Done button.
/// Clicking a grade gives it to the copy (its record or disc, or its sleeve) and keeps the guide open, so the other
/// part can be graded too.
struct GradingGuideSheet: View {
    let part: GradingNotes.Part
    let mediaPart: GradingNotes.Part
    @Binding var media: CollectionGrade?
    @Binding var sleeve: CollectionGrade?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grading Guide").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)
            GradingGuide(part: part, parts: [mediaPart, .sleeve],
                         selected: { $0 == .sleeve ? sleeve : media },
                         choose: { part, grade in
                             if part == .sleeve { sleeve = grade } else if grade.isMediaGrade { media = grade }
                         })
        }
        .frame(width: 620, height: 700)
    }
}

/// Opens the popover with a Discogs release's runouts and codes, looked up when it opens, to compare with the copy's
/// dead wax and copy into its Runouts.
struct DiscogsRunoutsButton: View {
    @Environment(AppModel.self) private var model
    let releaseID: Int
    let use: ([DiscogsIdentifier]) -> Void
    @State private var showing = false
    @State private var release: DiscogsRelease?
    @State private var failed: String?

    var body: some View {
        Button("Discogs’ Runouts…") { showing = true }
            .buttonStyle(.link)
            .help("See the matrix/runouts Discogs lists for this edition")
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                // A fixed size: a popover takes its content's ideal size, and a scroll view's is next to nothing.
                ScrollView {
                    Group {
                        if let release {
                            DiscogsIdentifierList(release: release) { runouts in
                                use(runouts)
                                showing = false
                            }
                        } else if let failed {
                            Text(failed).foregroundStyle(.secondary)
                        } else {
                            ProgressView("Looking it up on Discogs…")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 400, height: 380)
                .task(id: releaseID) { await load() }
            }
    }

    private func load() async {
        guard release?.id != releaseID else { return }
        failed = nil
        do {
            release = try await model.discogs.release(id: releaseID)
        } catch {
            failed = "Couldn’t look it up on Discogs: \(error.localizedDescription)"
        }
    }
}

enum RunoutText {
    /// The runouts added to what's typed: all of them into an empty field, else only lines not there yet.
    static func adding(_ runouts: [DiscogsIdentifier], to current: String?) -> String {
        let text = DiscogsIdentifierList.runoutText(runouts)
        guard let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let have = Set(current.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let new = text.split(separator: "\n").map(String.init).filter { !have.contains($0) }
        return new.isEmpty ? current : current + "\n" + new.joined(separator: "\n")
    }
}
