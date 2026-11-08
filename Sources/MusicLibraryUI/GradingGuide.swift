import MusicLibraryCore
import SwiftUI

// MARK: What each grade means

/// What to look for at each grade, for a record, a CD and a sleeve or case: the guide shown from the grade pickers.
/// The words are the app's own, after the Goldmine scale Discogs uses.
public enum GradingNotes {
    public enum Part: String, CaseIterable, Identifiable, Sendable {
        case record, cd, sleeve

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .record: "Record"
            case .cd: "CD"
            case .sleeve: "Sleeve or case"
            }
        }

        public var grades: [CollectionGrade] { self == .sleeve ? CollectionGrade.sleeve : CollectionGrade.media }
    }

    /// The grade in a sentence, for this part: what decides it.
    public static func summary(_ grade: CollectionGrade, part: Part) -> String {
        switch (part, grade) {
        case (.record, .mint):
            "Perfect in every way, never played. Almost always still sealed: grade an opened record Near Mint at best."
        case (.record, .nearMint):
            "Looks and plays as if it came out of the sleeve for the first time: glossy, unmarked, no added noise."
        case (.record, .veryGoodPlus):
            "Played and handled by a careful owner: light signs of use you can see, but they don't spoil the listening."
        case (.record, .veryGood):
            "Clearly used. Surface noise and clicks in quiet passages and between tracks, but the music comes first."
        case (.record, .goodPlus):
            "Well worn, at the better end of Good: noise throughout, but it plays from start to finish without skipping."
        case (.record, .good):
            "Heavily worn. It still plays through without skipping, but the noise is part of every track."
        case (.record, .fair):
            "Damaged: it skips or repeats in places, or is warped or cracked enough to affect play."
        case (.record, .poor):
            "Barely playable or unplayable: cracked, badly warped, or skipping throughout."
        case (.cd, .mint):
            "Sealed and untouched."
        case (.cd, .nearMint):
            "No marks you can see, even under a light, and it plays perfectly."
        case (.cd, .veryGoodPlus):
            "Light handling marks on the playing side, seen under a light; it plays perfectly."
        case (.cd, .veryGood):
            "Scuffs and scratches you see at a glance, but it still plays all the way through without errors."
        case (.cd, .goodPlus):
            "Well scratched, but it still plays through; a rip may need a second read."
        case (.cd, .good):
            "Heavily scratched: it plays, but some players struggle with it and a rip may come out inaccurate."
        case (.cd, .fair), (.cd, .poor):
            "Skips, won't read, or is cracked or rotting."
        case (.sleeve, .mint):
            "Still in its original shrink wrap: sharp corners and not a mark on it."
        case (.sleeve, .nearMint):
            "Looks new: sharp corners and edges, no ring wear, no creases, no splits, no writing or stickers."
        case (.sleeve, .veryGoodPlus):
            "Lightly handled: faint ring wear or a little wear at the corners and edges, but whole and clean."
        case (.sleeve, .veryGood):
            "Clearly used: ring wear you see straight on, worn corners, creases, perhaps a short split or some writing."
        case (.sleeve, .goodPlus):
            "Well worn but whole: heavy ring wear and worn edges, a split seam or a tape repair, some writing."
        case (.sleeve, .good):
            "Heavily worn: splits along more than one seam, tape, heavy writing or stains, but still in one piece."
        case (.sleeve, .fair), (.sleeve, .poor):
            "Badly damaged: torn, split along most of its seams, pieces missing, water-damaged or written over."
        case (_, .generic):
            "A plain or generic sleeve or case, not the one the album came in."
        case (_, .notGraded):
            "Not looked at closely yet."
        case (_, .noCover):
            "The sleeve or case is missing: only the record or disc is there."
        case (.record, _), (.cd, _):
            ""  // the sleeve-only grades never come up for a record or a disc
        }
    }

    /// What to check, as short points.
    public static func points(_ grade: CollectionGrade, part: Part) -> [String] {
        switch (part, grade) {
        case (.record, .mint):
            ["Never played; sealed copies are the usual Mint",
             "No marks of any kind, no warp, labels perfect"]
        case (.record, .nearMint):
            ["Surface glossy and clean under a bright light",
             "No added surface noise when played",
             "Labels clean: no writing, stickers or spindle marks around the hole",
             "Flat: no warp"]
        case (.record, .veryGoodPlus):
            ["A few light scuffs or fine hairlines you can see but not feel with a fingernail",
             "Plays cleanly; at most a faint tick or a little noise in the quietest moments",
             "A few spindle marks or light wear on the label",
             "A slight warp is fine if it doesn't affect play",
             "Typically worth about half a Near Mint copy"]
        case (.record, .veryGood):
            ["Light scratches you can feel, and groove wear that makes the surface look duller",
             "Surface noise and clicks you hear in quiet parts and in the lead-in and run-out",
             "Writing, stickers or tape on the label",
             "Typically worth about a quarter of a Near Mint copy"]
        case (.record, .goodPlus), (.record, .good):
            ["Heavy scuffing and scratches; the grooves look grey or worn",
             "Noise all the way through, but no skips or repeats",
             "Label worn, torn, written on or stained",
             "Worth a small fraction of Near Mint; a copy to have until a better one turns up"]
        case (.record, .fair), (.record, .poor):
            ["Skips or repeats",
             "Cracked, chipped, or warped enough that the needle won't track",
             "Kept for the sleeve, or because it's rare"]
        case (.cd, .mint):
            ["Factory sealed"]
        case (.cd, .nearMint):
            ["No visible marks on either side of the disc",
             "Case uncracked, booklet and back insert crisp"]
        case (.cd, .veryGoodPlus):
            ["Fine hairlines on the shiny side, seen only under a light",
             "No marks on the label side (the data sits just under it, so damage there is permanent)",
             "Plays without errors or skips"]
        case (.cd, .veryGood):
            ["Scratches and scuffs visible at a glance on the shiny side",
             "Still plays through without skips",
             "A check with AccurateRip after ripping tells you if it reads cleanly"]
        case (.cd, .goodPlus):
            ["Many scratches on the shiny side, a few deep",
             "Plays through; a rip may need Rip Again's extra reads",
             "Label side lightly worn"]
        case (.cd, .good):
            ["Deep scratches all over",
             "Some players skip; a rip may come out inaccurate",
             "Label side worn"]
        case (.cd, .fair), (.cd, .poor):
            ["Won't play or skips badly",
             "Cracked, warped, or the label side is peeling or pinholed (disc rot)"]
        case (.sleeve, .mint):
            ["Original shrink wrap intact",
             "Corners and spine sharp"]
        case (.sleeve, .nearMint):
            ["No ring wear, creases or seam splits",
             "Sharp corners, clean spine",
             "No writing, stickers or price tags (an original hype sticker is fine)",
             "No cut-out mark (a punched hole, clipped corner or saw cut from a remainder bin)",
             "For a CD: case uncracked, booklet and back insert crisp"]
        case (.sleeve, .veryGoodPlus):
            ["Faint ring wear, seen when you tilt it to the light",
             "Slightly worn corners or edges, perhaps a light crease",
             "No seam splits",
             "A small price sticker or a name in a corner, a cut-out mark at most",
             "For a CD: a scuffed case is fine (cases are easily replaced); booklet with light wear"]
        case (.sleeve, .veryGood):
            ["Ring wear you see straight on",
             "Worn corners and edges, creases",
             "A seam split of a few centimetres",
             "Writing, stickers or price tags",
             "For a CD: booklet creased or a little stained"]
        case (.sleeve, .goodPlus):
            ["Heavy ring wear, some fading",
             "A seam split along one side, or taped",
             "Writing or stickers on the front or back",
             "For a CD: booklet torn or heavily creased"]
        case (.sleeve, .good):
            ["Heavy ring wear, fading or discolouring",
             "Seams split along more than one side",
             "Tape repairs, heavy writing, stains or water marks",
             "For a CD: booklet missing pages, back insert damaged"]
        case (.sleeve, .fair), (.sleeve, .poor):
            ["Torn or split along most seams, pieces missing",
             "Heavy water damage, mould or writing all over",
             "For a CD: booklet or back insert missing"]
        case (_, .generic):
            ["A plain paper or card sleeve, a company sleeve, or a CD in a case that isn't its own",
             "Grade the record or disc on its own"]
        case (_, .notGraded):
            ["Leave it until you've had a proper look: a grade guessed too high misleads more than none"]
        case (_, .noCover):
            ["Only the record or disc is there"]
        case (.record, _), (.cd, _):
            []
        }
    }

    /// How to grade, before the grades.
    public static let tips = [
        "Grade the record (or disc) and its sleeve (or case) separately: they're two grades.",
        "Look under a bright lamp, tilting it to catch the light, then play a few minutes of each side, the quiet parts especially.",
        "When the look and the sound disagree, use the lower one.",
        "Be strict. Most played copies are VG+ or VG; Near Mint means hard to tell from new, and Mint usually means sealed.",
        "A mark you can feel with a fingernail is a scratch; one you can only see is a scuff or hairline.",
    ]
}

