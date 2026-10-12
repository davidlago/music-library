import Foundation

/// The sample library's made-up artists and albums. Every name, bio and song here is fictional.
enum SampleCatalog {
    struct Artist {
        var name: String
        var type: String
        var country: String
        var begin: String
        var genres: [String]
        var bio: String
        var palette: Artwork.Palette
    }

    struct Album {
        var title: String
        var artist: String
        var year: Int
        var month: Int
        var genre: String
        var label: String
        var type = "Album"
        var lossless = false
        var style: SynthStyle
        var cover: Artwork.Style
        var palette: Artwork.Palette
        var fonts: (title: String, artist: String)
        var letteringColor: Int
        var letteringTop: Bool
        /// When it joined the library.
        var addedDaysAgo: Int
        /// How much it gets played, and how that changed: (days ago it starts, weight) pairs, newest last.
        var affinity: [(from: Int, weight: Double)]
        var composers: [String]
        /// Who plays and produces on every song: (role, name).
        var personnel: [(String, String)]
        var producer: String
        var mixer: String
        var description: String
        /// Purchase day (days ago) and price; nil day and price for owned without details.
        var owned: (daysAgo: Int?, price: String?)?
        var tracks: [Track]
    }

    struct Track {
        var title: String
        var featuring: String? = nil
        var extra: [(String, String)] = []
    }

    static let note = "It's fictional, made up for Music Library's sample library: its songs were synthesized by a small program, so you can try the app without your own music."

    static let artists: [Artist] = [
        Artist(name: "Lumen Harbor", type: "Group", country: "GB", begin: "2014", genres: ["dream pop"],
               bio: "Lumen Harbor is the duo of Elin Marsh and Kofi Adeyemi: slow synthesizer tides, chiming arpeggios and bell-like melodies, recorded (so the story goes) in a disused lighthouse on the Northumberland coast. Their second album, Night Ferries, follows the overnight boats across the North Sea. \(note)",
               palette: .init(colors: [0x1B2A49, 0x2E6F8E, 0x41B3A3, 0xE8A87C, 0xFCE8C3])),
        Artist(name: "The Velvet Orchard", type: "Group", country: "US", begin: "2011", genres: ["indie folk"],
               bio: "The Velvet Orchard started as Hattie Bell and Jonah Reyes trading songs on a porch in Vermont and grew into a four-piece with Sam Whitlock on bass and Rosa Lindqvist on drums. Warm guitars, brushed drums and tunes you can whistle. \(note)",
               palette: .init(colors: [0x7C5C3B, 0xC8553D, 0xEFE6D8, 0xF4D35E, 0xA3B1A1])),
        Artist(name: "Mara Quell", type: "Person", country: "NO", begin: "1990", genres: ["neoclassical"],
               bio: "Mara Quell writes short, quiet pieces for electric piano late at night, with the window open. Her EP Small Hours was recorded in single takes between two and four in the morning. She also plays on Lumen Harbor's Glass Water. \(note)",
               palette: .init(colors: [0x111111, 0x2B2B2B, 0xE8E2D6, 0xC9A227])),
        Artist(name: "Circuit Garden", type: "Group", country: "CA", begin: "2015", genres: ["synthwave"],
               bio: "Circuit Garden is Dex Calloway and Priya Raman: square waves, four-on-the-floor drums and a fondness for houseplants. Neon Botany imagined a greenhouse at midnight; Overgrowth lets it run wild. \(note)",
               palette: .init(colors: [0x12002B, 0x3D0A5B, 0xC1287A, 0xFFD166, 0x06D6A0])),
        Artist(name: "Juniper & the Low Tide", type: "Group", country: "NZ", begin: "2019", genres: ["lo-fi hip hop"],
               bio: "Juniper Hale makes dusty, slow beats from electric piano chords and a drum machine with a sticky snare, with friends from Wellington's Low Tide collective. Best heard on a rainy Sunday. \(note)",
               palette: .init(colors: [0x3D405B, 0x9A8C98, 0xE9B1A6, 0xA8DADC, 0xF2CC8F])),
        Artist(name: "Okapi Sound System", type: "Group", country: "GB", begin: "2009", genres: ["dub"],
               bio: "Okapi Sound System is a Bristol collective led by bassist Marcus Obi: deep bass, offbeat chords and long echoes, at the tempo of a very relaxed animal. \(note)",
               palette: .init(colors: [0x2B2118, 0x6B4226, 0xF26419, 0xF6AE2D, 0xFFE8A3])),
    ]

