import AppKit
import MusicLibraryCore
import SwiftUI

/// Sync to Discogs (Physical Collection menu, the Shelf's header): what would change in the user's Discogs collection,
/// with every addition ticked and every removal not, then the changes made.
struct DiscogsSyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = model.discogsSync
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sync to Discogs").font(.title2.bold())
                Text(store.username.map { "Adds your CDs and records to \($0)'s collection on Discogs. Nothing in your collection here changes." }
                     ?? "Adds your CDs and records to your collection on Discogs. Nothing in your collection here changes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer(store)
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled(isSyncing(store))
        .onAppear { if store.isConnected, store.phase == .idle { store.prepare(model: model) } }
        // Connected in Settings while the sheet was open.
        .onChange(of: store.isConnected) { _, connected in if connected, store.phase == .idle { store.prepare(model: model) } }
        .onDisappear { store.reset() }
    }

    private func isSyncing(_ store: DiscogsSyncStore) -> Bool {
        if case .syncing = store.phase { return true }
        return false
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ store: DiscogsSyncStore) -> some View {
        if !store.isConnected {
            ContentUnavailableView {
                Label("Connect Discogs", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Paste a personal access token from your Discogs settings in Settings ▸ Discogs, then sync again.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else {
            switch store.phase {
            case .idle:
                ProgressView()
            case .preparing(let text, let fraction):
                VStack(spacing: 10) {
                    if let fraction { ProgressView(value: fraction).frame(width: 320) } else { ProgressView() }
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("Each CD or record is looked up once; later syncs are quick.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            case .ready:
                if let plan = store.plan { PlanList(plan: plan, store: store, open: open) }
            case .syncing(let done, let total):
                VStack(spacing: 10) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 320)
                    Text("\(done) of \(total) changes made").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            case .finished(let outcome):
                finished(outcome, store: store)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Sync", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { store.prepare(model: model) }
                }
            }
        }
    }

    private func finished(_ outcome: DiscogsSyncOutcome, store: DiscogsSyncStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let parts = [outcome.added > 0 ? "\(outcome.added) added" : nil,
                         outcome.linked > 0 ? "\(outcome.linked) matched to copies already there" : nil,
                         outcome.removed > 0 ? "\(outcome.removed) removed" : nil].compactMap { $0 }
            Label(outcome.cancelled ? "Stopped. What was done is kept." : parts.isEmpty ? "Nothing changed." : parts.joined(separator: " · "),
                  systemImage: outcome.failures.isEmpty && !outcome.cancelled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(outcome.failures.isEmpty && !outcome.cancelled ? .green : .orange)
            if outcome.cancelled, !parts.isEmpty { Text(parts.joined(separator: " · ")).foregroundStyle(.secondary) }
            if !outcome.failures.isEmpty {
                Text("These couldn't be changed:").font(.headline)
                List(outcome.failures, id: \.self) { Text($0).font(.callout) }
                    .listStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private func footer(_ store: DiscogsSyncStore) -> some View {
        HStack {
            if let url = store.username.flatMap({ DiscogsIdentity(id: 0, username: $0).profileURL }) {
                Link("Your Collection on Discogs", destination: url).font(.callout)
            }
            Spacer()
            switch store.phase {
            case .preparing, .syncing:
                Button("Stop") { store.cancel() }
            case .ready:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let plan = store.plan {
                    let count = store.chosenAdditions.count + store.chosenRemovals.count
                    Button(count > 0 ? "Make \(count) Change\(count == 1 ? "" : "s")" : plan.adoptions.isEmpty ? "Done" : "Save Matches") {
                        if count == 0 && plan.adoptions.isEmpty { dismiss() } else { store.sync(model: model) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            default:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Opens an item's page (closing the sheet).
    private func open(_ id: String) {
        dismiss()
        model.showItem(id: id)
    }
}

/// The plan: additions (ticked), removals (not ticked) and items with no Discogs release.
private struct PlanList: View {
    let plan: DiscogsSyncPlan
    @Bindable var store: DiscogsSyncStore
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if plan.additions.isEmpty && plan.removals.isEmpty && plan.unmatched.isEmpty {
                ContentUnavailableView("Discogs Is Up to Date", systemImage: "checkmark.circle",
                                       description: Text(plan.adoptions.isEmpty ? "Every CD and record here is in your Discogs collection."
                                                         : "Save the matches so later syncs know which copy is which."))
            } else {
                List {
                    if !plan.additions.isEmpty { additions }
                    if !plan.removals.isEmpty { removals }
                    if !plan.unmatched.isEmpty { unmatched }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if plan.inSync > 0 { parts.append("\(plan.inSync.formatted()) already on Discogs") }
        if !plan.adoptions.isEmpty {
            parts.append("\(plan.adoptions.count.formatted()) matched to copies already there")
        }
        var text = parts.joined(separator: " · ")
        if store.lookupFailures > 0 {
            text += (text.isEmpty ? "" : ". ") + "\(store.lookupFailures) couldn't be looked up now and will be tried next time."
        }
        let closest = plan.additions.filter { store.qualities[$0.id] == .closest }.count
        if closest > 0 {
            text += (text.isEmpty ? "" : ". ") + "\(closest) found by album only, marked Closest edition: check they're your pressing."
        }
        text += (text.isEmpty ? "" : ". ") + "New copies go in your “\(store.folderName)” folder."
        return text
    }

    private var additions: some View {
        Section {
            ForEach(plan.additions) { a in
                Toggle(isOn: Binding(get: { store.chosenAdditions.contains(a.id) },
                                     set: { if $0 { store.chosenAdditions.insert(a.id) } else { store.chosenAdditions.remove(a.id) } })) {
                    HStack(spacing: 8) {
                        if let sticker = a.item.sticker { StickerPill(sticker: sticker) }
                        itemTitle(a.item)
                        Spacer()
                        if store.qualities[a.id] == .closest {
                            Text("Closest edition").font(.caption).foregroundStyle(.orange)
                                .help("Found by album, country and year: this may be another pressing than yours. Open it on Discogs to check, or pick the edition with Change Edition….")
                        }
                        switch a.reason {
                        case .new: EmptyView()
                        case .removedOnDiscogs: Text("Removed on Discogs").font(.caption).foregroundStyle(.secondary)
                        case .editionChanged: Text("Edition changed").font(.caption).foregroundStyle(.secondary)
                        }
                        releaseLink(a.releaseID)
                    }
                }
            }
        } header: {
            sectionHeader("Add to Discogs", count: plan.additions.count, chosen: store.chosenAdditions.count) {
                store.chosenAdditions = $0 ? Set(plan.additions.map(\.id)) : []
            }
        }
    }

    private var removals: some View {
        Section {
            ForEach(plan.removals) { r in
                Toggle(isOn: Binding(get: { store.chosenRemovals.contains(r.id) },
                                     set: { if $0 { store.chosenRemovals.insert(r.id) } else { store.chosenRemovals.remove(r.id) } })) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.instance.title.isEmpty ? "Release \(r.instance.releaseID)" : r.instance.title).lineLimit(1)
                            Text([r.instance.artist, r.instance.formatDetail, r.instance.year.map(String.init) ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(reason(r.reason)).font(.caption).foregroundStyle(.secondary)
                        releaseLink(r.instance.releaseID)
                    }
                }
            }
        } header: {
            sectionHeader("Remove from Discogs", count: plan.removals.count, chosen: store.chosenRemovals.count) {
                store.chosenRemovals = $0 ? Set(plan.removals.map(\.id)) : []
            }
        } footer: {
            Text("Copies left unticked stay in your Discogs collection.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var unmatched: some View {
        Section {
            ForEach(plan.unmatched) { item in
                HStack(spacing: 8) {
                    if let sticker = item.sticker { StickerPill(sticker: sticker) }
                    itemTitle(item)
                    Spacer()
                    Button("Show") { open(item.id) }.buttonStyle(.link).font(.caption)
                }
            }
        } header: {
            Text("Not Found on Discogs (\(plan.unmatched.count.formatted()))")
        } footer: {
            Text("Pick their Discogs edition with Change Edition… on the item's page (choose Discogs as the source), or add a barcode.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func itemTitle(_ item: CollectionItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.album.isEmpty ? "Untitled" : item.album).lineLimit(1)
            Text([item.artist, item.formatDetail ?? item.medium.name, item.year.map(String.init) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func releaseLink(_ id: Int) -> some View {
        if let url = DiscogsLink.releaseURL(id) {
            Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                .help("Open this release on Discogs")
        }
    }

    private func sectionHeader(_ title: String, count: Int, chosen: Int, all: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text("\(title) (\(count.formatted()))")
            Spacer()
            Button(chosen == count ? "Untick All" : "Tick All") { all(chosen != count) }
                .buttonStyle(.link).font(.caption)
        }
    }

    private func reason(_ reason: DiscogsSyncPlan.Removal.Reason) -> String {
        switch reason {
        case .onlyOnDiscogs: "Not in your collection here"
        case .removedHere: "Removed here"
        case .editionChanged: "Old edition"
        }
    }
}

struct DiscogsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        @Bindable var store = model.discogsSync
        Form {
            Section {
                Text("Sync to Discogs adds the CDs and records in your physical collection to your collection on Discogs. It goes one way: your collection here is never changed, and nothing is removed from Discogs unless you tick it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if let user = store.username, store.hasToken {
                    LabeledContent("Status") {
                        HStack {
                            Label("Connected as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            if let url = DiscogsIdentity(id: 0, username: user).profileURL { Link("Collection", destination: url) }
                            Button("Disconnect") { store.disconnect() }
                        }
                    }
                } else {
                    SecureField("Personal access token", text: $token)
                        .onSubmit { store.connect(token: token) }
                    HStack {
                        Button("Connect") { store.connect(token: token) }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || store.isConnecting)
                        if store.isConnecting { ProgressView().controlSize(.small) }
                    }
                    Link("Generate a token in your Discogs settings (Developers)", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                        .font(.caption)
                }
                if let error = store.connectionError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("The token is stored in your keychain on this Mac and is only sent to Discogs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.isConnected {
                Section("Syncing") {
                    Picker("Add new copies to", selection: $store.folderID) {
                        let folders = store.folders.filter { $0.id > 0 }
                        if folders.isEmpty {
                            Text(store.folderName).tag(store.folderID)
                        } else {
                            ForEach(folders) { Text($0.name).tag($0.id) }
                        }
                    }
                    LabeledContent("Sync") {
                        Button("Sync to Discogs…") { model.syncToDiscogs() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .onAppear { store.loadFolders() }
    }
}
