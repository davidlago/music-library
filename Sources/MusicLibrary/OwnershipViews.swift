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

/// The number on the sticker on your copy, saved as you type (digits only; anything else clears it). While empty it
/// offers `suggestion`, the next number in your series, and `taken` names another album with the same number.
struct LabelNumberField: View {
    @Binding var number: Int?
    let suggestion: Int
    var taken: AlbumPurchase?
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("#").foregroundStyle(.subtext)
            TextField("Label number", text: $text, prompt: Text(String(suggestion)))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 70)
                .help("The number on the label you put on this CD")
                .onSubmit { text = Self.format(number) }
            if number == nil {
                Button("Use \(suggestion)") { number = suggestion }
                    .help("The next number in your series")
            } else if let taken {
                Label("Also on \(taken.album)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(1)
                    .help("\(taken.album) — \(taken.artist) has this number too")
            }
        }
        .onAppear { text = Self.format(number) }
        .onChange(of: text) { let n = Self.parse(text); if n != number { number = n } }
        .onChange(of: number) { if Self.parse(text) != number { text = Self.format(number) } }
    }

    static func format(_ number: Int?) -> String { number.map(String.init) ?? "" }

    static func parse(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return Int(s).flatMap(AlbumPurchase.validLabelNumber)
    }
}

// MARK: Album page

/// "Your Copy" on the album page: whether you own the album and, if so, whether you bought the CD or a download, when,
/// what you paid and the CD's label number (the next in the series when you first say you own it).
struct AlbumOwnershipSection: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    /// All-time plays of the album's tracks.
    let plays: Int
    /// What was entered before switching ownership off, restored if it's switched back on.
    @State private var draft: AlbumPurchase?

    var body: some View {
        // What you said about the album, else a download made of the songs you bought from it.
        let record = model.purchaseRecord(for: album)
        let purchase = record ?? model.purchase(for: album)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Your Copy")
            Toggle("I own this album", isOn: Binding(get: { purchase != nil }, set: { setOwned($0) }))
                .toggleStyle(.switch)
                // Owned through its songs: change their prices on the Import page, or edit the details below.
                .disabled(record == nil && purchase != nil)
            if record == nil, let songs = songsBought() {
                Text(songs).font(.callout).foregroundStyle(.subtext)
            }
            if let purchase {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Format").foregroundStyle(.subtext)
                        Picker("Format", selection: field(\.format)) {
                            Text("CD").tag(AlbumPurchase.Format.cd)
                            Text("Download").tag(AlbumPurchase.Format.digital)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Whether you bought the CD or the album as a download")
                    }
                    GridRow {
                        Text("Bought").foregroundStyle(.subtext)
                        PurchaseDateField(day: field(\.purchasedOn))
                    }
                    GridRow {
                        Text("Paid").foregroundStyle(.subtext)
                        PurchasePriceField(price: field(\.price))
                    }
                    if purchase.format == .cd {
                        GridRow {
                            Text("Label").foregroundStyle(.subtext)
                            LabelNumberField(number: field(\.labelNumber), suggestion: AlbumPurchase.nextLabelNumber(in: model.purchases),
                                             taken: purchase.labelNumber.flatMap {
                                                 AlbumPurchase.album(labeled: $0, in: model.purchases, excluding: AlbumInfoStore.key(album))
                                             })
                        }
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
            model.setPurchase(draft ?? AlbumPurchase(album: album.album, artist: album.artist,
                                                     labelNumber: AlbumPurchase.nextLabelNumber(in: model.purchases)), for: album)
        } else {
            draft = model.purchaseRecord(for: album)
            model.setPurchase(nil, for: album)
        }
    }

    /// "From the 3 of 12 songs you bought as downloads", for an album owned through its songs (entered when importing them).
    private func songsBought() -> String? {
        let tracks = model.tracks(of: album)
        let bought = tracks.filter { model.trackPurchases[$0.id] != nil }.count
        guard bought > 0 else { return nil }
        if bought == tracks.count { return bought == 1 ? "From the song you bought as a download." : "From the \(bought) songs you bought as downloads." }
        return "From the \(bought) of \(tracks.count) songs you bought as downloads."
    }

    /// A binding to one field of the album's purchase; every change is saved. Editing an album owned through its songs
    /// saves what's shown as the album's own details, which then take their place.
    private func field<T>(_ path: WritableKeyPath<AlbumPurchase, T>) -> Binding<T> {
        Binding(get: { (model.purchaseRecord(for: album) ?? model.purchase(for: album) ?? AlbumPurchase(album: album.album, artist: album.artist))[keyPath: path] },
                set: { value in
                    guard var p = model.purchaseRecord(for: album) ?? model.purchase(for: album) else { return }
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

/// "Do you own this CD?" with the purchase date, price and label number, shown above a matched disc's tracks. The
/// answer is saved for the album when ripping starts, and again on any change after that.
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
                Text("Label").foregroundStyle(.subtext)
                CDLabelNumberField(disc: disc)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }
}

/// The disc's label number; another album with the same number is pointed out.
struct CDLabelNumberField: View {
    @Environment(AppModel.self) private var model
    @Bindable var disc: CDDisc

    var body: some View {
        LabelNumberField(number: $disc.labelNumber, suggestion: model.cd.nextLabelNumber(),
                         taken: disc.labelNumber.flatMap { AlbumPurchase.album(labeled: $0, in: model.purchases, excluding: disc.albumKey) })
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
                    GridRow {
                        Text("Label").foregroundStyle(.subtext)
                        CDLabelNumberField(disc: disc)
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
        .frame(width: 440)
    }
}
