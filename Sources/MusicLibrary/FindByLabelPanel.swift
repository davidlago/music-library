import MusicLibraryCore
import SwiftUI

/// Find by Label (⌘L, anywhere): a series and a number, and what's at that spot on your shelf, with its neighbors,
/// so you can go and grab it. ↑/↓ step through the numbers, ⇥ switches between CD and Vinyl, ↩ opens the item.
/// A number is never shown without its series, so CD #12 and Vinyl #12 can't be mixed up.
struct FindByLabelPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("findLabelSeries") private var series = StickerSeries.cd
    @State private var text = ""
    @FocusState private var focused: Bool
    /// The label to open on (typed elsewhere, like the Collection pane's Find a label field).
    var initial: Sticker? = nil

    /// The label typed; "v12" or "cd 12" also pick the series.
    private var sticker: Sticker? {
        guard let form = Sticker.parse(text) else { return nil }
        return Sticker(series: form.series ?? series, number: form.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "number.square").font(.title).foregroundStyle(.secondary)
                Text("Find by Label").font(.title2.bold())
                Spacer()
                Picker("Series", selection: $series) {
                    ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Which labels to look in: CDs and records are numbered apart (⇥ switches)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series == .cd ? "CD #" : "Vinyl #")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                TextField("Label number", text: $text, prompt: Text("12"))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(open)
                    .onKeyPress(.upArrow) { step(1); return .handled }
                    .onKeyPress(.downArrow) { step(-1); return .handled }
                    .onKeyPress(.tab) { flip(); return .handled }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            if let sticker {
                LabelLookupCard(sticker: sticker, open: { item in dismiss(); model.showItem(id: item.id) },
                                step: { set($0) })
            } else {
                Text("Type the number on the label. ↑ ↓ step along the shelf, ⇥ switches between CD and Vinyl, ↩ opens it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let initial { set(initial) }
            focused = true
        }
        .onChange(of: text) {
            // "v12" or "cd 12" typed: the series switches, and the number stays.
            if let form = Sticker.parse(text), let s = form.series {
                series = s
                text = String(form.number)
            }
        }
    }

    private func set(_ sticker: Sticker) {
        series = sticker.series
        text = String(sticker.number)
    }

    /// One number up or down, within the series' numbers.
    private func step(_ delta: Int) {
        let current = sticker?.number ?? (delta > 0 ? 0 : model.nextNumber(in: series))
        let n = min(max(current + delta, 1), Sticker.maxNumber)
        text = String(n)
    }

    private func flip() {
        series = series == .cd ? .vinyl : .cd
    }

    /// Opens the item at the label (the first of a duplicate).
    private func open() {
        guard let sticker, let item = model.collection.items(at: sticker).first else { return }
        dismiss()
        model.showItem(id: item.id)
    }
}

/// What's at a label on your shelf: the item (or every item, for a number used twice), else whether the number is
/// free, with the labeled items either side ("between CD #141 Sketches of Spain and CD #143 Time Out"). The same
/// number in the other series is pointed out by its own label, never mixed in. Used by Find by Label and the
/// Shelf's Go to.
struct LabelLookupCard: View {
    @Environment(AppModel.self) private var model
    let sticker: Sticker
    var coverWidth: CGFloat = 160
    /// Opens an item's page.
    var open: (CollectionItem) -> Void
    /// Moves to another label (a neighbor, or the same number in the other series).
    var step: ((Sticker) -> Void)?

    var body: some View {
        let c = model.collection
        let found = c.items(at: sticker)
        let neighbors = c.neighbors(of: sticker)
        let other = StickerSeries.allCases.first { $0 != sticker.series }
            .flatMap { Sticker(series: $0, number: sticker.number) }
        VStack(alignment: .leading, spacing: 12) {
            if found.isEmpty {
                free
            } else {
                if found.count > 1 {
                    Label("\(sticker.text) is on \(found.count) items", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                }
                ForEach(found) { row($0) }
            }
            if neighbors.previous != nil || neighbors.next != nil {
                neighborsLine(neighbors)
            }
            if let other, let first = c.items(at: other).first {
                HStack(spacing: 6) {
                    Text("Not to be confused with").foregroundStyle(.secondary)
                    StickerPill(sticker: other, size: 10)
                    Text(first.album).lineLimit(1)
                    if let step {
                        Button("Show") { step(other) }.buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColor.separator.opacity(0.6), lineWidth: 0.5))
    }

    /// "CD #157 is free", or past the end "CD #313 is the next free number".
    private var free: some View {
        let next = model.nextNumber(in: sticker.series)
        let text: String
        if sticker.number >= next {
            // Past the end: the number to use is the next one, whichever was typed.
            text = "\(sticker.series.name) #\(next) is the next free number"
        } else {
            text = "\(sticker.text) is free"
        }
        return HStack(spacing: 10) {
            Image(systemName: "circle.dashed").font(.title2).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.medium))
        }
        .frame(minHeight: 44)
    }

    private func row(_ item: CollectionItem) -> some View {
        let c = model.collection
        let state = c.digitalState(item)
        return HStack(alignment: .top, spacing: 16) {
            Button { open(item) } label: {
                CopyArt(mark: c.mark(item: item), url: model.coverURL(for: item), width: coverWidth,
                        revision: model.coverRevision, title: item.album)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                if let s = item.sticker { StickerPill(sticker: s, size: 14) }
                Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.title3.bold()).lineLimit(2)
                Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).foregroundStyle(.secondary).lineLimit(1)
                let meta = [item.year.map(String.init), item.formatDetail, item.recordLabel].compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                DigitalStatusLabel(state: state, medium: item.medium, from: Self.from(state, in: model)).font(.callout)
                if let bought = Self.purchaseLine(item) { Text(bought).font(.callout).foregroundStyle(.secondary) }
                Button("Open") { open(item) }.controlSize(.small).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func neighborsLine(_ n: (previous: CollectionItem?, next: CollectionItem?)) -> some View {
        HStack(spacing: 5) {
            Text("Between").foregroundStyle(.secondary)
            neighbor(n.previous, edge: "the start of the shelf")
            Text("and").foregroundStyle(.secondary)
            neighbor(n.next, edge: "the end")
        }
        .font(.callout)
        .lineLimit(1)
    }

    @ViewBuilder
    private func neighbor(_ item: CollectionItem?, edge: String) -> some View {
        if let item, let s = item.sticker {
            Button {
                if let step { step(s) } else { open(item) }
            } label: {
                HStack(spacing: 4) {
                    StickerPill(sticker: s, size: 10)
                    Text(item.album.isEmpty ? "Unknown Album" : item.album).italic().lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help(step == nil ? "Open \(s.text)" : "Go to \(s.text)")
        } else {
            Text(edge).foregroundStyle(.secondary)
        }
    }

    static func from(_ state: DigitalState, in model: AppModel) -> CollectionItem? {
        if case .otherCopy(_, let id?) = state { return model.item(id: id) }
        return nil
    }

    /// "Bought 3 May 2019 · $12.99".
    static func purchaseLine(_ item: CollectionItem) -> String? {
        var parts: [String] = []
        if let day = item.purchasedOn { parts.append("Bought " + day.date().formatted(date: .long, time: .omitted)) }
        if let price = item.price { parts.append(formatMoney(price)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
