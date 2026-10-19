import Foundation
import Testing
@testable import MusicLibraryCore

@Suite struct CollaborationGraphTests {
    static func t(_ id: Int64, artist: String, composer: String = "", mbArtist: [String] = [], credits: [Credit] = [],
                  configure: (inout ExtendedMetadata) -> Void = { _ in }) -> Track {
        var x = ExtendedMetadata()
        x.credits = credits
        x.mbArtistIds = mbArtist
        configure(&x)
        return Track(id: id, path: "p\(id)", metadata: TrackMetadata(title: "T\(id)", artist: artist, album: "A", composer: composer, extended: x),
                     duration: 200, format: "flac", sha256: "s\(id)")
    }
    static func play(_ name: String, _ instrument: String, id: String? = nil) -> Credit {
        Credit(role: "instrument", name: name, artistId: id, attributes: [instrument], scope: .recording)
    }

    static let graph = CollaborationGraph(tracks: [
        t(1, artist: "Duke Ellington & His Orchestra", composer: "Duke Ellington; Billy Strayhorn",
          credits: [play("Duke Ellington", "piano", id: "de"), play("Johnny Hodges", "alto saxophone", id: "jh"),
                    play("Harry Carney", "baritone saxophone")]),
        t(2, artist: "Duke Ellington & His Orchestra", composer: "Duke Ellington",
          credits: [play("Duke Ellington", "piano", id: "de"), play("Johnny Hodges", "alto saxophone", id: "jh")]),
        t(3, artist: "Johnny Hodges", credits: [play("Johnny Hodges", "alto saxophone", id: "jh"), play("Billy Strayhorn", "piano")]) {
            $0.producer = "Norman Granz"
        },
        t(4, artist: "Rachael & Vilray feat. Jon Batiste", composer: "Vilray"),
        t(5, artist: "Various Artists", credits: [Credit(role: "producer", name: "Norman Granz", scope: .release),
                                                  Credit(role: "engineer", name: "[unknown]", scope: .recording)]) {
            $0.performers = ["Oscar Peterson (piano)"]
        },
    ])

