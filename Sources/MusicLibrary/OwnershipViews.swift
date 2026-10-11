import MusicLibraryCore
import SwiftUI

// MARK: Money

/// Prices are entered and shown in the currency of the user's locale.
let currencyCode = Locale.current.currency?.identifier ?? "USD"

func formatMoney(_ amount: Decimal, whole: Bool = false) -> String {
    amount.formatted(.currency(code: currencyCode).precision(.fractionLength(whole ? 0 : 2)))
}

// MARK: Fields

/// The purchase date: "Add Date" until one is set, then a date picker with a clear button.
struct PurchaseDateField: View {
    @Binding var day: PurchaseDay?

    var body: some View {
        HStack(spacing: 6) {
            if let day {
                DatePicker("Purchase date", selection: Binding(get: { day.date() }, set: { self.day = PurchaseDay($0) }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden().fixedSize()
                Button { self.day = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.subtext)
                    .help("Clear the purchase date")
            } else {
                Button("Add Date") { self.day = PurchaseDay(Date()) }
                    .help("When you bought it")
            }
        }
    }
}

/// What you paid, in the locale's currency, saved as you type. Text that isn't an amount (or is negative) clears it.
struct PurchasePriceField: View {
    @Binding var price: Decimal?
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(Locale.current.currencySymbol ?? "$").foregroundStyle(.subtext)
            TextField("Price", text: $text, prompt: Text(Decimal(0).formatted(.number.precision(.fractionLength(2)))))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 90)
                .help("What you paid")
                .onSubmit { text = Self.format(price) }
        }
        .onAppear { text = Self.format(price) }
        .onChange(of: text) { let p = Self.parse(text); if p != price { price = p } }
        .onChange(of: price) { if Self.parse(text) != price { text = Self.format(price) } }
    }

    static func format(_ price: Decimal?) -> String {
        price.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
    }

    static func parse(_ text: String) -> Decimal? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if let symbol = Locale.current.currencySymbol { s = s.replacingOccurrences(of: symbol, with: "") }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let value = try? Decimal.FormatStyle.number.parseStrategy.parse(s) else { return nil }
        return AlbumPurchase.validPrice(value)
    }
}

// MARK: Album page

/// "Your Copy" on the album page: whether you own the album and, if so, when you bought it and what you paid.
struct AlbumOwnershipSection: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    /// All-time plays of the album's tracks.
    let plays: Int
    /// What was entered before switching ownership off, restored if it's switched back on.
    @State private var draft: AlbumPurchase?

    var body: some View {
        let purchase = model.purchase(for: album)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Copy")
            Toggle("I own this album", isOn: Binding(get: { purchase != nil }, set: { setOwned($0) }))
                .toggleStyle(.switch)
            if let purchase {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Bought").foregroundStyle(.subtext)
                        PurchaseDateField(day: field(\.purchasedOn))
                    }
                    GridRow {
                        Text("Paid").foregroundStyle(.subtext)
                        PurchasePriceField(price: field(\.price))
                    }
                }
                .font(.callout)
                if let summary = summary(purchase) {
                    Text(summary).font(.caption).foregroundStyle(.subtext)
                }
            }
        }
        .onChange(of: album.id) { draft = nil }
    }

    private func setOwned(_ on: Bool) {
        if on {
            model.setPurchase(draft ?? AlbumPurchase(album: album.album, artist: album.artist), for: album)
        } else {
            draft = model.purchase(for: album)
            model.setPurchase(nil, for: album)
        }
    }

    /// A binding to one field of the saved purchase; every change is saved.
    private func field<T>(_ path: WritableKeyPath<AlbumPurchase, T>) -> Binding<T> {
        Binding(get: { (model.purchase(for: album) ?? AlbumPurchase(album: album.album, artist: album.artist))[keyPath: path] },
                set: { value in
                    guard var p = model.purchase(for: album) else { return }
                    p[keyPath: path] = value
                    model.setPurchase(p, for: album)
                })
    }

    private func summary(_ p: AlbumPurchase) -> String? {
        var parts: [String] = []
        if let day = p.purchasedOn {
            parts.append("Yours since \(day.date().formatted(.relative(presentation: .named)))")
        }
        if let price = p.price, price > 0, plays > 0 {
            parts.append("\(formatMoney(price / Decimal(plays))) a play so far")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: CD ripping

/// "Do you own this CD?" with the purchase date and price, shown above a matched disc's tracks. The answer is saved
/// for the album when ripping starts, and again on any change after that.
struct CDOwnershipPanel: View {
    @Bindable var disc: CDDisc

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "bag").foregroundStyle(.subtext)
            Text("Do you own this CD?").font(.callout.weight(.semibold))
            CDOwnershipPicker(disc: disc)
            if disc.owned == true {
                Divider().frame(height: 18)
                Text("Bought").foregroundStyle(.subtext)
                PurchaseDateField(day: $disc.purchasedOn)
                Text("Paid").foregroundStyle(.subtext)
                PurchasePriceField(price: $disc.price)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }
}

struct CDOwnershipPicker: View {
    @Bindable var disc: CDDisc

    var body: some View {
        Picker("Do you own this CD?", selection: $disc.owned) {
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("Albums you own show up in Insights › Owned, with what you paid")
    }
}

/// Asked when ripping starts before the ownership question was answered.
struct CDOwnershipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var disc: CDDisc
    let rip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Do you own this CD?").font(.title3.bold())
            if let release = disc.release {
                Text("\(release.album) — \(release.albumArtist)").foregroundStyle(.subtext)
            }
            CDOwnershipPicker(disc: disc)
            if disc.owned == true {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Bought").foregroundStyle(.subtext)
                        PurchaseDateField(day: $disc.purchasedOn)
                    }
                    GridRow {
                        Text("Paid").foregroundStyle(.subtext)
                        PurchasePriceField(price: $disc.price)
                    }
                }
            }
            Text("You can change this later on the album's page.").font(.caption).foregroundStyle(.subtext)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(disc.owned == nil ? "Rip Without Answering" : "Rip") { dismiss(); rip() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
