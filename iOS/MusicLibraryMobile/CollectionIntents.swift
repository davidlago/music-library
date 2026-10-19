import AppIntents
import MusicLibraryCore
import MusicLibraryGlance

// Siri and Shortcuts: Find by Label, the Physical tab's card as a question ("Find CD 12 in Music Library").
// In the app only; the widgets don't offer it. Like the widget buttons, it uses `PhoneModel.shared`, which loads the
// library first: Siri can start the app in the background.
//
// App Shortcut phrases can only hold an AppEnum or AppEntity, never a number, so the labels in the collection are
// `LabelEntity`s, offered to Siri as phrase values (`updateAppShortcutParameters` whenever the labels change): "Find
// CD 12 in Music Library" in one go. Shortcuts, and the phrases without a label, take a series and a number.

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

/// A label in the collection ("CD 12"), what the one-go Siri phrases hold. Any label resolves (by its id, "cd12", or
/// typed text, via `Sticker.parse`); Siri is offered the ones in use.
nonisolated struct LabelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Label"
    static let defaultQuery = LabelEntityQuery()

    let sticker: Sticker

    init(_ sticker: Sticker) { self.sticker = sticker }

    /// "cd12", "vinyl12".
    var id: String { "\(sticker.series.rawValue)\(sticker.number)" }

    var displayRepresentation: DisplayRepresentation {
        let n = String(sticker.number)
        let names = sticker.series == .cd ? ["CD"] : ["Vinyl", "Record", "LP"]
        let title = "\(names[0]) \(n)"
        let synonyms = names.flatMap { ["\($0) \(n)", "\($0) number \(n)", "\($0) #\(n)"] }.filter { $0 != title }
        return DisplayRepresentation(title: "\(title)", synonyms: synonyms.map { "\($0)" })
    }
}

nonisolated struct LabelEntityQuery: EntityStringQuery {
    /// Keeps the phrases Siri is given to a sensible number in a very large collection (the lowest labels win).
    static let suggestionLimit = 1000

    func entities(for identifiers: [String]) async throws -> [LabelEntity] {
        identifiers.compactMap(Self.entity)
    }

    func entities(matching string: String) async throws -> [LabelEntity] {
        guard let parsed = Sticker.parse(string) else { return [] }
        return (parsed.series.map { [$0] } ?? StickerSeries.allCases)
            .compactMap { Sticker(series: $0, number: parsed.number).map(LabelEntity.init) }
    }

    func suggestedEntities() async throws -> [LabelEntity] {
        await PhoneModel.shared.labelsInUse().prefix(Self.suggestionLimit).map(LabelEntity.init)
    }

    private static func entity(_ id: String) -> LabelEntity? {
        guard let parsed = Sticker.parse(id), let series = parsed.series,
              let sticker = Sticker(series: series, number: parsed.number) else { return nil }
        return LabelEntity(sticker)
    }
}

/// Says what has a label ("CD #12 is Kind of Blue by Miles Davis") and opens it on the Physical tab.
struct FindByLabelIntent: AppIntent {
    static let title: LocalizedStringResource = "Find by Label"
    static let description = IntentDescription("Says which CD or record in your physical collection has a label number, and opens it.")

    @Parameter(title: "Series", default: .cd)
    var series: LabelSeriesOption

    @Parameter(title: "Number", inclusiveRange: (1, 9_999_999))
    var number: Int?

    /// Set by the one-go Siri phrases ("Find CD 12…"); it wins over the series and number.
    @Parameter(title: "Label")
    var label: LabelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Find \(\.$series) number \(\.$number)") {
            \.$label
        }
    }

    init() {}

    init(series: LabelSeriesOption, number: Int) {
        self.series = series
        self.number = number
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sticker: Sticker
        if let label {
            sticker = label.sticker
        } else {
            guard let number else { throw $number.needsValueError("Which label number?") }
            guard let typed = Sticker(series: series.series, number: number) else {
                return .result(dialog: "Label numbers go from 1 to 9,999,999.")
            }
            sticker = typed
        }
        guard let items = await PhoneModel.shared.items(labeled: sticker) else {
            return .result(dialog: "Nothing has synced to this iPhone yet.")
        }
        guard let first = items.first else {
            return .result(dialog: "Nothing in your physical collection has \(sticker.text).")
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

/// Opens an item's page on the Physical tab (what Find by Label ends with).
struct OpenCollectionItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Physical Collection"
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
            "Find \(\.$label) in \(.applicationName)",
            "Look up \(\.$label) in \(.applicationName)",
            "Where is \(\.$label) in \(.applicationName)",
            "What's \(\.$label) in \(.applicationName)",
            "Find a \(\.$series) by label in \(.applicationName)",
            "Find \(\.$series) by label in \(.applicationName)",
            "Look up a \(\.$series) label in \(.applicationName)",
            "Find by label in \(.applicationName)",
        ], shortTitle: "Find by Label", systemImageName: "number")
    }
}

/// Gives Siri the labels in use as phrase values when they change (`LabelEntityQuery.suggestedEntities`).
enum LabelShortcuts {
    private static var offered: Set<Sticker>?

    static func update(for collection: MusicCollection) {
        let labels = Set(collection.items.compactMap(\.sticker))
        guard labels != offered else { return }
        offered = labels
        MusicLibraryShortcuts.updateAppShortcutParameters()
    }
}
