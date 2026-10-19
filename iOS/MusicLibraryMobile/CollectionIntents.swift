import AppIntents
import MusicLibraryCore
import MusicLibraryGlance

// Siri and Shortcuts: Find by Label, the Collection tab's card as a question ("Find a CD by label in Music Library").
// In the app only; the widgets don't offer it. Like the widget buttons, it uses `PhoneModel.shared`, which loads the
// library first: Siri can start the app in the background.

/// A label series as Siri and Shortcuts offer it (`StickerSeries`).
nonisolated enum LabelSeriesOption: String, AppEnum {
    case cd, vinyl

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Label Series"
    static let caseDisplayRepresentations: [LabelSeriesOption: DisplayRepresentation] = [
        .cd: DisplayRepresentation(title: "CD", synonyms: ["Compact Disc", "Disc"]),
        .vinyl: DisplayRepresentation(title: "Vinyl", synonyms: ["Record", "LP"]),
    ]

    var series: StickerSeries {
        switch self {
        case .cd: .cd
        case .vinyl: .vinyl
        }
    }
}

/// Says what has a label ("CD #12 is Kind of Blue by Miles Davis") and opens it on the Collection tab.
struct FindByLabelIntent: AppIntent {
    static let title: LocalizedStringResource = "Find by Label"
    static let description = IntentDescription("Says which CD or record in your collection has a label number, and opens it.")

    @Parameter(title: "Series", default: .cd)
    var series: LabelSeriesOption

    @Parameter(title: "Number", inclusiveRange: (1, 9_999_999), requestValueDialog: "Which label number?")
    var number: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$series) number \(\.$number)")
    }

    init() {}

    init(series: LabelSeriesOption, number: Int) {
        self.series = series
        self.number = number
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sticker = Sticker(series: series.series, number: number) else {
            return .result(dialog: "Label numbers go from 1 to 9,999,999.")
        }
        guard let items = await PhoneModel.shared.items(labeled: sticker) else {
            return .result(dialog: "There's no library on this iPhone yet.")
        }
        guard let first = items.first else {
            return .result(dialog: "Nothing in your collection has \(sticker.text).")
        }
        let names = items.map(Self.name)
        let dialog: IntentDialog = items.count == 1
            ? "\(sticker.text) is \(names[0])."
            : "\(sticker.text) is on \(items.count) items: \(names.formatted(.list(type: .and)))."
        return .result(opensIntent: OpenCollectionItemIntent(id: first.id), dialog: dialog)
    }

    /// "Kind of Blue by Miles Davis".
    private static func name(_ item: CollectionItem) -> String {
        let album = item.album.isEmpty ? "Unknown Album" : item.album
        return item.artist.isEmpty ? album : "\(album) by \(item.artist)"
    }
}

/// Opens an item's page on the Collection tab (what Find by Label ends with).
struct OpenCollectionItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Collection Item"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Item")
    var id: String

    init() {}

    init(id: String) {
        self.id = id
    }

    func perform() async throws -> some IntentResult {
        let link = GlanceLink.item(id: id)
        await MainActor.run { PhoneModel.shared.pendingLink = link }
        return .result()
    }
}

nonisolated struct MusicLibraryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindByLabelIntent(), phrases: [
            "Find a \(\.$series) by label in \(.applicationName)",
            "Find \(\.$series) by label in \(.applicationName)",
            "Look up a \(\.$series) label in \(.applicationName)",
            "Find by label in \(.applicationName)",
        ], shortTitle: "Find by Label", systemImageName: "number")
    }
}