    static let albums: [Album] = [
        Album(title: "Tidewater Lights", artist: "Lumen Harbor", year: 2019, month: 9, genre: "Dream Pop", label: "Driftwood Records",
              style: SynthStyle(tempo: 84...96, scales: [.major, .dorian], drums: .pop, chords: .pad, arp: .pluck, lead: .bell, bass: .round, reverb: 0.45),
              cover: .waves, palette: .init(colors: [0x1B2A49, 0xE8A87C, 0x2E6F8E, 0x41B3A3, 0xFCE8C3]),
              fonts: ("AvenirNext-DemiBold", "AvenirNext-Medium"), letteringColor: 4, letteringTop: true,
              addedDaysAgo: 840, affinity: [(840, 1.6), (300, 1.0)],
              composers: ["Elin Marsh", "Kofi Adeyemi"],
              personnel: [("synthesizer", "Elin Marsh"), ("guitar", "Kofi Adeyemi"), ("programming", "Kofi Adeyemi")],
              producer: "Theo Navarro", mixer: "Ines Okafor",
              description: "Lumen Harbor's debut drifts between ambient and pop: pads that swell like a tide coming in, plucked arpeggios, and melodies played on something that sounds like a lighthouse bell.",
              owned: (838, "14.99"),
              tracks: [Track(title: "Harbor Lights"), Track(title: "Paper Lanterns"), Track(title: "Low Tide Choir"),
                       Track(title: "Salt & Static"), Track(title: "Lighthouse Hours")]),
        Album(title: "Night Ferries", artist: "Lumen Harbor", year: 2023, month: 4, genre: "Dream Pop", label: "Driftwood Records",
              style: SynthStyle(tempo: 78...92, scales: [.minor, .dorian], drums: .pop, chords: .pad, arp: .bell, lead: .pluck, bass: .round, reverb: 0.5),
              cover: .night, palette: .init(colors: [0x0B1026, 0x26315F, 0x0E1A33, 0xF4EBC1, 0xF6C35B, 0x1C1C1C]),
              fonts: ("AvenirNext-DemiBold", "AvenirNext-Medium"), letteringColor: 3, letteringTop: false,
              addedDaysAgo: 120, affinity: [(120, 2.4), (40, 1.6)],
              composers: ["Elin Marsh", "Kofi Adeyemi"],
              personnel: [("synthesizer", "Elin Marsh"), ("guitar", "Kofi Adeyemi"), ("synthesizer", "Priya Raman"), ("drums", "Rosa Lindqvist")],
              producer: "Theo Navarro", mixer: "Ines Okafor",
              description: "A darker, roomier second album about overnight crossings: slower tempos, bells over the water and Mara Quell's electric piano on Glass Water.",
              owned: nil,
              tracks: [Track(title: "Night Ferry"), Track(title: "Northbound"),
                       Track(title: "Glass Water", featuring: "Mara Quell", extra: [("piano", "Mara Quell")]),
                       Track(title: "Signal Fires"), Track(title: "Last Crossing")]),
        Album(title: "Apples in Winter", artist: "The Velvet Orchard", year: 2016, month: 11, genre: "Indie Folk", label: "Paper Moon",
              style: SynthStyle(tempo: 96...112, scales: [.major], drums: .brushes, chords: .strum, arp: .none, lead: .sine, bass: .folk, reverb: 0.25),
              cover: .horizon, palette: .init(colors: [0xEFE6D8, 0xC8553D, 0xA3B1A1, 0x7C8C7A, 0x4F5D4F, 0x2F2A26]),
              fonts: ("Baskerville-SemiBoldItalic", "Baskerville"), letteringColor: 5, letteringTop: true,
              addedDaysAgo: 1020, affinity: [(1020, 3.0), (200, 0.5), (70, 0.05)],
              composers: ["Hattie Bell", "Jonah Reyes"],
              personnel: [("guitar", "Hattie Bell"), ("flute", "Jonah Reyes"), ("bass", "Sam Whitlock"), ("drums", "Rosa Lindqvist")],
              producer: "Hattie Bell", mixer: "Ines Okafor",
              description: "Recorded around a wood stove over one snowed-in week: strummed guitars, brushed drums and a flute carrying the tunes.",
              owned: (1018, "12.99"),
              tracks: [Track(title: "Apples in Winter"), Track(title: "Woodstove"), Track(title: "The Long Field"), Track(title: "Frost on the Wire")]),
        Album(title: "Kitchen Radio", artist: "The Velvet Orchard", year: 2021, month: 5, genre: "Indie Folk", label: "Paper Moon",
              style: SynthStyle(tempo: 100...116, scales: [.major], drums: .brushes, chords: .strum, arp: .none, lead: .epiano, bass: .folk, reverb: 0.2),
              cover: .kitchen, palette: .init(colors: [0xF3E9D2, 0xD1495B, 0x2F6690, 0xF4D35E, 0xF3E9D2]),
              fonts: ("AmericanTypewriter-Bold", "AmericanTypewriter"), letteringColor: 2, letteringTop: true,
              addedDaysAgo: 560, affinity: [(560, 1.4), (100, 0.9)],
              composers: ["Hattie Bell", "Jonah Reyes"],
              personnel: [("guitar", "Hattie Bell"), ("piano", "Jonah Reyes"), ("bass", "Sam Whitlock"), ("drums", "Rosa Lindqvist")],
              producer: "Jonah Reyes", mixer: "Ines Okafor",
              description: "Brighter and quicker than its predecessor, with Jonah Reyes's electric piano taking the melodies.",
              owned: (555, "13.49"),
              tracks: [Track(title: "Kitchen Radio"), Track(title: "Sunday Bread"), Track(title: "Porch Light Waltz"), Track(title: "Letters Home")]),
        Album(title: "Small Hours", artist: "Mara Quell", year: 2020, month: 2, genre: "Neoclassical", label: "Quiet Room", type: "EP", lossless: true,
              style: SynthStyle(tempo: 64...76, scales: [.minor, .major], drums: .none, chords: .epiano, arp: .none, lead: .epiano, bass: .none, reverb: 0.55, length: 30...38),
              cover: .minimal, palette: .init(colors: [0x111111, 0xE8E2D6, 0xC9A227]),
              fonts: ("Didot-Italic", "Didot"), letteringColor: 1, letteringTop: true,
              addedDaysAgo: 430, affinity: [(430, 1.2)],
              composers: ["Mara Quell"],
              personnel: [("piano", "Mara Quell")],
              producer: "Mara Quell", mixer: "Ines Okafor",
              description: "Three short pieces for electric piano, each recorded in a single take in the middle of the night.",
              owned: (428, "9.99"),
              tracks: [Track(title: "2:14 a.m."), Track(title: "Streetlamp Etude"), Track(title: "Small Hours")]),
        Album(title: "Neon Botany", artist: "Circuit Garden", year: 2018, month: 6, genre: "Synthwave", label: "Greenhouse Audio",
              style: SynthStyle(tempo: 108...118, scales: [.minor], drums: .fourOnFloor, chords: .pad, arp: .square, fastArp: true, lead: .square, bass: .pulse, reverb: 0.2),
              cover: .synthSun, palette: .init(colors: [0x12002B, 0x3D0A5B, 0xC1287A, 0xFFD166, 0xEF476F, 0x0A0A1F, 0x06D6A0]),
              fonts: ("Futura-Bold", "Futura-Medium"), letteringColor: 3, letteringTop: true,
              addedDaysAgo: 700, affinity: [(700, 1.5), (250, 1.2)],
              composers: ["Dex Calloway", "Priya Raman"],
              personnel: [("synthesizer", "Dex Calloway"), ("synthesizer", "Priya Raman"), ("programming", "Dex Calloway")],
              producer: "Dex Calloway", mixer: "Ines Okafor",
              description: "Square-wave arpeggios, four-on-the-floor drums and a striped sunset: a night drive through a greenhouse.",
              owned: (695, "18.00"),
              tracks: [Track(title: "Neon Botany"), Track(title: "Photosynthesizer"), Track(title: "Chrome Ivy"),
                       Track(title: "Midnight Greenhouse"), Track(title: "Pollen Drive")]),
        Album(title: "Overgrowth", artist: "Circuit Garden", year: 2024, month: 10, genre: "Synthwave", label: "Greenhouse Audio",
              style: SynthStyle(tempo: 112...122, scales: [.minor, .dorian], drums: .fourOnFloor, chords: .pad, arp: .square, fastArp: true, lead: .bell, bass: .pulse, reverb: 0.25),
              cover: .jungle, palette: .init(colors: [0x0B3D2E, 0x041F1A, 0x2D6A4F, 0x40916C, 0x95D5B2, 0xFF5D8F]),
              fonts: ("Futura-Bold", "Futura-Medium"), letteringColor: 4, letteringTop: false,
              addedDaysAgo: 9, affinity: [(9, 4.0)],
              composers: ["Dex Calloway", "Priya Raman"],
              personnel: [("synthesizer", "Dex Calloway"), ("synthesizer", "Priya Raman")],
              producer: "Theo Navarro", mixer: "Ines Okafor",
              description: "Circuit Garden's third record lets the plants take over: brighter bells, busier drums and a guest turn from Juniper & the Low Tide.",
              owned: nil,
              tracks: [Track(title: "Overgrowth"), Track(title: "Root Access"),
                       Track(title: "Bloom Protocol", featuring: "Juniper & the Low Tide", extra: [("keyboards", "Juniper Hale")]),
                       Track(title: "Canopy Run")]),
        Album(title: "Sunday Static", artist: "Juniper & the Low Tide", year: 2022, month: 1, genre: "Lo-Fi Hip Hop", label: "Low Tide Tapes",
              style: SynthStyle(tempo: 76...86, scales: [.dorian, .minor], drums: .boomBap, chords: .epiano, arp: .none, lead: .sine, bass: .round, swing: 0.3, reverb: 0.3, lofi: true),
              cover: .window, palette: .init(colors: [0xE9B1A6, 0x9A8C98, 0x3D405B, 0xA8DADC, 0xF2CC8F, 0x81B29A]),
              fonts: ("Optima-Bold", "Optima-Regular"), letteringColor: 2, letteringTop: true,
              addedDaysAgo: 300, affinity: [(300, 2.0), (60, 2.6)],
              composers: ["Juniper Hale"],
              personnel: [("keyboards", "Juniper Hale"), ("drum machine", "Juniper Hale"), ("bass", "Marcus Obi")],
              producer: "Theo Navarro", mixer: "Juniper Hale",
              description: "Dusty electric piano chords, a lazy swing and the sound of rain on a skylight.",
              owned: (290, "11.00"),
              tracks: [Track(title: "Sunday Static"), Track(title: "Rain on the Skylight"), Track(title: "Coffee Rings"),
                       Track(title: "Library Card"), Track(title: "Slow Walk Home")]),
        Album(title: "Slow Motion Safari", artist: "Okapi Sound System", year: 2017, month: 7, genre: "Dub", label: "Riverbank Sound",
              style: SynthStyle(tempo: 68...76, scales: [.minor], drums: .oneDrop, chords: .skank, arp: .none, lead: .sine, bass: .dub, reverb: 0.3, echo: true),
              cover: .savanna, palette: .init(colors: [0xF6AE2D, 0xF26419, 0xFFE8A3, 0x6B4226, 0x2B2118, 0x2B2118]),
              fonts: ("HelveticaNeue-CondensedBlack", "HelveticaNeue-Medium"), letteringColor: 4, letteringTop: true,
              addedDaysAgo: 960, affinity: [(960, 1.0), (400, 0.7)],
              composers: ["Marcus Obi"],
              personnel: [("bass", "Marcus Obi"), ("melodica", "Lena Fischer"), ("bass", "Sam Whitlock")],
              producer: "Marcus Obi", mixer: "Marcus Obi",
              description: "Half-speed one-drop rhythms, offbeat chords dissolving into echo, and a melodica wandering over the top.",
              owned: (nil, nil),
              tracks: [Track(title: "Slow Motion Safari"), Track(title: "Savanna Dub"), Track(title: "Okapi Skank"), Track(title: "Heat Haze")]),
    ]

    /// Playlists: name and (album, track number) pairs.
    static let playlists: [(String, [(String, Int)])] = [
        ("Morning Coffee", [("Kitchen Radio", 2), ("Sunday Static", 3), ("Small Hours", 2), ("Apples in Winter", 2),
                            ("Sunday Static", 1), ("Kitchen Radio", 1), ("Tidewater Lights", 2), ("Slow Motion Safari", 4)]),
        ("Late Night Drive", [("Neon Botany", 5), ("Night Ferries", 1), ("Overgrowth", 4), ("Neon Botany", 3), ("Night Ferries", 4),
                              ("Slow Motion Safari", 2), ("Overgrowth", 3), ("Neon Botany", 1), ("Night Ferries", 5)]),
        ("Deep Focus", [("Small Hours", 1), ("Tidewater Lights", 3), ("Sunday Static", 5), ("Small Hours", 3),
                        ("Tidewater Lights", 5), ("Sunday Static", 2), ("Night Ferries", 2), ("Small Hours", 2)]),
    ]

    static let smartPlaylists: [(String, String)] = [
        ("Lossless", "is:lossless"),
        ("Recently Added", "added:60d"),
    ]
}