// MARK: The guide

/// The grading guide: tips, then each grade with a drawing of a copy in that condition and what to look for. The
/// pickers open it with the grade being edited; `part` picks record, CD or sleeve. With `choose`, clicking a grade
/// chooses it for that part (the Mac's editor); without, it's for reading (the iPhone).
public struct GradingGuide: View {
    @State private var part: GradingNotes.Part
    private let parts: [GradingNotes.Part]
    private let selected: (GradingNotes.Part) -> CollectionGrade?
    private let choose: ((GradingNotes.Part, CollectionGrade) -> Void)?
    @State private var hovered: CollectionGrade?

    /// For reading, with `highlighted` outlined under `part`.
    public init(part: GradingNotes.Part = .record, highlighted: CollectionGrade? = nil) {
        _part = State(initialValue: part)
        parts = GradingNotes.Part.allCases
        selected = { [part] p in p == part ? highlighted : nil }
        choose = nil
    }

    /// For choosing: `parts` are the copy's (its record or disc, and the sleeve), `selected` the grade each has now.
    public init(part: GradingNotes.Part, parts: [GradingNotes.Part], selected: @escaping (GradingNotes.Part) -> CollectionGrade?,
                choose: @escaping (GradingNotes.Part, CollectionGrade) -> Void) {
        _part = State(initialValue: part)
        self.parts = parts
        self.selected = selected
        self.choose = choose
    }

