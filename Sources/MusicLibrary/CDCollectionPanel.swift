import MusicLibraryCore
import SwiftUI

/// On a disc's page (matched, or unknown to MusicBrainz and named by the page's album and artist), above its tracks: the copy in your collection the CD is. An item already there ("This
/// is CD #37 in your collection, not ripped yet. This rip will be linked to it."; a picker when several match),
/// else adding it as a new CD with the next label, or the question "Is this CD yours?" when Settings ▸ Collection
/// asks. An existing item's date, price and label are edited on it at once; a new one's are saved when ripping or
/// cataloging starts, and on every change after that. Saying no never removes an item that was there before.
struct CDCollectionPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var disc: CDDisc

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical").foregroundStyle(.subtext)
                CDCollectionChoiceControl(disc: disc)
                if disc.collectionChoice == .new || disc.itemID != nil {
                    Divider().frame(height: 18)
                    CDCopyFields(disc: disc)
                }
                Spacer(minLength: 0)
            }
            if let line = statusLine {
                Text(line).font(.caption).foregroundStyle(.subtext).padding(.leading, 30)
            }
            if let id = disc.catalogedItemID, let item = model.item(id: id) {
                HStack(spacing: 6) {
                    Label("Saved in your physical collection as \(item.sticker?.text ?? "a CD")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Open") { model.showItem(id: id) }.buttonStyle(.link)
                }
                .font(.caption).padding(.leading, 30)
            }
            if let message = disc.collectionMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(.leading, 30)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }

    /// What happens to the existing copy: "This is CD #37 in your collection, not ripped yet. This rip will be
    /// linked to it."
    private var statusLine: String? {
        guard case .existing(let id)? = disc.collectionChoice, let item = model.item(id: id) else { return nil }
        let name = item.sticker.map { "\($0.text) in your physical collection" } ?? "your CD of “\(item.album)”"
        let state = model.collection.digitalState(item)
        if state.needsDigitizing { return "This is \(name), not ripped yet. This rip will be linked to it." }
        return "This is \(name), ripped."
    }
}

/// Which copy the CD is: a picker of the matching items (plus a new copy and "not mine"), else a switch to add it
/// as a new CD, or Yes/No while unanswered.
struct CDCollectionChoiceControl: View {
    @Environment(AppModel.self) private var model
    @Bindable var disc: CDDisc

    var body: some View {
        let next = disc.newSticker ?? model.cd.nextLabelNumber(for: disc)
        if !disc.matches.isEmpty {
            Picker("This CD is", selection: Binding(get: { disc.collectionChoice }, set: { model.cd.setChoice(disc, $0) })) {
                ForEach(disc.matches) { item in
                    Text(Self.title(item, in: model)).tag(CDCollectionChoice?.some(.existing(item.id)))
                }
                Divider()
                Text(disc.createdItemID != nil ? "A new copy" : "A new copy (CD #\(next))").tag(CDCollectionChoice?.some(.new))
                Text("Not in my physical collection").tag(CDCollectionChoice?.some(.none))
            }
            .fixedSize()
            .help("The CD in your physical collection this disc is: ripping links the rip to it")
        } else if disc.collectionChoice == nil {
            Text("Is this CD yours?").font(.callout.weight(.semibold))
            Picker("Is this CD yours?", selection: Binding(get: { disc.collectionChoice }, set: { model.cd.setChoice(disc, $0) })) {
                Text("Yes").tag(CDCollectionChoice?.some(.new))
                Text("No").tag(CDCollectionChoice?.some(.none))
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("A CD you own is added to your physical collection, with its label number")
        } else {
            Toggle(isOn: Binding(get: { disc.collectionChoice == .new }, set: { model.cd.setChoice(disc, $0 ? .new : CDCollectionChoice.none) })) {
                Text(disc.createdItemID != nil ? "In your physical collection" : "Add to your physical collection as CD #\(next)")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch).controlSize(.small)
            .help(disc.createdItemID != nil ? "Switching off removes the CD this page added to your physical collection"
                  : "Add this CD to your physical collection when ripping starts")
        }
    }

    /// "CD #37 · Not ripped", "CD · Ripped".
    static func title(_ item: CollectionItem, in model: AppModel) -> String {
        let state = model.collection.digitalState(item)
        let name = item.sticker?.text ?? "Your CD (no label)"
        let edition = [item.year.map(String.init), item.country, item.catalogNumber].compactMap { $0 }.joined(separator: " ")
        return [name, edition.isEmpty ? nil : edition, state.needsDigitizing ? "Not ripped" : "Ripped"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Bought, Paid and Label for the CD's copy: the existing item's (each change saved on it), or the new one's.
struct CDCopyFields: View {
    @Environment(AppModel.self) private var model
    @Bindable var disc: CDDisc

    var body: some View {
        if let id = disc.itemID, let item = model.item(id: id) {
            Text("Bought").foregroundStyle(.subtext)
            PurchaseDateField(day: field(item, \.purchasedOn))
            Text("Paid").foregroundStyle(.subtext)
            PurchasePriceField(price: field(item, \.price))
            if item.isEditable {
                Text("Label").foregroundStyle(.subtext)
                StickerField(series: .cd, number: field(item, \.stickerNumber), itemID: item.id)
            }
        } else {
            Text("Bought").foregroundStyle(.subtext)
            PurchaseDateField(day: $disc.newPurchasedOn)
            Text("Paid").foregroundStyle(.subtext)
            PurchasePriceField(price: $disc.newPrice)
            Text("Label").foregroundStyle(.subtext)
            StickerField(series: .cd, number: $disc.newSticker, live: true)
        }
    }

    /// A field of the item as saved now; each change is saved on its own.
    private func field<T: Equatable>(_ item: CollectionItem, _ path: WritableKeyPath<CollectionItem, T>) -> Binding<T> {
        Binding(get: { (model.item(id: item.id) ?? item)[keyPath: path] },
                set: { value in model.changeItem(id: item.id) { $0[keyPath: path] = value } })
    }
}

/// Asked when ripping starts before "Is this CD yours?" was answered.
struct CDCollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var disc: CDDisc
    let rip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Is this CD yours?").font(.title3.bold())
            if let release = disc.release {
                Text("\(release.album) — \(release.albumArtist)").foregroundStyle(.subtext)
            } else if !disc.searchAlbum.isEmpty {
                Text([disc.searchAlbum, disc.searchArtist].filter { !$0.isEmpty }.joined(separator: " — ")).foregroundStyle(.subtext)
            }
            Picker("Is this CD yours?", selection: Binding(get: { disc.collectionChoice }, set: { model.cd.setChoice(disc, $0) })) {
                Text("Yes").tag(CDCollectionChoice?.some(.new))
                Text("No").tag(CDCollectionChoice?.some(.none))
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if disc.collectionChoice == .new {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Label").foregroundStyle(.subtext)
                        StickerField(series: .cd, number: $disc.newSticker, live: true)
                    }
                    GridRow {
                        Text("Bought").foregroundStyle(.subtext)
                        PurchaseDateField(day: $disc.newPurchasedOn)
                    }
                    GridRow {
                        Text("Paid").foregroundStyle(.subtext)
                        PurchasePriceField(price: $disc.newPrice)
                    }
                }
            }
            Text("It's added to your physical collection when ripping starts. You can change it later on its page.")
                .font(.caption).foregroundStyle(.subtext)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(disc.collectionChoice == nil ? "Rip Without Answering" : "Rip") { dismiss(); rip() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
