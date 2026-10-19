import MusicLibraryCore
import SwiftUI

/// Find by Label, at the top of the Collection tab: pick CD or Vinyl, type a number (or step with ‹ ›), and see what
/// has that label and what sits on either side of it on the shelf, so you can go and grab it. Tapping the result opens
/// the item. The series and number are remembered.
struct FindByLabelCard: View {
    @Environment(PhoneModel.self) private var model
    @AppStorage("findSeries") private var series = StickerSeries.cd
    /// 0: not picked yet (the series' highest label is shown).
    @AppStorage("findNumber") private var storedNumber = 0
    /// The field was emptied to type another number: nothing is shown until a digit is typed (or a step or neighbor
    /// is picked), instead of the highest label coming back.
    @State private var cleared = false
    @FocusState private var editing: Bool

    var body: some View {
        let collection = model.collection
        let number = shownNumber(collection)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Find by Label", systemImage: "number").font(.headline)
                Spacer(minLength: 8)
                Picker("Series", selection: Binding(get: { series }, set: { series = $0; storedNumber = 0; cleared = false })) {
                    ForEach(StickerSeries.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(spacing: 10) {
                stepButton(-1, number: number, systemImage: "chevron.left", label: "Previous number")
                HStack(spacing: 4) {
                    Text("#").foregroundStyle(.secondary)
                    TextField("0", text: Binding(get: { number > 0 ? String(number) : "" }, set: { typed in
                        // Any script's digits (Arabic-Indic, full-width…): `Int(String)` reads only ASCII ones.
                        if let n = Sticker.typedNumber(typed), n > 0 {
                            storedNumber = min(n, Sticker.maxNumber)
                            cleared = false
                        } else {
                            cleared = true
                        }
                    }))
                    .keyboardType(.numberPad)
                    .focused($editing)
                    .fixedSize()
                    // Room for the # to stay put while typing, centred as a whole.
                    .frame(minWidth: 30)
                }
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
                .onTapGesture { editing = true }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(series.name) label number")
                // Left empty: show the number it had again.
                .onChange(of: editing) { if !editing { cleared = false } }
                stepButton(1, number: number, systemImage: "chevron.right", label: "Next number")
            }
            if let sticker = Sticker(series: series, number: number) {
                result(sticker, collection)
            }
        }
        .padding(16)
        .card()
        .toolbar {
            if editing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }

    /// The number typed, else the series' highest label (1 when it has none); 0 while the field is empty.
    private func shownNumber(_ c: MusicCollection) -> Int {
        if cleared { return 0 }
        if storedNumber > 0 { return storedNumber }
        return max(c.nextNumber(in: series) - 1, 1)
    }

    private func stepButton(_ step: Int, number: Int, systemImage: String, label: String) -> some View {
        Button {
            storedNumber = min(max(number + step, 1), Sticker.maxNumber)
            cleared = false
        } label: {
            Image(systemName: systemImage).font(.title3.weight(.semibold)).frame(width: 30, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
        .disabled(step < 0 ? number <= 1 : number >= Sticker.maxNumber)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func result(_ sticker: Sticker, _ c: MusicCollection) -> some View {
        let hits = c.items(at: sticker)
        let neighbors = c.neighbors(of: sticker)
        VStack(alignment: .leading, spacing: 10) {
            if hits.isEmpty {
                // Past the highest label, the number to use is the next one, whatever was typed (as on the Mac).
                let next = c.nextNumber(in: sticker.series)
                HStack(spacing: 10) {
                    Image(systemName: "tag").foregroundStyle(.secondary)
                    Text(sticker.number >= next ? "\(sticker.series.name) #\(next) is the next free number" : "\(sticker.text) is free")
                        .font(.headline)
                }
                .padding(.vertical, 4)
            } else {
                if hits.count > 1 {
                    Label("\(sticker.text) is on \(hits.count) items", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(hits) { item in
                    NavigationLink(value: CollectionItemRoute(id: item.id)) { hit(item, c) }
                        .buttonStyle(.plain)
                }
            }
            if neighbors.previous != nil || neighbors.next != nil {
                HStack(alignment: .top, spacing: 8) {
                    neighbor(neighbors.previous, leading: true)
                    Spacer(minLength: 0)
                    neighbor(neighbors.next, leading: false)
                }
            }
        }
    }

    private func hit(_ item: CollectionItem, _ c: MusicCollection) -> some View {
        let state = c.digitalState(item)
        return HStack(spacing: 12) {
            CopyArt(mark: c.mark(item: item), url: model.library?.coverURL(item: item), width: 96, title: item.album)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.album.isEmpty ? "Unknown Album" : item.album).font(.headline).lineLimit(2)
                Text(item.artist.isEmpty ? "Unknown Artist" : item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                let meta = [item.year.map(String.init), item.formatDetail].compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                DigitalStatusLabel(item: item, state: state, collection: c).font(.caption)
            }
            Spacer(minLength: 4)
            InsightChevron()
        }
        .contentShape(Rectangle())
    }

    /// The labeled item just before or after the number, which jumps to it.
    @ViewBuilder
    private func neighbor(_ item: CollectionItem?, leading: Bool) -> some View {
        if let item, let sticker = item.sticker {
            Button {
                storedNumber = sticker.number
                cleared = false
            } label: {
                HStack(spacing: 4) {
                    if leading { Image(systemName: "arrow.left") }
                    VStack(alignment: leading ? .leading : .trailing, spacing: 1) {
                        Text(sticker.text).font(.caption.weight(.semibold).monospacedDigit())
                        Text(item.album).font(.caption2).lineLimit(1)
                    }
                    if !leading { Image(systemName: "arrow.right") }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 150, alignment: leading ? .leading : .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(leading ? "Before it" : "After it"): \(sticker.spoken), \(item.album)")
        }
    }
}
