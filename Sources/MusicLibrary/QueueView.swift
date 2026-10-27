import MusicLibraryCore
import SwiftUI

/// The queue in the window's inspector: the current song, songs queued with Play Next, then the rest of
/// the list (what playback started from, plus anything added with Add to Queue). Double-click plays a song, drag reorders, Delete removes.
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<PlayQueue.Entry.ID>()

    var body: some View {
        let player = model.player
        let queue = player.queue
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.title3.bold())
                Spacer()
                Button { model.showsQueue = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide Queue")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            List(selection: $selection) {
                if let current = queue.currentEntry {
                    Section("Now Playing") {
                        QueueRow(track: current.track, isCurrent: true)
                    }
                }
                if !queue.queued.isEmpty {
                    Section {
                        ForEach(queue.queued) { QueueRow(track: $0.track).tag($0.id) }
                            .onMove { player.moveQueued(from: $0, to: $1) }
                    } header: {
                        HStack {
                            Text("Next in Queue")
                            Spacer()
                            Button("Clear") { player.clearQueued(); selection = [] }
                                .buttonStyle(.borderless)
                                .help("Remove all queued songs")
                        }
                    }
                }
                if !queue.upcoming.isEmpty {
                    Section(queue.source.map { "Next From: \($0)" } ?? "Next Up") {
                        ForEach(queue.upcoming) { QueueRow(track: $0.track).tag($0.id) }
                            .onMove { player.moveUpcoming(from: $0, to: $1) }
                    }
                }
            }
            .contextMenu(forSelectionType: PlayQueue.Entry.ID.self) { ids in
                if !ids.isEmpty {
                    if ids.count == 1, let id = ids.first { Button("Play") { player.jump(to: id) } }
                    Button("Remove from Queue") { remove(ids) }
                }
            } primaryAction: { ids in
                if let id = queue.entries.first(where: { ids.contains($0.id) })?.id { player.jump(to: id) }
            }
            .onDeleteCommand { remove(selection) }
            .overlay {
                if queue.current == nil {
                    ContentUnavailableView("Nothing Playing", systemImage: "list.bullet",
                                           description: Text("Right-click songs, albums or playlists and choose Add to Queue."))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func remove(_ ids: Set<PlayQueue.Entry.ID>) {
        model.player.removeFromQueue(ids)
        selection.subtract(ids)
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var isCurrent = false

    var body: some View {
        HStack(spacing: 10) {
            CoverThumb(url: model.coverURL(for: track), size: 36, revision: model.coverRevision)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(AppColor.accent) : AnyShapeStyle(.primary))
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(formatTime(track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(isCurrent ? track.title : "Double-click to play")
    }
}

/// "Play Next" and "Add to Queue" for context menus. `tracks` is only evaluated when one is chosen.
struct QueueMenuButtons: View {
    let player: Player
    let tracks: () -> [Track]

    var body: some View {
        Button("Play Next") { player.playNext(tracks()) }
        Button("Add to Queue") { player.addToQueue(tracks()) }
    }
}