    func p(_ name: String) throws -> CollaborationGraph.Person { try #require(Self.graph.person(named: name), "\(name) missing") }

    @Test func peopleAreMergedAndPlaceholdersSkipped() throws {
        let duke = try p("Duke Ellington")
        #expect(duke.trackCount == 2)                       // credit (by MBID) and composer tag (by name) merge
        #expect(duke.roles.first == "composer" || duke.roles.first == "piano")
        #expect(Self.graph.person(named: "duke ellington")?.id == duke.id)
        #expect(try p("Johnny Hodges").trackCount == 3)      // credit + track artist
        #expect(Self.graph.person(named: "Various Artists") == nil)
        #expect(Self.graph.person(named: "[unknown]") == nil)
        #expect(try p("Jon Batiste").roles == ["artist"])    // split from "feat."
        #expect(try p("Rachael & Vilray").trackCount == 1)   // "&" stays part of the name
        #expect(try p("Oscar Peterson").roles == ["performer"])
    }

    @Test func nonMusicalCreditsAreLeftOut() {
        let g = CollaborationGraph(tracks: [
            Self.t(1, artist: "Tom Rush", credits: [
                Credit(role: "photography", name: "Elliott Landy", scope: .release),
                Credit(role: "liner notes", name: "Dave Marsh", scope: .release),
                Credit(role: "mastering", name: "Mark Wilder", scope: .release),
            ]),
        ])
        #expect(g.person(named: "Elliott Landy") == nil && g.person(named: "Dave Marsh") == nil)
        #expect(g.person(named: "Mark Wilder")?.category == .production)
        #expect(g.person(named: "Tom Rush")?.degree == 1)
    }

    @Test func sameNameDifferentMBIDStaysSeparate() {
        let g = CollaborationGraph(tracks: [
            Self.t(1, artist: "X", credits: [Self.play("John Smith", "drums", id: "a")]),
            Self.t(2, artist: "Y", credits: [Self.play("John Smith", "bass", id: "b")]),
        ])
        #expect(g.people.filter { $0.name == "John Smith" }.count == 2)
    }

    @Test func categories() throws {
        #expect(try p("Norman Granz").category == .production)
        #expect(try p("Vilray").category == .writing)
        #expect(try p("Harry Carney").category == .performance)
        #expect(CollaborationGraph.category(ofRole: "recording engineer") == .production)
        #expect(CollaborationGraph.category(ofRole: "lyricist") == .writing)
        #expect(CollaborationGraph.category(ofRole: "tenor saxophone") == .performance)
    }

    @Test func edgesCountSharedTracks() throws {
        let g = Self.graph
        let duke = try p("Duke Ellington"), hodges = try p("Johnny Hodges"), strayhorn = try p("Billy Strayhorn")
        #expect(g.sharedTrackCount(duke.id, hodges.id) == 2)
        #expect(g.sharedTracks(duke.id, hodges.id) == [1, 2])
        #expect(g.sharedTrackCount(hodges.id, strayhorn.id) == 2)   // tracks 1 and 3
        #expect(g.collaborators(of: hodges.id).first?.shared == 2)
        #expect(g.sharedTrackCount(duke.id, try p("Norman Granz").id) == 0)
        #expect(hodges.degree == g.collaborators(of: hodges.id).count)
    }

    @Test func splitting() {
        #expect(CollaborationGraph.splitNames("JD BECK; DOMi") == ["JD BECK", "DOMi"])
        #expect(CollaborationGraph.splitNames("Earth, Wind & Fire") == ["Earth, Wind & Fire"])
        #expect(CollaborationGraph.splitArtists("A feat. B with C") == ["A", "B", "C"])
        #expect(CollaborationGraph.stripParenthetical("Oscar Peterson (piano)") == "Oscar Peterson")
    }

    @Test func searchAndStartingPoints() {
        #expect(Self.graph.search("hod").first?.name == "Johnny Hodges")
        #expect(Self.graph.search("ell").first?.name == "Duke Ellington")   // word start beats "Duke Ellington & His Orchestra"? both start
        #expect(Self.graph.search("").isEmpty)
        #expect(Self.graph.mostConnected(limit: 1).first?.name == "Johnny Hodges")
    }

    @Test func neighborhoodLevelsAndTreeEdges() throws {
        let g = Self.graph
        let granz = try p("Norman Granz")
        let one = g.neighborhood(of: granz.id, depth: 1)
        #expect(one.nodes.first?.level == 0)
        #expect(Set(one.nodes.dropFirst().map(\.person.name)) == ["Johnny Hodges", "Billy Strayhorn", "Oscar Peterson"])
        #expect(one.nodes.dropFirst().allSatisfy { $0.level == 1 && $0.parent == granz.id })

        let two = g.neighborhood(of: granz.id, depth: 2)
        #expect(two.nodes.contains { $0.person.name == "Duke Ellington" && $0.level == 2 })
        #expect(Set(two.nodes.map(\.id)).count == two.nodes.count)          // each person once
        let ids = Set(two.nodes.map(\.id))
        #expect(two.edges.allSatisfy { ids.contains($0.a) && ids.contains($0.b) && $0.a < $0.b })
        #expect(two.edges.filter(\.isTree).count == two.nodes.count - 1)
        #expect(two.edges.contains { !$0.isTree })                             // Hodges–Strayhorn are both level 1
    }

    @Test func fanoutCapsLargeNeighborhoods() {
        // One leader with 50 sidemen, each also on a second track with their own 3 guests.
        var tracks = [Self.t(1, artist: "Leader", credits: (0..<50).map { Self.play("Side \($0)", "horn") })]
        for i in 0..<50 {
            tracks.append(Self.t(Int64(100 + i), artist: "Side \(i)", credits: (0..<3).map { Self.play("Guest \(i)-\($0)", "drums") }))
        }
        let g = CollaborationGraph(tracks: tracks)
        let leader = g.person(named: "Leader")!.id
        let one = g.neighborhood(of: leader, depth: 1)
        #expect(one.nodes.count == 31 && one.hidden == 20)
        let three = g.neighborhood(of: leader, depth: 3, maxNodes: 60)
        #expect(three.nodes.count <= 60)
        #expect(three.nodes.filter { $0.level == 1 }.count == 10)
    }

    @Test func radialLayoutPutsLevelsOnRings() throws {
        let g = Self.graph
        let n = g.neighborhood(of: try p("Norman Granz").id, depth: 2)
        let pos = CollaborationGraph.layout(n)
        #expect(pos.count == n.nodes.count)
        for node in n.nodes {
            let r = hypot(pos[node.id]!.x, pos[node.id]!.y)
            #expect(abs(r - Double(node.level)) < 1e-9, "\(node.person.name) at r=\(r)")
        }
        let ring1 = n.nodes.filter { $0.level == 1 }.map { pos[$0.id]! }
        for i in ring1.indices { for j in ring1.indices where j > i { #expect(hypot(ring1[i].x - ring1[j].x, ring1[i].y - ring1[j].y) > 0.5) } }
    }

    @Test func emptyGraph() {
        #expect(CollaborationGraph.empty.people.isEmpty)
        #expect(CollaborationGraph.empty.neighborhood(of: 0, depth: 2).nodes.isEmpty)
        #expect(CollaborationGraph.empty.person(named: "x") == nil)
    }

    /// A record with no digital copy adds its release's people (from the cached album info), so a player you have only
    /// on vinyl links to the same people in the digital collection; a copy whose album has tracks adds nothing more.
    @Test func physicalOnlyCopiesJoinTheGraph() throws {
        let miles = "561d854a-6a28-4aa7-8c99-323e6ce46c2a", trane = "b625448e-bf4a-41c3-a421-72ad46cdb831"
        let digital = Self.t(1, artist: "John Coltrane", mbArtist: [trane], credits: [Self.play("John Coltrane", "tenor saxophone", id: trane),
                                                                                         Self.play("McCoy Tyner", "piano")])
        func copy(_ id: String, _ medium: CollectionMedium, album: String, artist: String) -> CollectionItem {
            CollectionItem(id: id, medium: medium, album: album, artist: artist, now: Date(timeIntervalSince1970: 0))
        }
        let vinyl = copy("kob-lp", .vinyl, album: "Kind of Blue", artist: "Miles Davis")
        let cd = copy("kob-cd", .cd, album: "Kind of Blue", artist: "Miles Davis")      // same album, counted once
        let bare = copy("bare-lp", .vinyl, album: "Sketches", artist: "Gil Evans")        // no album info: one song
        let ripped = copy("train-cd", .cd, album: "A", artist: "John Coltrane")         // its tracks are in the library
        let collection = MusicCollection(items: [vinyl, cd, bare, ripped], songPurchases: [:], tracks: [digital])
        var info = AlbumInfo(title: "Kind of Blue")
        info.tracklist = [
            TracklistEntry(disc: 1, number: 1, title: "So What", artist: "Miles Davis", position: "A1",
                           credits: [Self.play("John Coltrane", "tenor saxophone", id: trane), Self.play("Bill Evans", "piano")]),
            TracklistEntry(disc: 1, number: 2, title: "Freddie Freeloader", artist: "Miles Davis", position: "A2",
                           credits: [Self.play("Wynton Kelly", "piano")]),
        ]
        info.releaseCredits = [Credit(role: "producer", name: "Teo Macero", scope: .release),
                               Credit(role: "photography", name: "Don Hunstein", scope: .release),
                               Self.play("Miles Davis", "trumpet", id: miles)]
        let songs = CollaborationGraph.physicalSongs(collection: collection, albumInfos: [vinyl.albumKey: info])
        #expect(songs.count == 3, "two songs from the record's track list, one for the album with no info")
        #expect(songs.allSatisfy { $0.id < 0 } && Set(songs.map(\.id)).count == 3)
        #expect(Set(songs.map(\.itemID)) == ["kob-cd", "bare-lp"], "the first copy of an album, by id")
        let graph = CollaborationGraph(tracks: [digital], physical: songs)

        let coltrane = try #require(graph.person(named: "John Coltrane"))
        #expect(coltrane.trackCount == 2, "the digital track and So What from the record, merged by MusicBrainz ID")
        let shared = graph.sharedTracks(coltrane.id, try #require(graph.person(named: "Miles Davis")).id)
        #expect(shared.count == 1 && graph.physicalSong(shared[0])?.title == "So What")
        #expect(graph.collaborators(of: coltrane.id).map(\.person.name).contains("McCoy Tyner"))
        #expect(graph.person(named: "Teo Macero")?.trackCount == 2, "release credits are on every song of the record")
        #expect(graph.person(named: "Don Hunstein") == nil, "not a musical credit")
        #expect(graph.person(named: "Gil Evans")?.trackCount == 1)
        #expect(graph.physicalSong(1) == nil && graph.physicalSong(-99) == nil)
    }

    @Test func albumInfoCachedBeforeCreditsStillDecodes() throws {
        let old = #"{"title":"A","secondaryTypes":[],"genres":[],"ratingVotes":0,"links":[],"tracklist":[{"disc":1,"number":1,"title":"T","artist":"X","recordingId":""}],"fetchedAt":0,"notFound":false}"#
        let info = try JSONDecoder().decode(AlbumInfo.self, from: Data(old.utf8))
        #expect(info.releaseCredits == nil && info.tracklist.first?.credits == nil)
    }
}