    private var highlighted: CollectionGrade? { selected(part) }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Grading", selection: $part) {
                        ForEach(parts) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if choose != nil {
                        Text("\(Layout.chooseVerb) a grade to give it to your copy\(part == .sleeve ? "'s sleeve" : "").")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    tips
                    ForEach(part.grades, id: \.self) { grade in
                        row(grade).id(grade)
                    }
                    Text("The drawings show the kinds of wear to look for, not real copies. The grades follow the Goldmine scale that Discogs and most sellers use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(Layout.padding)
            }
            .onAppear {
                if let highlighted, part.grades.contains(highlighted) { proxy.scrollTo(highlighted, anchor: .top) }
            }
            .onChange(of: part) {
                if let highlighted, part.grades.contains(highlighted) { proxy.scrollTo(highlighted, anchor: .top) }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("How to grade", systemImage: "lightbulb").font(.headline)
            ForEach(GradingNotes.tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(tip).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func row(_ grade: CollectionGrade) -> some View {
        if let choose {
            Button { choose(part, grade) } label: { card(grade) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? grade : (hovered == grade ? nil : hovered) }
                .accessibilityLabel("Choose \(grade.name)")
        } else {
            card(grade)
        }
    }

    private func card(_ grade: CollectionGrade) -> some View {
        HStack(alignment: .top, spacing: 14) {
            GradeIllustration(grade: grade, part: part)
                .frame(width: Layout.picture, height: Layout.picture)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(grade.name).font(.headline)
                    if grade.isMediaGrade { Text(grade.short).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if choose != nil {
                        if grade == highlighted {
                            Label("Chosen", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        } else if grade == hovered {
                            Text("Choose").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Text(GradingNotes.summary(grade, part: part)).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(GradingNotes.points(grade, part: part), id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(point).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .card()
        .overlay {
            if grade == hovered, grade != highlighted {
                RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5)
            }
            if grade == highlighted {
                RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    enum Layout {
        #if os(macOS)
        static let chooseVerb = "Click"
        #else
        static let chooseVerb = "Tap"
        #endif
        #if os(macOS)
        static let picture: CGFloat = 120, padding: CGFloat = 20
        #else
        static let picture: CGFloat = 96, padding: CGFloat = 16
        #endif
    }
}

// MARK: Drawings

/// A record, CD or sleeve drawn in a grade's condition: hairlines and scuffs, then scratches, a dull surface, ring
/// wear, worn corners, seam splits, writing and tape as the grade goes down. The same marks every time (seeded).
public struct GradeIllustration: View {
    let grade: CollectionGrade
    let part: GradingNotes.Part

    public init(grade: CollectionGrade, part: GradingNotes.Part) {
        self.grade = grade
        self.part = part
    }

    /// 0 for Mint up to 7 for Poor.
    private var wear: Int { CollectionGrade.media.firstIndex(of: grade) ?? 0 }

    public var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: UInt64(wear + 1) &* 0x9E37_79B9 &+ UInt64(part.rawValue.count))
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            switch part {
            case .record: drawRecord(in: rect, context: &context, rng: &rng)
            case .cd: drawCD(in: rect, context: &context, rng: &rng)
            case .sleeve: drawSleeve(in: rect, context: &context, rng: &rng)
            }
        }
    }

    // MARK: Record

    private func drawRecord(in rect: CGRect, context: inout GraphicsContext, rng: inout SeededRandom) {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        // Every mark stays on the record.
        context.clip(to: disc)
        // Duller and greyer with wear.
        let shade = 0.08 + Double(wear) * 0.025
        context.fill(disc, with: .color(Color(white: shade)))
        // Grooves, then a sheen that fades with wear.
        for i in stride(from: radius * 0.38, to: radius * 0.97, by: radius * 0.045) {
            let groove = Path(ellipseIn: CGRect(x: center.x - i, y: center.y - i, width: i * 2, height: i * 2))
            context.stroke(groove, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
        }
        let sheen = max(0, 0.22 - Double(wear) * 0.03)
        context.fill(disc, with: .linearGradient(
            Gradient(colors: [.white.opacity(sheen), .clear, .white.opacity(sheen * 0.6), .clear]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        // The label, worn and written on further down.
        let label = radius * 0.32
        let labelRect = CGRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2)
        context.fill(Path(ellipseIn: labelRect), with: .color(Color(red: 0.78, green: 0.25, blue: 0.2).opacity(1 - Double(wear) * 0.06)))
        if wear >= 2 { spindleMarks(center: center, radius: label * 0.45, count: wear * 2, context: &context, rng: &rng) }
        if wear >= 3 { scribble(in: labelRect.insetBy(dx: label * 0.5, dy: label * 1.1).offsetBy(dx: 0, dy: label * 0.45),
                               color: Color(white: 0.15), context: &context, rng: &rng) }
        context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(.black))
        // A light edge, so the black record stands out on a dark card.
        context.stroke(disc, with: .color(.white.opacity(0.35)), lineWidth: 1.5)
        surfaceMarks(center: center, inner: label * 1.1, outer: radius * 0.95, context: &context, rng: &rng)
        if wear >= 6 {
            // A crack in from the edge, longer at Poor.
            var crack = Path()
            let angle = 0.6
            crack.move(to: point(center, radius * 1.02, angle))
            crack.addLine(to: point(center, radius * 0.84, angle + 0.07))
            crack.addLine(to: point(center, radius * (wear >= 7 ? 0.42 : 0.62), angle - 0.04))
            context.stroke(crack, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        }
    }

    /// Scuffs and hairlines (seen, not felt) from VG+, scratches from VG, deep ones from G.
    private func surfaceMarks(center: CGPoint, inner: CGFloat, outer: CGFloat, context: inout GraphicsContext, rng: inout SeededRandom) {
        let hairlines = [0, 1, 4, 8, 12, 16, 20, 24][wear]
        for _ in 0..<hairlines {
            let r = rng.next(in: inner...outer), a = rng.next(in: 0...(2 * .pi)), length = rng.next(in: 0.12...0.4)
            var p = Path()
            p.addArc(center: center, radius: r, startAngle: .radians(a), endAngle: .radians(a + length), clockwise: false)
            context.stroke(p, with: .color(.white.opacity(0.25 + Double(wear) * 0.03)), lineWidth: 0.5)
        }
        let scratches = [0, 0, 0, 2, 4, 6, 8, 10][wear]
        for i in 0..<scratches {
            let from = point(center, rng.next(in: inner...outer), rng.next(in: 0...(2 * .pi)))
            let dx = rng.next(in: -1...1), dy = rng.next(in: -1...1), length = rng.next(in: 0.15...0.45) * outer
            var p = Path()
            p.move(to: from)
            p.addLine(to: CGPoint(x: from.x + dx * length, y: from.y + dy * length))
            let deep = wear >= 5 && i % 2 == 0
            context.stroke(p, with: .color(.white.opacity(deep ? 0.75 : 0.45)), lineWidth: deep ? 1.3 : 0.7)
        }
    }

    // MARK: CD

    private func drawCD(in rect: CGRect, context: inout GraphicsContext, rng: inout SeededRandom) {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let discRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let disc = Path(ellipseIn: discRect)
        context.clip(to: disc)
        context.fill(disc, with: .conicGradient(
            Gradient(colors: [Color(white: 0.86), Color(red: 0.75, green: 0.82, blue: 0.95), Color(white: 0.93),
                              Color(red: 0.92, green: 0.82, blue: 0.9), Color(white: 0.86)]),
            center: center))
        context.fill(disc, with: .color(Color(white: 0.5).opacity(Double(wear) * 0.04)))
        context.stroke(disc, with: .color(Color(white: 0.6)), lineWidth: 0.7)
        let hub = radius * 0.3
        context.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(Color(white: 0.8)))
        let hole = radius * 0.12
        context.blendMode = .destinationOut
        context.fill(Path(ellipseIn: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2)), with: .color(.black))
        context.blendMode = .normal
        // Scratches on a CD run in any direction; radial ones from the centre out are the ones that hurt least.
        let count = [0, 1, 5, 10, 16, 22, 28, 34][wear]
        for i in 0..<count {
            let from = point(center, rng.next(in: (hub * 1.1)...(radius * 0.95)), rng.next(in: 0...(2 * .pi)))
            let a = rng.next(in: 0...(2 * .pi)), length = rng.next(in: 0.1...0.4) * radius
            var p = Path()
            p.move(to: from)
            p.addLine(to: CGPoint(x: from.x + cos(a) * length, y: from.y + sin(a) * length))
            let deep = wear >= 5 && i % 3 == 0
            context.stroke(p, with: .color(Color(white: deep ? 0.3 : 0.45).opacity(deep ? 0.8 : 0.5)), lineWidth: deep ? 1.2 : 0.5)
        }
        if wear >= 6 {
            // Disc rot: pinholes and a cloudy patch near the edge.
            for _ in 0..<12 {
                let p = point(center, rng.next(in: (radius * 0.75)...(radius * 0.95)), rng.next(in: 4.0...5.0))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(.black.opacity(0.7)))
            }
        }
    }

    // MARK: Sleeve

    private func drawSleeve(in rect: CGRect, context: inout GraphicsContext, rng: inout SeededRandom) {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch grade {
        case .noCover:
            context.stroke(Path(roundedRect: square.insetBy(dx: 4, dy: 4), cornerRadius: 3),
                           with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            return
        case .generic:
            context.fill(Path(roundedRect: square, cornerRadius: 2), with: .color(Color(red: 0.86, green: 0.8, blue: 0.68)))
            let hole = side * 0.18
            context.fill(Path(ellipseIn: CGRect(x: square.midX - hole, y: square.midY - hole, width: hole * 2, height: hole * 2)),
                         with: .color(Color(white: 0.12)))
            return
        case .notGraded:
            context.fill(Path(roundedRect: square, cornerRadius: 2), with: .color(Color(white: 0.75)))
            context.draw(Text("?").font(.system(size: side * 0.4, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: square.midX, y: square.midY))
            return
        default: break
        }
        // A printed cover: colour bands, faded with wear.
        let fade = Double(wear) * 0.06
        context.fill(Path(roundedRect: square, cornerRadius: 2), with: .linearGradient(
            Gradient(colors: [Color(red: 0.16, green: 0.36, blue: 0.62), Color(red: 0.9, green: 0.62, blue: 0.2)]),
            startPoint: CGPoint(x: square.minX, y: square.minY), endPoint: CGPoint(x: square.maxX, y: square.maxY)))
        context.fill(Path(roundedRect: square, cornerRadius: 2), with: .color(.white.opacity(fade)))
        // Mint: shrink wrap's shine.
        if grade == .mint {
            var shine = Path()
            shine.move(to: CGPoint(x: square.minX + side * 0.55, y: square.minY))
            shine.addLine(to: CGPoint(x: square.minX + side * 0.75, y: square.minY))
            shine.addLine(to: CGPoint(x: square.minX + side * 0.25, y: square.maxY))
            shine.addLine(to: CGPoint(x: square.minX + side * 0.05, y: square.maxY))
            context.fill(shine, with: .color(.white.opacity(0.28)))
        }
        // Ring wear: the record's outline rubbed through, fainter at VG+.
        if wear >= 2 {
            let r = side * 0.44
            let ring = Path(ellipseIn: CGRect(x: square.midX - r, y: square.midY - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(.white.opacity(min(0.65, 0.08 + Double(wear - 2) * 0.12))),
                           lineWidth: side * (0.03 + Double(wear) * 0.006))
        }
        // Worn corners.
        if wear >= 2 {
            let size = side * (0.03 + Double(wear) * 0.012)
            for corner in [square.origin, CGPoint(x: square.maxX, y: square.minY), CGPoint(x: square.minX, y: square.maxY),
                           CGPoint(x: square.maxX, y: square.maxY)] {
                let p = Path(ellipseIn: CGRect(x: corner.x - size, y: corner.y - size, width: size * 2, height: size * 2))
                context.fill(p, with: .color(.white.opacity(0.55)))
            }
        }
        // A price sticker, then creases and writing.
        if wear >= 2 {
            let sticker = CGRect(x: square.maxX - side * 0.24, y: square.minY + side * 0.06, width: side * 0.17, height: side * 0.1)
            context.fill(Path(roundedRect: sticker, cornerRadius: 1.5), with: .color(.white.opacity(0.9)))
        }
        if wear >= 3 {
            var crease = Path()
            crease.move(to: CGPoint(x: square.minX, y: square.minY + side * 0.3))
            crease.addLine(to: CGPoint(x: square.minX + side * 0.3, y: square.minY))
            context.stroke(crease, with: .color(.white.opacity(0.5)), lineWidth: 0.8)
            scribble(in: CGRect(x: square.minX + side * 0.1, y: square.maxY - side * 0.2, width: side * 0.35, height: side * 0.08),
                     color: .black.opacity(0.7), context: &context, rng: &rng)
        }
        // A seam split down the right edge, longer further down, with tape at G.
        if wear >= 3 {
            let length = side * [0, 0, 0, 0.15, 0.4, 0.55, 0.8, 0.95][wear]
            var split = Path()
            split.move(to: CGPoint(x: square.maxX - 1, y: square.minY + side * 0.05))
            split.addLine(to: CGPoint(x: square.maxX - 1, y: square.minY + side * 0.05 + length))
            context.stroke(split, with: .color(Color(white: 0.1)), lineWidth: 2.4)
            if wear >= 5 {
                let tape = CGRect(x: square.maxX - side * 0.1, y: square.minY + side * 0.2, width: side * 0.16, height: side * 0.12)
                context.fill(Path(tape), with: .color(Color(red: 0.95, green: 0.88, blue: 0.6).opacity(0.75)))
            }
        }
        // Stains.
        if wear >= 5 {
            for _ in 0..<(wear - 3) {
                let r = rng.next(in: (side * 0.05)...(side * 0.12))
                let c = CGPoint(x: rng.next(in: square.minX...square.maxX), y: rng.next(in: square.minY...square.maxY))
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 1.6)),
                             with: .color(Color(red: 0.45, green: 0.32, blue: 0.15).opacity(0.35)))
            }
        }
    }

    // MARK: Helpers

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func spindleMarks(center: CGPoint, radius: CGFloat, count: Int, context: inout GraphicsContext, rng: inout SeededRandom) {
        for _ in 0..<count {
            let a = rng.next(in: 0...(2 * .pi)), r = rng.next(in: (radius * 0.4)...radius)
            var p = Path()
            p.addArc(center: center, radius: r, startAngle: .radians(a), endAngle: .radians(a + 0.5), clockwise: false)
            context.stroke(p, with: .color(.black.opacity(0.45)), lineWidth: 0.6)
        }
    }

    private func scribble(in rect: CGRect, color: Color, context: inout GraphicsContext, rng: inout SeededRandom) {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        var x = rect.minX
        while x < rect.maxX {
            x += rect.width / 9
            p.addLine(to: CGPoint(x: min(x, rect.maxX), y: rng.next(in: rect.minY...rect.maxY)))
        }
        context.stroke(p, with: .color(color), lineWidth: 0.9)
    }
}

/// A small, repeatable random number source, so a drawing's marks stay put.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed }

    mutating func nextUnit() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 1_000_000) / 1_000_000
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }
}
